defmodule SymphonyElixir.Protocol.FinalizationGateTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Protocol.{Contract, FinalizationGate}

  @contract %Contract{}
  @states [
    %{name: "In Progress", id: "state-progress"},
    %{name: "Human Review", id: "state-review"},
    %{name: "Blocked", id: "state-blocked"},
    %{name: "Done", id: "state-done"}
  ]

  test "docs lane allows README change with PR and explicit skipped validation reason" do
    run_state =
      base_run_state(%{
        lane: "docs",
        changed_files: ["README.md"],
        validation_required: false,
        validation_status: :not_run,
        validation_reason: "docs-only/text-only change"
      })

    assert {:ok, result} = FinalizationGate.evaluate(run_state, "Human Review", @contract)
    assert result.finalization_gate_result == :ok
    assert result.pr_required == true
  end

  test "docs lane blocks file change without PR" do
    run_state =
      base_run_state(%{
        lane: "docs",
        changed_files: ["README.md"],
        pr_url: nil,
        pr_created: false,
        pr_posted_to_linear: false,
        validation_required: false,
        validation_status: :not_run,
        validation_reason: "docs-only/text-only change"
      })

    assert {:blocked, result} = FinalizationGate.evaluate(run_state, "Human Review", @contract)
    assert violation?(result, :pr_required_but_missing)
    assert result.final_state == "Blocked"
  end

  test "docs lane blocks unexpected source changes" do
    run_state =
      base_run_state(%{
        lane: "docs",
        changed_files: ["README.md", "lib/runtime.ex"],
        validation_required: false,
        validation_status: :not_run,
        validation_reason: "docs-only/text-only change"
      })

    assert {:blocked, result} = FinalizationGate.evaluate(run_state, "Human Review", @contract)
    assert violation?(result, :docs_lane_source_change)
  end

  test "docs lane ignores phase36 control artifact when checking source changes" do
    run_state =
      base_run_state(%{
        lane: "docs",
        changed_files: ["docs/foo.md", ".phase36/handoff.json"],
        validation_required: false,
        validation_status: :not_run,
        validation_reason: "docs-only/text-only change"
      })

    assert {:ok, result} = FinalizationGate.evaluate(run_state, "Human Review", @contract)
    refute violation?(result, :docs_lane_source_change)
    assert result.changed_files == ["docs/foo.md"]
  end

  test "docs lane still treats non-phase36 json as code config" do
    run_state =
      base_run_state(%{
        lane: "docs",
        changed_files: ["docs/foo.md", "config/example.json"],
        validation_required: false,
        validation_status: :not_run,
        validation_reason: "docs-only/text-only change"
      })

    assert {:blocked, result} = FinalizationGate.evaluate(run_state, "Human Review", @contract)
    assert violation?(result, :docs_lane_source_change)
  end

  test "feature lane blocks runtime change when validation is missing" do
    run_state =
      base_run_state(%{
        lane: "feature",
        changed_files: ["lib/product/runtime.ex"],
        validation_status: :not_run,
        tests_added: true
      })

    assert {:blocked, result} = FinalizationGate.evaluate(run_state, "Human Review", @contract)
    assert violation?(result, :validation_required_but_missing)
    assert violation?(result, :feature_validation_missing)
  end

  test "repo-changing lanes require branch commit pushed pr and Linear handoff before Human Review" do
    run_state =
      base_run_state(%{
        lane: "feature",
        changed_files: ["lib/product/runtime.ex"],
        branch_name: nil,
        commit_sha: nil,
        branch_pushed: false,
        pr_url: nil,
        pr_created: false,
        pr_posted_to_linear: false,
        handoff_posted: false,
        validation_status: :passed,
        tests_added: true
      })

    assert {:blocked, result} = FinalizationGate.evaluate(run_state, "Human Review", @contract)
    assert violation?(result, :branch_missing)
    assert violation?(result, :commit_missing)
    assert violation?(result, :branch_not_pushed)
    assert violation?(result, :pr_required_but_missing)
    assert violation?(result, :pr_url_not_posted_to_linear)
    assert violation?(result, :handoff_missing)
  end

  test "bug lane blocks fix without failure signal" do
    run_state =
      base_run_state(%{
        lane: "bug",
        changed_files: ["lib/product/runtime.ex"],
        validation_status: :passed,
        affected_files_inspected: true
      })

    assert {:blocked, result} = FinalizationGate.evaluate(run_state, "Human Review", @contract)
    assert violation?(result, :bug_failure_signal_identified)
  end

  test "refactor lane allows behavior-preserving validated PR" do
    run_state =
      base_run_state(%{
        lane: "refactor",
        changed_files: ["lib/product/runtime.ex"],
        validation_status: :passed,
        behavior_preservation_evidence: true,
        behavior_changed: false,
        scope_expanded: false
      })

    assert {:ok, result} = FinalizationGate.evaluate(run_state, "Human Review", @contract)
    assert result.finalization_gate_result == :ok
  end

  test "test lane allows test coverage update after targeted test run" do
    run_state =
      base_run_state(%{
        lane: "test",
        changed_files: ["test/product/runtime_test.exs"],
        validation_status: :passed,
        targeted_tests_run: true,
        test_coverage_added: true
      })

    assert {:ok, result} = FinalizationGate.evaluate(run_state, "Human Review", @contract)
    assert result.finalization_gate_result == :ok
  end

  test "chore lane blocks config change when validation is missing" do
    run_state =
      base_run_state(%{
        lane: "chore",
        changed_files: ["config/config.exs"],
        validation_status: :not_run
      })

    assert {:blocked, result} = FinalizationGate.evaluate(run_state, "Human Review", @contract)
    assert violation?(result, :validation_required_but_missing)
    assert violation?(result, :chore_validation_missing)
  end

  test "research lane with no repo changes can move to Human Review after findings are posted" do
    run_state =
      base_run_state(%{
        lane: "research",
        repo_changed: false,
        changed_files: [],
        branch_name: nil,
        commit_sha: nil,
        branch_pushed: false,
        pr_url: nil,
        pr_created: false,
        pr_posted_to_linear: false,
        validation_required: false,
        validation_status: :not_run,
        findings_posted: true,
        sources_inspected_listed: true,
        recommendation_included: true
      })

    assert {:ok, result} = FinalizationGate.evaluate(run_state, "Human Review", @contract)
    assert result.pr_required == false
  end

  test "research lane with committed markdown artifact and PR can move to Human Review" do
    run_state =
      base_run_state(%{
        lane: "research",
        changed_files: ["docs/research-report.md"],
        validation_required: false,
        validation_status: :not_run,
        validation_reason: "research markdown artifact only",
        findings_posted: true,
        sources_inspected_listed: true,
        recommendation_included: true
      })

    assert {:ok, result} = FinalizationGate.evaluate(run_state, "Human Review", @contract)
    assert result.pr_required == true
  end

  test "research lane with repo artifact blocks when PR is missing" do
    run_state =
      base_run_state(%{
        lane: "research",
        changed_files: ["docs/research-report.md"],
        pr_url: nil,
        pr_created: false,
        pr_posted_to_linear: false,
        validation_required: false,
        validation_status: :not_run,
        findings_posted: true,
        sources_inspected_listed: true,
        recommendation_included: true
      })

    assert {:blocked, result} = FinalizationGate.evaluate(run_state, "Human Review", @contract)
    assert violation?(result, :pr_required_but_missing)
  end

  test "ticket cannot disable workflow-required PR" do
    run_state =
      base_run_state(%{
        lane: "docs",
        changed_files: ["README.md"],
        pr_url: nil,
        ticket_text: "This is docs-only. no PR required.",
        validation_required: false,
        validation_status: :not_run,
        validation_reason: "docs-only/text-only change"
      })

    assert {:blocked, result} = FinalizationGate.evaluate(run_state, "Human Review", @contract)
    refute violation?(result, :ticket_conflicts_with_workflow_policy)
    assert warning?(result, :ticket_conflicts_with_workflow_policy)
    assert violation?(result, :pr_required_but_missing)
  end

  test "ticket PR conflict warns but allows Human Review when required PR artifacts exist" do
    run_state =
      base_run_state(%{
        lane: "docs",
        changed_files: ["README.md"],
        ticket_text: "This is docs-only. no PR required.",
        validation_required: false,
        validation_status: :not_run,
        validation_reason: "docs-only/text-only change"
      })

    assert {:ok, result} = FinalizationGate.evaluate(run_state, "Human Review", @contract)
    refute violation?(result, :ticket_conflicts_with_workflow_policy)
    assert warning?(result, :ticket_conflicts_with_workflow_policy)
    assert result.finalization_gate_result == :ok
  end

  test "generic GraphQL fallback emits warning when narrow helper was available and did not fail" do
    run_state =
      base_run_state(%{
        lane: "research",
        repo_changed: false,
        changed_files: [],
        validation_required: false,
        validation_status: :not_run,
        findings_posted: true,
        sources_inspected_listed: true,
        recommendation_included: true,
        generic_linear_graphql_calls: [
          %{
            operation: "moveIssue",
            fallback_reason: "state update",
            narrow_tool_available: true,
            narrow_tool_failed: false
          }
        ]
      })

    assert {:ok, result} = FinalizationGate.evaluate(run_state, "Human Review", @contract)
    assert warning?(result, :unnecessary_generic_linear_graphql)
  end

  test "budget exceeded before PR blocks deterministically" do
    run_state =
      base_run_state(%{
        lane: "docs",
        changed_files: ["README.md"],
        pr_url: nil,
        effective_tokens_total: 10_001,
        effective_token_budget: 10_000,
        validation_required: false,
        validation_status: :not_run,
        validation_reason: "docs-only/text-only change"
      })

    assert {:blocked, result} = FinalizationGate.evaluate(run_state, "Human Review", @contract)
    assert violation?(result, :budget_exceeded_before_pr)
  end

  test "invalid target state blocks with available state evidence" do
    run_state =
      base_run_state(%{
        available_states: [
          %{name: "Human Review", id: "state-review"},
          %{name: "Blocked", id: "state-blocked"},
          %{name: "Done", id: "state-done"}
        ]
      })

    assert {:blocked, result} = FinalizationGate.evaluate(run_state, "Needs Review", @contract)
    assert violation?(result, :state_not_found)
  end

  defp base_run_state(overrides) do
    %{
      lane: "feature",
      current_state: "In Progress",
      available_states: @states,
      repo_changed: true,
      changed_files: ["lib/example.ex"],
      branch_name: "agent/test",
      commit_sha: "abc123",
      branch_pushed: true,
      pr_url: "https://github.com/openai/symphony/pull/123",
      pr_created: true,
      pr_is_draft: true,
      pr_posted_to_linear: true,
      handoff_posted: true,
      validation_required: true,
      validation_status: :passed,
      validation_reason: "mix test",
      budget_state: :ok
    }
    |> Map.merge(overrides)
  end

  defp violation?(result, code) do
    Enum.any?(result.protocol_violations, &(&1.code == code))
  end

  defp warning?(result, code) do
    Enum.any?(result.protocol_warnings, &(&1.code == code))
  end
end
