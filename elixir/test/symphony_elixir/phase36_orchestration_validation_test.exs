defmodule SymphonyElixir.Phase36OrchestrationValidationTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.DynamicTool
  alias SymphonyElixir.{GitHubHandoff, JobPacket, LaneClassifier, LanePolicy, PromptBuilder}
  alias SymphonyElixir.Protocol.{Capsule, Contract, FinalizationGate, Validation}

  @contract %Contract{}
  @states [
    %{name: "In Progress", id: "state-progress"},
    %{name: "Human Review", id: "state-review"},
    %{name: "Blocked", id: "state-blocked"},
    %{name: "Done", id: "state-done"}
  ]

  describe "lane classification validation matrix" do
    test "classifies required Phase 3.6 lane examples with reasons, signals, and policy version" do
      cases = [
        {"Update README contributor guidance", :docs},
        {"Fix analyzer crash on invalid URL", :bug},
        {"Add export button for agent card JSON", :feature},
        {"Refactor crawler retry logic without behavior changes", :refactor},
        {"Add regression tests for business map extraction", :test},
        {"Update validation script and CI config", :chore},
        {"Investigate whether onboarding docs are clear", :research}
      ]

      for {title, expected_lane} <- cases do
        issue = %Issue{id: "issue-#{expected_lane}", title: title, description: title, labels: []}

        assert %{lane: ^expected_lane, reason: reason, matched_signals: signals, policy_version: version} =
                 LaneClassifier.classify(issue)

        assert is_binary(reason) and reason != ""
        assert is_list(signals) and signals != []
        assert is_binary(version) and version != ""
      end
    end
  end

  describe "lane policy validation matrix" do
    test "protocol contract uses exact Agent Workbench statuses" do
      assert Contract.allowed_states() == [
               "Backlog",
               "Todo",
               "In Progress",
               "Human Review",
               "Rework",
               "Merging",
               "Blocked",
               "Done",
               "Duplicate",
               "Canceled"
             ]

      refute "Cancelled" in Contract.allowed_states()
    end

    test "every lane exposes budget, validation, PR, and context guidance" do
      for lane <- LanePolicy.lanes() do
        policy = LanePolicy.policy_for(lane)

        assert is_integer(policy.max_turns) and policy.max_turns > 0
        assert is_integer(policy.effective_token_budget) and policy.effective_token_budget > 0
        assert is_integer(policy.max_tool_calls) and policy.max_tool_calls > 0
        assert is_binary(policy.validation_policy) and policy.validation_policy != ""
        assert is_boolean(policy.pr_required)
        assert policy.allowed_paths != []
        assert policy.forbidden_paths != []
      end
    end

    test "lane policies preserve cross-lane workflow semantics" do
      docs = LanePolicy.policy_for(:docs)
      bug = LanePolicy.policy_for(:bug)
      feature = LanePolicy.policy_for(:feature)
      refactor = LanePolicy.policy_for(:refactor)
      test_lane = LanePolicy.policy_for(:test)
      chore = LanePolicy.policy_for(:chore)
      research = LanePolicy.policy_for(:research)

      assert docs.validation_policy == "optional"
      assert docs.pr_required
      assert docs.effective_token_budget <= 30_000

      assert bug.validation_policy == "required"
      assert Enum.any?(bug.required, &String.contains?(&1, "failure signal"))

      assert feature.validation_policy == "required"
      assert Enum.any?(feature.required, &String.contains?(&1, "tests"))
      assert Enum.any?(feature.required, &String.contains?(&1, "docs"))

      assert refactor.validation_policy == "required"
      assert Enum.any?(refactor.required, &String.contains?(&1, "preserve behavior"))

      assert test_lane.validation_policy == "required"
      assert Enum.any?(test_lane.required, &String.contains?(&1, "targeted tests"))

      assert chore.validation_policy == "conditional"
      assert Enum.any?(chore.required, &String.contains?(&1, "relevant validation"))

      refute research.pr_required
      assert Enum.any?(research.required, &String.contains?(&1, "read-only"))
    end
  end

  describe "finalization gate validation matrix" do
    test "required Phase 3.6 finalization cases are enforced" do
      cases = [
        {:allowed, %{lane: "docs", changed_files: ["README.md"], validation_required: false, validation_status: :not_run, validation_reason: "docs-only/text-only change"}},
        {:blocked, %{lane: "docs", changed_files: ["README.md"], pr_url: nil, validation_required: false, validation_status: :not_run, validation_reason: "docs-only/text-only change"},
         :pr_required_but_missing},
        {:blocked, %{lane: "feature", changed_files: ["lib/runtime.ex"], validation_status: :not_run, tests_added: true}, :validation_required_but_missing},
        {:blocked, %{lane: "bug", changed_files: ["lib/runtime.ex"], validation_status: :passed, affected_files_inspected: true}, :bug_failure_signal_identified},
        {:allowed, %{lane: "refactor", changed_files: ["lib/runtime.ex"], validation_status: :passed, behavior_preservation_evidence: true, behavior_changed: false, scope_expanded: false}},
        {:blocked, %{lane: "test", changed_files: ["test/runtime_test.exs"], validation_status: :passed, targeted_tests_run: false, test_coverage_added: true}, :tests_not_run},
        {:blocked, %{lane: "chore", changed_files: ["config/config.exs"], validation_status: :not_run}, :validation_required_but_missing},
        {:allowed,
         %{
           lane: "research",
           repo_changed: false,
           changed_files: [],
           branch_name: nil,
           commit_sha: nil,
           branch_pushed: false,
           pr_url: nil,
           pr_posted_to_linear: false,
           validation_required: false,
           validation_status: :not_run,
           findings_posted: true,
           sources_inspected_listed: true,
           recommendation_included: true
         }},
        {:blocked,
         %{
           lane: "research",
           changed_files: ["docs/research.md"],
           pr_url: nil,
           validation_required: false,
           validation_status: :not_run,
           findings_posted: true,
           sources_inspected_listed: true,
           recommendation_included: true
         }, :pr_required_but_missing}
      ]

      for {:allowed, overrides} <- Enum.filter(cases, &(elem(&1, 0) == :allowed)) do
        assert {:ok, result} = FinalizationGate.evaluate(run_state(overrides), "Human Review", @contract)
        assert result.finalization_gate_result == :ok
      end

      for {:blocked, overrides, expected_violation} <- Enum.filter(cases, &(elem(&1, 0) == :blocked)) do
        assert {:blocked, result} = FinalizationGate.evaluate(run_state(overrides), "Human Review", @contract)
        assert violation?(result, expected_violation)
      end
    end

    test "Phase 3.5 no-PR ticket text regressions remain fixed" do
      valid_pr_state =
        run_state(%{
          lane: "docs",
          changed_files: ["README.md"],
          ticket_text: "no PR required",
          validation_required: false,
          validation_status: :not_run,
          validation_reason: "docs-only/text-only change"
        })

      assert {:ok, valid_result} = FinalizationGate.evaluate(valid_pr_state, "Human Review", @contract)
      refute violation?(valid_result, :ticket_conflicts_with_workflow_policy)
      assert warning?(valid_result, :ticket_conflicts_with_workflow_policy)

      missing_pr_state = %{valid_pr_state | pr_url: nil, pr_posted_to_linear: false}
      assert {:blocked, missing_result} = FinalizationGate.evaluate(missing_pr_state, "Human Review", @contract)
      assert violation?(missing_result, :pr_required_but_missing)
      refute violation?(missing_result, :ticket_conflicts_with_workflow_policy)
      assert warning?(missing_result, :ticket_conflicts_with_workflow_policy)
    end

    test "test lane live-smoke validation artifact carries evidence into finalization gate" do
      workspace =
        Path.join(
          System.tmp_dir!(),
          "symphony-phase36-live-smoke-evidence-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(Path.join(workspace, ".git"))

      on_exit(fn ->
        File.rm_rf(workspace)
      end)

      validation_command =
        "cd elixir && mise exec -- mix test test/symphony_elixir/phase36_orchestration_validation_test.exs"

      validation_reason = "targeted Phase 3.6 live-smoke regression test passed"

      validation_artifact = %{
        "validation_status" => "passed",
        "validation_reason" => validation_reason,
        "validation_command" => validation_command,
        "targeted_tests_run" => true,
        "test_coverage_added" => true
      }

      File.write!(
        Path.join([workspace, ".git", "symphony-validation.json"]),
        Jason.encode!(validation_artifact)
      )

      changed_files = ["elixir/test/symphony_elixir/phase36_orchestration_validation_test.exs"]
      validation = Validation.summarize(workspace, changed_files, lane: "test")

      assert validation.validation_required == true
      assert validation.validation_status == :passed
      assert validation.validation_reason == validation_reason
      assert validation.validation_command == validation_command
      assert validation.targeted_tests_run == true
      assert validation.test_coverage_added == true

      run_state =
        run_state(
          Map.merge(validation, %{
            lane: "test",
            changed_files: changed_files
          })
        )

      assert {:ok, result} = FinalizationGate.evaluate(run_state, "Human Review", @contract)
      assert result.finalization_gate_result == :ok
    end

    test "GitHub handoff uses resolved test lane and live-smoke validation evidence" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-phase36-github-handoff-evidence-#{System.unique_integer([:positive])}"
        )

      previous_path = System.get_env("PATH")
      previous_gh_log = System.get_env("GH_LOG")

      try do
        repo = Path.join(test_root, "repo")
        origin = Path.join(test_root, "origin.git")
        bin_dir = Path.join(test_root, "bin")
        gh_log = Path.join(test_root, "gh.log")
        branch = "agent/phase36-test-evidence"

        File.mkdir_p!(Path.join(repo, "elixir/test/symphony_elixir"))
        File.mkdir_p!(bin_dir)
        File.write!(Path.join(repo, "README.md"), "# test\n")
        System.cmd("git", ["init", "-b", "main"], cd: repo)
        System.cmd("git", ["config", "user.name", "Test User"], cd: repo)
        System.cmd("git", ["config", "user.email", "test@example.com"], cd: repo)
        System.cmd("git", ["add", "README.md"], cd: repo)
        System.cmd("git", ["commit", "-m", "initial"], cd: repo)
        System.cmd("git", ["init", "--bare", origin])
        System.cmd("git", ["remote", "add", "origin", origin], cd: repo)
        System.cmd("git", ["push", "-u", "origin", "main"], cd: repo)

        System.cmd("git", ["switch", "-c", branch], cd: repo)

        File.write!(
          Path.join(repo, "elixir/test/symphony_elixir/phase36_orchestration_validation_test.exs"),
          """
          defmodule Phase36EvidenceTest do
            use ExUnit.Case

            test "live smoke evidence", do: assert(true)
          end
          """
        )

        System.cmd("git", ["add", "."], cd: repo)
        System.cmd("git", ["commit", "-m", "Add live smoke evidence regression"], cd: repo)
        System.cmd("git", ["push", "-u", "origin", branch], cd: repo)

        File.write!(
          Path.join(repo, ".git/symphony-validation.json"),
          Jason.encode!(%{
            "validation_status" => "passed",
            "validation_reason" => "targeted live-smoke evidence test passed",
            "validation_command" => "cd elixir && mise exec -- mix test test/symphony_elixir/phase36_orchestration_validation_test.exs",
            "targeted_tests_run" => true,
            "test_coverage_added" => true
          })
        )

        File.write!(Path.join(bin_dir, "gh"), """
        #!/bin/sh
        printf '%s\\n' "$*" >> "$GH_LOG"
        printf 'https://github.com/example/repo/pull/22\\n'
        """)

        File.chmod!(Path.join(bin_dir, "gh"), 0o755)
        System.put_env("PATH", bin_dir <> ":" <> (previous_path || ""))
        System.put_env("GH_LOG", gh_log)

        write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
        Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

        issue = %Issue{
          id: "issue-phase36-test-handoff",
          identifier: "AGE-22",
          title: "Add regression tests for Phase 3.6 live smoke evidence",
          state: "In Progress",
          lane_classification: %{lane: :test},
          available_states: @states
        }

        assert {:ok, "https://github.com/example/repo/pull/22"} = GitHubHandoff.complete(repo, issue)
        assert File.read!(gh_log) =~ "pr create --draft --head #{branch} --base main"
        assert_receive {:memory_tracker_comment, "issue-phase36-test-handoff", comment}
        assert comment =~ "https://github.com/example/repo/pull/22"
        assert_receive {:memory_tracker_state_update, "issue-phase36-test-handoff", "Human Review"}
      after
        restore_env("PATH", previous_path)
        restore_env("GH_LOG", previous_gh_log)
        Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
        File.rm_rf(test_root)
      end
    end
  end

  describe "budget and tool tracking validation" do
    test "effective token accounting excludes cached input and warns at 80 percent without treating raw total as burn" do
      issue_id = "issue-budget-warning"
      issue = %Issue{id: issue_id, identifier: "PH36-BUDGET", title: "Budget warning", state: "In Progress"}
      orchestrator_name = Module.concat(__MODULE__, :BudgetWarningOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid), do: Process.exit(pid, :normal)
      end)

      initial_state = :sys.get_state(pid)

      :sys.replace_state(pid, fn _ ->
        initial_state
        |> Map.put(:running, %{issue_id => running_entry(issue, effective_tokens_budget: 30_000)})
        |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
      end)

      send_token_usage(pid, issue_id, %{
        "input_tokens" => 100_000,
        "cached_input_tokens" => 80_000,
        "output_tokens" => 4_000,
        "total_tokens" => 104_000
      })

      assert %{running: [snapshot_entry]} = GenServer.call(pid, :snapshot)
      assert snapshot_entry.codex_total_tokens == 104_000
      assert snapshot_entry.codex_cached_input_tokens == 80_000
      assert snapshot_entry.codex_effective_tokens == 24_000
      assert snapshot_entry.budget_state == :warning
    end

    test "generic GraphQL warning and fallback semantics are visible" do
      unnecessary =
        run_state(%{
          lane: "research",
          repo_changed: false,
          changed_files: [],
          validation_required: false,
          validation_status: :not_run,
          findings_posted: true,
          sources_inspected_listed: true,
          recommendation_included: true,
          generic_linear_graphql_calls: [
            %{operation: "moveIssue", fallback_reason: "state update", narrow_tool_available: true, narrow_tool_failed: false}
          ]
        })

      assert {:ok, unnecessary_result} = FinalizationGate.evaluate(unnecessary, "Human Review", @contract)
      assert warning?(unnecessary_result, :unnecessary_generic_linear_graphql)

      fallback =
        put_in(unnecessary.generic_linear_graphql_calls, [
          %{operation: "moveIssue", fallback_reason: "narrow helper failed", narrow_tool_available: true, narrow_tool_failed: true}
        ])

      assert {:ok, fallback_result} = FinalizationGate.evaluate(fallback, "Human Review", @contract)
      refute warning?(fallback_result, :unnecessary_generic_linear_graphql)
      refute warning?(fallback_result, :generic_graphql_without_fallback_reason)
    end

    test "narrow Human Review lifecycle tool cannot bypass finalization artifacts" do
      issue = %Issue{id: "issue-tool-gate", state: "In Progress", available_states: [%{id: "state-review", name: "Human Review"}]}

      response =
        DynamicTool.execute(
          "linear_move_to_human_review",
          %{"issue_id" => "issue-tool-gate"},
          issue: issue,
          linear_lifecycle_graphql: fn _query, _variables ->
            flunk("Linear state mutation should not run when the finalization gate blocks")
          end
        )

      assert response["success"] == false
      output = Jason.decode!(response["output"])
      assert output["error"]["code"] == "finalization_gate_blocked"
      assert Enum.any?(output["error"]["protocol_violations"], &(&1["code"] == "pr_required_but_missing"))
    end
  end

  describe "Layer B dry-run orchestration simulations" do
    test "all seven lane simulations emit trace evidence without live Linear or GitHub mutation" do
      simulations = [
        docs: simulate("Update README contributor guidance", docs_ticket(), docs_artifacts()),
        bug: simulate("Fix crash when analyzer receives an invalid URL", bug_ticket(), bug_artifacts_without_signal()),
        feature: simulate("Add a copy button for generated agent card JSON", feature_ticket(), feature_artifacts()),
        refactor: simulate("Refactor crawler retry logic without changing behavior", refactor_ticket(), refactor_artifacts()),
        test: simulate("Add regression tests for business map extraction", test_ticket(), test_artifacts()),
        chore: simulate("Update validation script output formatting", chore_ticket(), chore_artifacts()),
        research: simulate("Investigate whether README onboarding is clear", research_ticket(), research_artifacts())
      ]

      for {lane, trace} <- simulations do
        assert trace.lane == Atom.to_string(lane)
        assert is_binary(trace.classification_reason) and trace.classification_reason != ""
        assert trace.job_packet_size_chars > 0
        assert trace.prompt_size_chars > trace.job_packet_size_chars
        assert trace.protocol_capsule_size_chars < trace.prompt_size_chars
        refute trace.universal_workflow_included
        assert trace.allowed_context != []
        assert trace.forbidden_context != []
        assert is_binary(trace.validation_policy)
        assert is_binary(trace.pr_policy)
        assert is_integer(trace.effective_token_budget)
        assert is_integer(trace.tool_call_budget)
        assert trace.generic_graphql_calls == 0
        assert trace.narrow_lifecycle_calls >= 1
        assert trace.finalization_gate_result in [:ok, :blocked]
        assert trace.final_state in ["Human Review", "Blocked"]
        assert is_binary(trace.finalization_reason)
      end

      assert simulations[:docs].finalization_gate_result == :ok
      assert simulations[:docs].validation_policy == "optional"
      assert simulations[:docs].pr_required == true

      assert simulations[:bug].finalization_gate_result == :blocked
      assert :bug_failure_signal_identified in simulations[:bug].protocol_violation_codes

      assert simulations[:feature].validation_policy == "required"
      assert simulations[:refactor].finalization_gate_result == :ok
      assert simulations[:test].finalization_gate_result == :ok
      assert simulations[:chore].validation_policy == "conditional"

      assert simulations[:research].finalization_gate_result == :ok
      assert simulations[:research].repo_changed == false
      assert simulations[:research].pr_required == false
    end
  end

  defp simulate(title, description, artifacts) do
    issue = %Issue{id: "issue-#{System.unique_integer([:positive])}", title: title, description: description, state: "In Progress", labels: []}
    classification = LaneClassifier.classify(issue)
    issue = %{issue | lane_classification: classification}
    policy = LanePolicy.policy_for(classification.lane)
    packet = JobPacket.compile(issue)
    job_packet = JobPacket.render_prompt(packet)
    prompt = PromptBuilder.build_prompt(issue)
    capsule = Capsule.render(Contract.current())
    run_state = run_state(Map.merge(%{lane: Atom.to_string(classification.lane)}, artifacts))

    {status, gate_result} = FinalizationGate.evaluate(run_state, "Human Review", @contract)

    %{
      lane: Atom.to_string(classification.lane),
      classification_reason: classification.reason,
      job_packet_size_chars: String.length(job_packet),
      prompt_size_chars: String.length(prompt),
      protocol_capsule_size_chars: String.length(capsule),
      universal_workflow_included: String.contains?(prompt, ["Phase 1:", "Phase 2:", "Phase 3:", "giant universal workflow"]),
      allowed_context: packet.allowed_files_directories,
      forbidden_context: packet.forbidden_files_directories,
      validation_policy: packet.validation_policy,
      pr_policy: packet.pr_policy,
      effective_token_budget: policy.effective_token_budget,
      tool_call_budget: policy.max_tool_calls,
      generic_graphql_calls: 0,
      narrow_lifecycle_calls: 2,
      finalization_gate_result: gate_result.finalization_gate_result,
      final_state: if(status == :ok, do: gate_result.final_state, else: @contract.blocked_state),
      finalization_reason: gate_result.finalization_reason,
      protocol_violation_codes: Enum.map(gate_result.protocol_violations, & &1.code),
      protocol_warning_codes: Enum.map(gate_result.protocol_warnings, & &1.code),
      repo_changed: gate_result.repo_changed,
      pr_required: gate_result.pr_required
    }
  end

  defp run_state(overrides) do
    %{
      current_state: "In Progress",
      available_states: @states,
      repo_changed: true,
      changed_files: ["lib/example.ex"],
      branch_name: "agent/phase36",
      commit_sha: "abc123",
      branch_pushed: true,
      pr_url: "https://github.com/moizghumann/symphony/pull/36",
      pr_posted_to_linear: true,
      handoff_posted: true,
      validation_required: true,
      validation_status: :passed,
      budget_state: :ok
    }
    |> Map.merge(overrides)
  end

  defp running_entry(%Issue{} = issue, overrides) do
    Map.merge(
      %{
        pid: self(),
        ref: make_ref(),
        identifier: issue.identifier,
        issue: issue,
        session_id: nil,
        turn_count: 0,
        tool_call_count: 0,
        tool_call_counts: %{shell: 0, linear_narrow: 0, linear_generic_graphql: 0, github: 0, file_edit: 0, other: 0},
        linear_generic_graphql_calls: 0,
        linear_narrow_tool_calls: 0,
        generic_graphql_fallback_reasons: [],
        issue_state_transitions: [],
        budget_state: :ok,
        last_codex_message: nil,
        last_codex_timestamp: nil,
        last_codex_event: nil,
        codex_input_tokens: 0,
        codex_cached_input_tokens: 0,
        codex_output_tokens: 0,
        codex_total_tokens: 0,
        codex_effective_tokens: 0,
        codex_last_effective_token_delta: 0,
        codex_last_reported_input_tokens: 0,
        codex_last_reported_cached_input_tokens: 0,
        codex_last_reported_output_tokens: 0,
        codex_last_reported_total_tokens: 0,
        codex_last_reported_effective_tokens: 0,
        started_at: DateTime.utc_now()
      },
      Map.new(overrides)
    )
  end

  defp send_token_usage(pid, issue_id, usage) do
    send(pid, {
      :codex_worker_update,
      issue_id,
      %{
        event: :notification,
        payload: %{
          "method" => "thread/tokenUsage/updated",
          "params" => %{"tokenUsage" => %{"total" => usage}}
        },
        timestamp: DateTime.utc_now()
      }
    })
  end

  defp docs_ticket do
    """
    ## Goal
    Update README with one sentence about contributors reading AGENTS.md.

    ## Scope
    Only edit README.md.

    ## Validation
    Do not run full validation.
    """
  end

  defp bug_ticket do
    """
    ## Goal
    Fix crash when analyzer receives an invalid URL.

    ## Scope
    Relevant analyzer path only.

    ## Validation
    Run npm run validate.
    """
  end

  defp feature_ticket do
    """
    ## Goal
    Add a copy button for generated agent card JSON.

    ## Scope
    Relevant UI and client logic only.

    ## Validation
    Run npm run validate.
    """
  end

  defp refactor_ticket do
    """
    ## Goal
    Refactor crawler retry logic without changing behavior.

    ## Scope
    Crawler retry internals only.

    ## Validation
    Run npm run validate.
    """
  end

  defp test_ticket do
    """
    ## Goal
    Add regression tests for business map extraction.

    ## Scope
    Tests only unless small fixture updates are needed.

    ## Validation
    Run targeted tests and npm run validate if needed.
    """
  end

  defp chore_ticket do
    """
    ## Goal
    Update validation script output formatting.

    ## Scope
    scripts only.

    ## Validation
    Run npm run validate.
    """
  end

  defp research_ticket do
    """
    ## Goal
    Investigate whether README onboarding is clear.

    ## Scope
    Read-only review.

    ## Output
    Post findings in Linear. No code changes.
    """
  end

  defp docs_artifacts do
    %{changed_files: ["README.md"], validation_required: false, validation_status: :not_run, validation_reason: "docs-only/text-only change"}
  end

  defp bug_artifacts_without_signal do
    %{changed_files: ["src/analyzer.ts"], validation_status: :passed, affected_files_inspected: true}
  end

  defp feature_artifacts do
    %{changed_files: ["src/ui/Card.tsx"], validation_status: :passed, behavior_changed: true, behavior_change_documented: true, tests_added: true}
  end

  defp refactor_artifacts do
    %{changed_files: ["src/crawler/retry.ts"], validation_status: :passed, behavior_preservation_evidence: true, behavior_changed: false, scope_expanded: false}
  end

  defp test_artifacts do
    %{changed_files: ["tests/business-map.test.ts"], validation_status: :passed, targeted_tests_run: true, test_coverage_added: true}
  end

  defp chore_artifacts do
    %{changed_files: ["scripts/validate.sh"], validation_status: :passed}
  end

  defp research_artifacts do
    %{
      repo_changed: false,
      changed_files: [],
      branch_name: nil,
      commit_sha: nil,
      branch_pushed: false,
      pr_url: nil,
      pr_posted_to_linear: false,
      validation_required: false,
      validation_status: :not_run,
      findings_posted: true,
      sources_inspected_listed: true,
      recommendation_included: true
    }
  end

  defp violation?(result, code), do: Enum.any?(result.protocol_violations, &(&1.code == code))
  defp warning?(result, code), do: Enum.any?(result.protocol_warnings, &(&1.code == code))
end
