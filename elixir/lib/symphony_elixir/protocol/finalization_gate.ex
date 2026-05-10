defmodule SymphonyElixir.Protocol.FinalizationGate do
  @moduledoc """
  Central gate for final workflow transitions.
  """

  alias SymphonyElixir.Protocol.{Contract, StateTransitionGuard, Violation}

  @code_extensions ~w[
    .ex .exs .erl .hrl .js .jsx .ts .tsx .mjs .cjs .json .lock .yml .yaml .toml .sql .sh .bash .zsh
    .py .rb .go .rs .java .kt .swift .c .cc .cpp .h .hpp .cs .php
  ]

  @spec evaluate(map(), String.t() | atom(), Contract.t()) :: {:ok, map()} | {:blocked, map()}
  def evaluate(run_state, target_state, %Contract{finalization_gate: false} = contract) when is_map(run_state) do
    {:ok, result(run_state, to_string(target_state), contract, [], [])}
  end

  def evaluate(run_state, target_state, %Contract{} = contract) when is_map(run_state) do
    target_state = target_state_name(target_state, contract)
    warnings = protocol_warnings(run_state, contract)

    violations =
      []
      |> add_state_transition_violations(run_state, target_state, contract)
      |> add_budget_violations(run_state, contract)
      |> add_validation_violations(run_state, target_state, contract)
      |> add_lane_violations(run_state, target_state, contract)
      |> add_human_review_violations(run_state, target_state, contract)
      |> add_blocked_violations(run_state, target_state, contract)
      |> add_done_violations(run_state, target_state, contract)
      |> Enum.reverse()

    result = result(run_state, target_state, contract, violations, warnings)

    if Enum.any?(violations, &(&1.severity == :blocking)) do
      {:blocked, %{result | final_state: contract.blocked_state}}
    else
      {:ok, result}
    end
  end

  def evaluate(_run_state, target_state, contract) do
    violation =
      Violation.blocking(:invalid_finalization_input, "Finalization gate requires a run state map.", evidence: %{target_state: target_state})

    {:blocked, result(%{}, contract.blocked_state, contract, [violation], [])}
  end

  @spec code_bearing_changes?([String.t()]) :: boolean()
  def code_bearing_changes?(changed_files) when is_list(changed_files) do
    Enum.any?(changed_files, fn file ->
      ext = file |> to_string() |> Path.extname() |> String.downcase()
      ext in @code_extensions
    end)
  end

  def code_bearing_changes?(_changed_files), do: false

  defp add_state_transition_violations(violations, run_state, target_state, contract) do
    StateTransitionGuard.validate(run_state, target_state, contract) ++ violations
  end

  defp add_budget_violations(violations, run_state, _contract) do
    if budget_exceeded?(run_state) and repo_changed?(run_state) and blank?(Map.get(run_state, :pr_url)) do
      [
        Violation.blocking(:budget_exceeded_before_pr, "Lane token budget was exceeded before a required PR existed.",
          required_action: "Stop the run, post a budget-exceeded blocker handoff, and move to Blocked.",
          evidence: budget_evidence(run_state)
        )
        | violations
      ]
    else
      violations
    end
  end

  defp add_validation_violations(violations, run_state, target_state, %Contract{} = contract) do
    if target_state == contract.review_state and validation_required?(run_state, contract) do
      validation_status_violations(violations, run_state)
    else
      violations
    end
  end

  defp validation_status_violations(violations, run_state) do
    case validation_status(run_state) do
      status when status in [:passed, :allowed_failure] ->
        violations

      :failed ->
        failed_validation_violations(violations, run_state)

      _ ->
        [
          Violation.blocking(:validation_required_but_missing, "Code-bearing changes require explicit validation before Human Review.",
            required_action: "Run the configured validation command and record the result.",
            evidence: validation_evidence(run_state)
          )
          | violations
        ]
    end
  end

  defp failed_validation_violations(violations, run_state) do
    if validation_failure_allowed?(run_state) do
      violations
    else
      [
        Violation.blocking(:validation_failed, "Required validation failed.",
          required_action: "Fix the validation failure or move to Blocked with an allowed-policy reason.",
          evidence: validation_evidence(run_state)
        )
        | violations
      ]
    end
  end

  defp add_lane_violations(violations, run_state, target_state, %Contract{} = contract) do
    if target_state == contract.review_state do
      lane_violations(lane(run_state), violations, run_state)
    else
      violations
    end
  end

  defp lane_violations("docs", violations, run_state), do: docs_lane_violations(violations, run_state)
  defp lane_violations("feature", violations, run_state), do: feature_lane_violations(violations, run_state)
  defp lane_violations("bug", violations, run_state), do: bug_lane_violations(violations, run_state)
  defp lane_violations("refactor", violations, run_state), do: refactor_lane_violations(violations, run_state)
  defp lane_violations("test", violations, run_state), do: test_lane_violations(violations, run_state)
  defp lane_violations("chore", violations, run_state), do: chore_lane_violations(violations, run_state)
  defp lane_violations("research", violations, run_state), do: research_lane_violations(violations, run_state)
  defp lane_violations(_lane, violations, _run_state), do: violations

  defp docs_lane_violations(violations, run_state) do
    cond do
      !repo_changed?(run_state) ->
        violations

      code_bearing_changes?(changed_files(run_state)) ->
        [
          Violation.blocking(:docs_lane_source_change, "Docs lane changed source, runtime, schema, script, or config files unexpectedly.",
            required_action: "Reclassify the lane or run the required validation before Human Review.",
            evidence: %{lane: "docs", changed_files: changed_files(run_state)}
          )
          | violations
        ]

      validation_required_by_ticket?(run_state) and validation_status(run_state) in [:not_run, nil] ->
        [
          Violation.blocking(:validation_required_but_missing, "Ticket-required validation was skipped for a docs lane change.",
            required_action: "Run the ticket-required validation or move to Blocked.",
            evidence: validation_evidence(run_state)
          )
          | violations
        ]

      validation_status(run_state) == :not_run and blank?(Map.get(run_state, :validation_reason)) ->
        [
          Violation.blocking(:validation_skip_reason_missing, "Docs lane skipped validation without an explicit docs/text-only reason.",
            required_action: "Record why validation was not run.",
            evidence: validation_evidence(run_state)
          )
          | violations
        ]

      true ->
        violations
    end
  end

  defp feature_lane_violations(violations, run_state) do
    violations
    |> require_lane_validation(run_state, :feature_validation_missing, "Feature lane requires validation before Human Review.")
    |> require_flag_if_true(
      run_state,
      :behavior_changed,
      :behavior_change_documented,
      :behavior_change_not_documented,
      "Feature behavior changes must be documented in the handoff."
    )
    |> require_flag_or_reason(
      run_state,
      :tests_added,
      :tests_not_added_reason,
      :tests_missing_or_unjustified,
      "Feature lane requires tests or an explicit no-tests justification."
    )
    |> require_false(run_state, :scope_expanded, :scope_expanded_beyond_ticket, "Feature lane cannot expand scope beyond the ticket.")
  end

  defp bug_lane_violations(violations, run_state) do
    violations
    |> require_true(:bug_failure_signal_identified, run_state, :failure_signal_identified, "Bug lane requires an identified failure signal.")
    |> require_true(:affected_files_not_inspected, run_state, :affected_files_inspected, "Bug lane requires affected files to be inspected.")
    |> require_lane_validation(run_state, :bug_validation_missing, "Bug lane requires validation or a targeted test run.")
  end

  defp refactor_lane_violations(violations, run_state) do
    violations
    |> require_lane_validation(run_state, :refactor_validation_missing, "Refactor lane requires validation before Human Review.")
    |> require_true(:behavior_preservation_missing, run_state, :behavior_preservation_evidence, "Refactor lane requires behavior-preservation evidence.")
    |> require_false(run_state, :behavior_changed, :unexpected_behavior_change, "Refactor lane must preserve behavior.")
    |> require_false(run_state, :scope_expanded, :refactor_scope_expanded, "Refactor lane cannot expand into unrelated feature work.")
  end

  defp test_lane_violations(violations, run_state) do
    violations
    |> require_true(:tests_not_run, run_state, :targeted_tests_run, "Test lane requires targeted tests to be run.")
    |> require_true(:test_coverage_missing, run_state, :test_coverage_added, "Test lane requires meaningful test coverage to be added or improved.")
  end

  defp chore_lane_violations(violations, run_state) do
    if safe_chore_skip?(run_state) do
      violations
    else
      violations
      |> require_lane_validation(run_state, :chore_validation_missing, "Chore lane requires relevant validation for config, script, dependency, CI, formatting, or hygiene changes.")
      |> require_dependency_evidence(run_state)
    end
  end

  defp research_lane_violations(violations, run_state) do
    violations
    |> require_true(:research_findings_missing, run_state, :findings_posted, "Research lane requires Linear findings to be posted.")
    |> require_true(:research_sources_missing, run_state, :sources_inspected_listed, "Research lane requires inspected files or sources to be listed.")
    |> require_true(:research_conclusion_missing, run_state, :recommendation_included, "Research lane requires a recommendation or conclusion.")
  end

  defp add_human_review_violations(violations, run_state, target_state, %Contract{} = contract) do
    if target_state == contract.review_state and repo_changed?(run_state) do
      violations
      |> require_value(:branch_missing, run_state, :branch_name, "Repository changes require a branch before Human Review.")
      |> require_value(:commit_missing, run_state, :commit_sha, "Repository changes require a commit before Human Review.")
      |> require_value(:pr_required_but_missing, run_state, :pr_url, "Repository changes require a draft PR before Human Review.")
      |> require_true(:branch_not_pushed, run_state, :branch_pushed, "Repository changes require the branch to be pushed before Human Review.")
      |> require_true(:pr_url_not_posted_to_linear, run_state, :pr_posted_to_linear, "PR URL must be posted to Linear before Human Review.")
      |> require_true(:handoff_missing, run_state, :handoff_posted, "Linear handoff must exist before Human Review.")
    else
      violations
    end
  end

  defp add_blocked_violations(violations, run_state, target_state, %Contract{} = contract) do
    if target_state == contract.blocked_state do
      violations
      |> require_value(:blocked_reason_missing, run_state, :blocker_reason, "Blocked transitions require an explicit blocker reason.")
      |> require_true(:handoff_missing, run_state, :handoff_posted, "Blocked transitions require a blocker handoff comment.")
    else
      violations
    end
  end

  defp add_done_violations(violations, run_state, target_state, %Contract{} = contract) do
    if target_state == contract.done_state and Map.get(run_state, :merged) != true do
      [
        Violation.blocking(:merge_required_before_done, "Done is only allowed after merge/landing semantics are satisfied.",
          required_action: "Complete the merge flow before moving to Done.",
          evidence: %{merged: Map.get(run_state, :merged)}
        )
        | violations
      ]
    else
      violations
    end
  end

  defp protocol_warnings(run_state, %Contract{} = contract) do
    policy_override_warnings(run_state, contract) ++ graphql_fallback_warnings(run_state)
  end

  defp policy_override_warnings(run_state, %Contract{} = contract) do
    if repo_changed?(run_state) and contract.repo_changes_require_pr and
         !contract.allow_ticket_to_disable_pr and ticket_disables_pr?(run_state) do
      [
        Violation.warning(:ticket_conflicts_with_workflow_policy, "Ticket text conflicts with the workflow PR policy.",
          required_action: "Follow the workflow policy and require a PR for repository changes.",
          evidence: %{
            policy_override: true,
            override_reason: "workflow requires PR for repo-changing tickets",
            ticket_conflict: ticket_conflict(run_state)
          }
        )
      ]
    else
      []
    end
  end

  defp graphql_fallback_warnings(run_state) do
    run_state
    |> generic_linear_graphql_calls()
    |> Enum.flat_map(fn call ->
      reason = Map.get(call, :fallback_reason) || Map.get(call, "fallback_reason") || Map.get(call, :reason) || Map.get(call, "reason")

      narrow_available =
        Map.get(call, :narrow_tool_available) ||
          Map.get(call, "narrow_tool_available") ||
          Map.get(call, :narrow_tool_existed) ||
          Map.get(call, "narrow_tool_existed")

      narrow_failed = Map.get(call, :narrow_tool_failed) || Map.get(call, "narrow_tool_failed")

      cond do
        blank?(reason) ->
          [
            Violation.warning(:generic_graphql_without_fallback_reason, "Generic Linear GraphQL was used without a fallback reason.",
              required_action: "Record why fallback GraphQL was necessary.",
              evidence: call
            )
          ]

        narrow_available == true and narrow_failed != true ->
          [
            Violation.warning(:unnecessary_generic_linear_graphql, "Generic Linear GraphQL was used while a narrow helper was available.",
              required_action: "Use the narrow lifecycle/helper tool unless it failed.",
              evidence: call
            )
          ]

        true ->
          []
      end
    end)
  end

  defp require_value(violations, code, run_state, key, message) do
    if blank?(Map.get(run_state, key) || Map.get(run_state, to_string(key))) do
      [
        Violation.blocking(code, message,
          required_action: "Move to Blocked and record the missing artifact.",
          evidence: %{missing_artifact: key, changed_files: changed_files(run_state)}
        )
        | violations
      ]
    else
      violations
    end
  end

  defp require_true(violations, code, run_state, key, message) do
    if (Map.get(run_state, key) || Map.get(run_state, to_string(key))) == true do
      violations
    else
      [
        Violation.blocking(code, message,
          required_action: "Move to Blocked and record the missing artifact.",
          evidence: %{missing_artifact: key, value: Map.get(run_state, key), changed_files: changed_files(run_state)}
        )
        | violations
      ]
    end
  end

  defp require_false(violations, run_state, key, code, message) do
    if (Map.get(run_state, key) || Map.get(run_state, to_string(key))) == true do
      [
        Violation.blocking(code, message,
          required_action: "Move to Blocked or provide lane evidence before Human Review.",
          evidence: %{lane: lane(run_state), key: key, value: true}
        )
        | violations
      ]
    else
      violations
    end
  end

  defp require_flag_if_true(violations, run_state, condition_key, required_key, code, message) do
    condition = Map.get(run_state, condition_key) || Map.get(run_state, to_string(condition_key))
    required = Map.get(run_state, required_key) || Map.get(run_state, to_string(required_key))

    if condition == true and required != true do
      [
        Violation.blocking(code, message,
          required_action: "Record the missing lane evidence before Human Review.",
          evidence: %{lane: lane(run_state), condition: condition_key, missing_artifact: required_key}
        )
        | violations
      ]
    else
      violations
    end
  end

  defp require_flag_or_reason(violations, run_state, flag_key, reason_key, code, message) do
    flag = Map.get(run_state, flag_key) || Map.get(run_state, to_string(flag_key))
    reason = Map.get(run_state, reason_key) || Map.get(run_state, to_string(reason_key))

    if flag == true or !blank?(reason) do
      violations
    else
      [
        Violation.blocking(code, message,
          required_action: "Add tests or record why tests were not applicable.",
          evidence: %{lane: lane(run_state), missing_artifact: flag_key, missing_reason: reason_key}
        )
        | violations
      ]
    end
  end

  defp require_lane_validation(violations, run_state, code, message) do
    case validation_status(run_state) do
      :passed -> violations
      :allowed_failure -> violations
      _ -> [lane_validation_violation(run_state, code, message) | violations]
    end
  end

  defp lane_validation_violation(run_state, code, message) do
    Violation.blocking(code, message,
      required_action: "Run lane-required validation.",
      evidence: validation_evidence(run_state)
    )
  end

  defp require_dependency_evidence(violations, run_state) do
    if dependency_change?(run_state) and
         (Map.get(run_state, :dependency_update_evidence) || Map.get(run_state, "dependency_update_evidence")) != true do
      [
        Violation.blocking(:dependency_update_evidence_missing, "Dependency changes require lockfile or update evidence.",
          required_action: "Record dependency update evidence before Human Review.",
          evidence: %{changed_files: changed_files(run_state)}
        )
        | violations
      ]
    else
      violations
    end
  end

  defp dependency_change?(run_state) do
    Enum.any?(changed_files(run_state), fn file ->
      String.contains?(file, ["package.json", "package-lock.json", "pnpm-lock.yaml", "yarn.lock", "mix.exs", "mix.lock"])
    end)
  end

  defp safe_chore_skip?(run_state) do
    Map.get(run_state, :explicitly_safe_validation_skip) == true or
      Map.get(run_state, "explicitly_safe_validation_skip") == true
  end

  defp result(run_state, target_state, %Contract{} = contract, violations, warnings) do
    %{
      protocol_contract_version: contract.version,
      target_state: target_state,
      final_state: target_state,
      repo_changed: repo_changed?(run_state),
      changed_files: changed_files(run_state),
      pr_required: pr_required?(run_state, contract),
      protocol_violations: violations,
      protocol_warnings: warnings,
      finalization_gate_result: if(Enum.any?(violations, &(&1.severity == :blocking)), do: :blocked, else: :ok),
      finalization_reason: finalization_reason(violations, warnings)
    }
  end

  defp finalization_reason([], []), do: "protocol gate passed"
  defp finalization_reason(violations, _warnings), do: Enum.map_join(violations, ", ", & &1.code)

  defp target_state_name(:human_review, contract), do: contract.review_state
  defp target_state_name(:blocked, contract), do: contract.blocked_state
  defp target_state_name(:done, contract), do: contract.done_state
  defp target_state_name(target_state, _contract) when is_binary(target_state), do: target_state
  defp target_state_name(target_state, _contract), do: to_string(target_state)

  defp pr_required?(run_state, %Contract{} = contract), do: repo_changed?(run_state) and contract.repo_changes_require_pr

  defp repo_changed?(run_state) do
    Map.get(run_state, :repo_changed) == true or Map.get(run_state, "repo_changed") == true or changed_files(run_state) != []
  end

  defp changed_files(run_state) do
    case Map.get(run_state, :changed_files) || Map.get(run_state, "changed_files") do
      files when is_list(files) -> Enum.map(files, &to_string/1)
      _ -> []
    end
  end

  defp validation_required?(run_state, %Contract{validation_gate: true}) do
    case Map.get(run_state, :validation_required) || Map.get(run_state, "validation_required") do
      value when is_boolean(value) ->
        value

      _ ->
        lane = lane(run_state)
        repo_changed?(run_state) and (code_bearing_changes?(changed_files(run_state)) or lane not in ["docs", "research"])
    end
  end

  defp validation_required?(_run_state, _contract), do: false

  defp lane(run_state) do
    run_state
    |> Map.get(:lane, Map.get(run_state, "lane", "unknown"))
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp validation_failure_allowed?(run_state) do
    Map.get(run_state, :validation_failure_allowed) == true or Map.get(run_state, "validation_failure_allowed") == true
  end

  defp validation_required_by_ticket?(run_state) do
    Map.get(run_state, :validation_required_by_ticket) == true or Map.get(run_state, "validation_required_by_ticket") == true
  end

  defp validation_status(run_state) do
    case Map.get(run_state, :validation_status) || Map.get(run_state, "validation_status") do
      status when status in [:passed, "passed"] -> :passed
      status when status in [:failed, "failed"] -> :failed
      status when status in [:allowed_failure, "allowed_failure"] -> :allowed_failure
      status when status in [:not_run, "not_run"] -> :not_run
      _ -> nil
    end
  end

  defp validation_evidence(run_state) do
    %{
      lane: lane(run_state),
      validation_required: Map.get(run_state, :validation_required),
      validation_status: Map.get(run_state, :validation_status),
      validation_reason: Map.get(run_state, :validation_reason),
      changed_files: changed_files(run_state)
    }
  end

  defp budget_exceeded?(run_state) do
    Map.get(run_state, :budget_state) in [:exceeded, "exceeded"] or
      numeric_budget_exceeded?(Map.get(run_state, :effective_tokens_total), Map.get(run_state, :effective_token_budget))
  end

  defp numeric_budget_exceeded?(tokens, budget) when is_integer(tokens) and is_integer(budget) and budget > 0, do: tokens > budget
  defp numeric_budget_exceeded?(_tokens, _budget), do: false

  defp budget_evidence(run_state) do
    %{
      budget_state: Map.get(run_state, :budget_state),
      effective_tokens_total: Map.get(run_state, :effective_tokens_total),
      effective_token_budget: Map.get(run_state, :effective_token_budget)
    }
  end

  defp generic_linear_graphql_calls(run_state) do
    case Map.get(run_state, :generic_linear_graphql_calls) || Map.get(run_state, "generic_linear_graphql_calls") do
      calls when is_list(calls) -> calls
      true -> [%{}]
      _ -> linear_graphql_call_count_entries(run_state)
    end
  end

  defp linear_graphql_call_count_entries(run_state) do
    count = Map.get(run_state, :linear_generic_graphql_calls) || Map.get(run_state, "linear_generic_graphql_calls")
    reasons = Map.get(run_state, :generic_graphql_fallback_reasons) || Map.get(run_state, "generic_graphql_fallback_reasons") || []

    cond do
      is_integer(count) and count > 0 and reasons == [] ->
        Enum.map(1..count, fn _ -> %{} end)

      is_integer(count) and count > 0 ->
        Enum.map(reasons, fn reason -> %{reason: reason} end)

      true ->
        []
    end
  end

  defp ticket_disables_pr?(run_state), do: !blank?(ticket_conflict(run_state))

  defp ticket_conflict(run_state) do
    text = Map.get(run_state, :ticket_text) || Map.get(run_state, "ticket_text") || ""

    Regex.run(~r/(no\s+(draft\s+)?pr\s+required|no\s+pull\s+request\s+required|no\s+branch\s+required)/i, text)
    |> case do
      [match | _] -> match
      _ -> nil
    end
  end

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false
end
