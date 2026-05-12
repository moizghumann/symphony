defmodule SymphonyElixir.Phase36OrchestrationValidationTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.DynamicTool
  alias SymphonyElixir.{GitHubHandoff, JobPacket, LaneClassifier, LanePolicy, PromptBuilder}
  alias SymphonyElixir.Protocol.{Capsule, Contract, FinalizationGate}

  defmodule HandoffCommentIdLinearClient do
    def fetch_candidate_issues, do: {:ok, []}
    def fetch_issues_by_states(_states), do: {:ok, []}
    def fetch_issue_states_by_ids(_issue_ids), do: {:ok, []}

    def graphql(query, variables) do
      case Application.get_env(:symphony_elixir, :linear_client_recipient) do
        pid when is_pid(pid) -> send(pid, {:linear_client_graphql, query, variables})
        _ -> :ok
      end

      cond do
        String.contains?(query, "commentCreate") ->
          {:ok,
           %{
             "data" => %{
               "commentCreate" => %{
                 "success" => true,
                 "comment" => %{"id" => "comment-249"}
               }
             }
           }}

        String.contains?(query, "issueUpdate") ->
          {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
      end
    end
  end

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

  describe "GitHub handoff lane preservation" do
    test "prefers opts lane over inferred lane" do
      issue =
        handoff_issue(%{
          identifier: "AGE-2201",
          title: "Fix regression in checkout validation"
        })

      assert_handoff_reaches_human_review(issue, lane: "test")
    end

    test "prefers issue lane classification over inferred lane" do
      issue =
        handoff_issue(%{
          identifier: "AGE-2202",
          title: "Fix regression in checkout validation",
          lane_classification: %{lane: :test, reason: "preclassified test lane"}
        })

      assert_handoff_reaches_human_review(issue)
    end

    test "reads lane from valid phase36 handoff artifact when issue classification is absent" do
      issue =
        handoff_issue(%{
          identifier: "AGE-2203",
          title: "Fix regression in checkout validation"
        })

      assert_handoff_reaches_human_review(issue)
    end

    test "add regression tests handoff stays test lane" do
      issue = handoff_issue(%{identifier: "AGE-2204", title: "Add regression tests for handoff evidence"})
      classification = LaneClassifier.classify(issue)

      assert classification.lane == :test

      assert_handoff_reaches_human_review(%{issue | lane_classification: classification})
    end
  end

  describe "research read-only handoff routing" do
    test "valid read-only research handoff finalizes through Linear without GitHub PR handoff" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-phase36-research-linear-only-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        codex_binary = Path.join(test_root, "fake-codex")
        trace_file = Path.join(test_root, "codex.trace")

        File.mkdir_p!(workspace_root)

        File.write!(codex_binary, """
        #!/bin/sh
        trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"
        count=0

        while IFS= read -r line; do
          count=$((count + 1))
          printf 'JSON:%s\\n' "$line" >> "$trace_file"
          case "$count" in
            1)
              printf '%s\\n' '{"id":1,"result":{}}'
              ;;
            2)
              ;;
            3)
              printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-research-ready"}}}'
              ;;
            4)
              mkdir -p .phase36
              cat > .phase36/handoff.json <<'JSON'
        {
          "lane": "research",
          "linear_issue_identifier": "AGE-26",
          "status": "handoff_ready",
          "repo_changed": false,
          "branch_name": null,
          "commit_sha": null,
          "pr_url": null,
          "changed_files": [],
          "findings_posted": true,
          "sources_inspected_listed": true,
          "recommendation_included": true,
          "validation_status": "not_run",
          "validation_reason": "read-only research",
          "validation": {
            "required": false,
            "status": "not_run",
            "command": "not required",
            "reason": "read-only research"
          },
          "handoff": {
            "linear_comment_posted": true,
            "final_state_requested": "Human Review"
          },
          "protocol_notes": ["Findings posted to Linear handoff comment."]
        }
        JSON
              printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-research-ready"}}}'
              printf '%s\\n' '{"id":201,"method":"item/tool/call","params":{"name":"linear_post_handoff","callId":"call-handoff","threadId":"thread-research-ready","turnId":"turn-research-ready","arguments":{"issue_id":"issue-research-ready","body":"Findings: docs are clear. Sources: README.md. Recommendation: no repo change."}}}'
              ;;
            5)
              printf '%s\\n' '{"method":"codex/event/agent_message_content_delta","params":{"msg":{"delta":"SYMPHONY_HANDOFF_READY"}}}'
              printf '%s\\n' '{"method":"turn/completed"}'
              exit 0
              ;;
          esac
        done
        """)

        File.chmod!(codex_binary, 0o755)
        System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
        on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_kind: "linear",
          workspace_root: workspace_root,
          codex_command: "#{codex_binary} app-server",
          max_turns: 3
        )

        Application.put_env(:symphony_elixir, :linear_client_module, HandoffCommentIdLinearClient)
        Application.put_env(:symphony_elixir, :linear_client_recipient, self())
        on_exit(fn -> Application.delete_env(:symphony_elixir, :linear_client_recipient) end)

        issue = %Issue{
          id: "issue-research-ready",
          identifier: "AGE-26",
          title: "Investigate read-only handoff routing",
          description: "Read-only research. Post findings in Linear. No repository changes.",
          state: "In Progress",
          labels: ["research"],
          lane_classification: %{
            lane: :research,
            reason: "explicit research lane",
            matched_signals: ["label:research"],
            policy_version: "2026-05-10.phase3"
          },
          available_states: [%{id: "state-human-review", name: "Human Review"}]
        }

        assert :ok =
                 AgentRunner.run(issue, self(),
                   linear_lifecycle_graphql: &HandoffCommentIdLinearClient.graphql/2,
                   github_handoff: fn _workspace, _issue, _worker_host, _opts ->
                     flunk("GitHubHandoff must not run for read-only research")
                   end,
                   issue_state_fetcher: fn _issue_ids ->
                     flunk("research handoff marker should finalize without polling another turn")
                   end
                 )

        assert_receive {:linear_client_graphql, comment_query, %{issueId: "issue-research-ready", body: comment}}
        assert comment_query =~ "commentCreate"
        assert comment =~ "Findings:"
        assert comment =~ "Sources:"
        assert comment =~ "Recommendation:"

        assert_receive {:linear_client_graphql, update_query, %{issueId: "issue-research-ready", stateId: "state-human-review"}}
        assert update_query =~ "issueUpdate"

        assert_receive {:codex_worker_update, "issue-research-ready", %{event: :tool_call_completed, tool_name: "linear_post_handoff", tool_result: %{"success" => true}}}
        assert_receive {:codex_worker_update, "issue-research-ready", %{event: :linear_lifecycle_call, tool_name: "linear_move_to_human_review", tool_result: %{success: true}}}

        trace = File.read!(trace_file)
        refute trace =~ "No commits between"
      after
        File.rm_rf(test_root)
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

    test "research narrow Human Review lifecycle tool cannot bypass research evidence" do
      workspace = temp_workspace!()
      on_exit(fn -> File.rm_rf(workspace) end)

      issue =
        %Issue{
          id: "issue-research-tool-gate",
          state: "In Progress",
          available_states: [%{id: "state-review", name: "Human Review"}],
          lane_classification: %{lane: :research}
        }

      response =
        DynamicTool.execute(
          "linear_move_to_human_review",
          %{
            "issue_id" => "issue-research-tool-gate",
            "repo_changed" => false,
            "lane" => "research",
            "findings_posted" => true,
            "sources_inspected_listed" => true,
            "recommendation_included" => true,
            "validation_status" => "not_run",
            "validation_reason" => "read-only research"
          },
          issue: issue,
          workspace: workspace,
          linear_lifecycle_graphql: fn _query, _variables ->
            flunk("Linear state mutation should not run without the research handoff artifact")
          end
        )

      assert response["success"] == false
      output = Jason.decode!(response["output"])
      assert output["error"]["code"] == "finalization_gate_blocked"
      assert Enum.any?(output["error"]["protocol_violations"], &(&1["code"] == "research_findings_missing"))
    end

    test "research handoff artifact fields are extracted into narrow Human Review gate state" do
      workspace = temp_workspace!()
      on_exit(fn -> File.rm_rf(workspace) end)
      write_research_handoff_artifact!(workspace)
      test_pid = self()

      issue =
        %Issue{
          id: "issue-research-artifact-gate",
          state: "In Progress",
          available_states: [%{id: "state-review", name: "Human Review"}],
          lane_classification: %{lane: :research}
        }

      response =
        DynamicTool.execute(
          "linear_move_to_human_review",
          %{"issue_id" => "issue-research-artifact-gate", "lane" => "research"},
          issue: issue,
          workspace: workspace,
          linear_lifecycle_graphql: fn query, variables ->
            send(test_pid, {:linear_lifecycle_graphql_called, query, variables})
            {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
          end
        )

      assert_received {:linear_lifecycle_graphql_called, query, %{issueId: "issue-research-artifact-gate", stateId: "state-review"}}
      assert query =~ "issueUpdate"
      assert response["success"] == true
      assert Jason.decode!(response["output"])["state"] == "Human Review"
    end

    test "research Human Review lifecycle tool does not attempt Blocked to Human Review" do
      workspace = temp_workspace!()
      on_exit(fn -> File.rm_rf(workspace) end)
      write_research_handoff_artifact!(workspace)

      issue =
        %Issue{
          id: "issue-research-blocked",
          state: "Blocked",
          available_states: [%{id: "state-review", name: "Human Review"}],
          lane_classification: %{lane: :research}
        }

      response =
        DynamicTool.execute(
          "linear_move_to_human_review",
          %{"issue_id" => "issue-research-blocked", "lane" => "research"},
          issue: issue,
          workspace: workspace,
          linear_lifecycle_graphql: fn _query, _variables ->
            flunk("Linear state mutation should not run for Blocked -> Human Review")
          end
        )

      assert response["success"] == false
      output = Jason.decode!(response["output"])
      assert output["error"]["code"] == "finalization_gate_blocked"
      assert Enum.any?(output["error"]["protocol_violations"], &(&1["code"] == "illegal_state_transition"))
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

  defp temp_workspace! do
    workspace = Path.join(System.tmp_dir!(), "symphony-phase36-research-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)
    workspace
  end

  defp write_research_handoff_artifact!(workspace) do
    File.mkdir_p!(Path.join(workspace, ".phase36"))

    File.write!(
      Path.join(workspace, ".phase36/handoff.json"),
      Jason.encode!(
        %{
          "lane" => "research",
          "linear_issue_identifier" => "AGE-24",
          "status" => "handoff_ready",
          "repo_changed" => false,
          "branch_name" => nil,
          "commit_sha" => nil,
          "pr_url" => nil,
          "changed_files" => [],
          "findings_posted" => true,
          "sources_inspected_listed" => true,
          "recommendation_included" => true,
          "validation_status" => "not_run",
          "validation_reason" => "read-only research",
          "validation" => %{
            "required" => false,
            "status" => "not_run",
            "command" => "not required",
            "reason" => "read-only research"
          },
          "handoff" => %{
            "linear_comment_posted" => true,
            "final_state_requested" => "Human Review"
          },
          "protocol_notes" => ["Findings posted to Linear handoff comment."]
        },
        pretty: true
      )
    )
  end

  defp handoff_issue(overrides) do
    defaults = %{
      id: "issue-#{System.unique_integer([:positive])}",
      identifier: "AGE-22",
      title: "Add regression tests for validation",
      description: "Exercise the Phase 3.6 test lane handoff.",
      state: "In Progress",
      branch_name: "symphony/age-22-lane-preservation",
      labels: [],
      url: "https://linear.app/symphonys/issue/AGE-22"
    }

    struct!(Issue, Map.merge(defaults, overrides))
  end

  defp assert_handoff_reaches_human_review(%Issue{} = issue, opts \\ []) do
    test_root = Path.join(System.tmp_dir!(), "symphony-handoff-lane-preservation-#{System.unique_integer([:positive])}")
    previous_path = System.get_env("PATH")
    previous_gh_log = System.get_env("GH_LOG")

    try do
      repo = prepare_lane_handoff_repo!(test_root, issue.identifier)
      install_fake_gh!(test_root)

      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      assert {:ok, "https://github.com/example/repo/pull/22"} =
               GitHubHandoff.complete(repo, issue, nil, Keyword.merge([auto_publish_from_main: true], opts))

      assert_receive {:memory_tracker_comment, issue_id, comment}, 1_000
      assert issue_id == issue.id
      assert comment =~ "https://github.com/example/repo/pull/22"
      assert_receive {:memory_tracker_state_update, issue_id, "Human Review"}, 1_000
      assert issue_id == issue.id

      artifact = repo |> Path.join(".phase36/handoff.json") |> File.read!() |> Jason.decode!()
      assert artifact["lane"] == "test"
      assert artifact["handoff"]["final_state_requested"] == "Human Review"
    after
      restore_env("PATH", previous_path)
      restore_env("GH_LOG", previous_gh_log)
      File.rm_rf(test_root)
    end
  end

  defp prepare_lane_handoff_repo!(test_root, identifier) do
    repo = Path.join(test_root, "repo")
    origin = Path.join(test_root, "origin.git")

    File.mkdir_p!(Path.join(repo, "test/product"))
    File.write!(Path.join(repo, "README.md"), "# test\n")
    System.cmd("git", ["init", "-b", "main"], cd: repo)
    System.cmd("git", ["config", "user.name", "Test User"], cd: repo)
    System.cmd("git", ["config", "user.email", "test@example.com"], cd: repo)
    System.cmd("git", ["add", "README.md"], cd: repo)
    System.cmd("git", ["commit", "-m", "initial"], cd: repo)
    System.cmd("git", ["init", "--bare", origin])
    System.cmd("git", ["remote", "add", "origin", origin], cd: repo)
    System.cmd("git", ["push", "-u", "origin", "main"], cd: repo)

    File.write!(Path.join(repo, "test/product/runtime_test.exs"), "defmodule RuntimeTest do\n  use ExUnit.Case\n\n  test \"runtime\" do\n    assert true\n  end\nend\n")
    File.mkdir_p!(Path.join(repo, ".phase36"))
    File.write!(Path.join(repo, ".phase36/handoff.json"), phase36_test_handoff_artifact(identifier))

    repo
  end

  defp install_fake_gh!(test_root) do
    bin_dir = Path.join(test_root, "bin")
    gh_log = Path.join(test_root, "gh.log")
    File.mkdir_p!(bin_dir)

    File.write!(Path.join(bin_dir, "gh"), """
    #!/bin/sh
    printf '%s\\n' "$*" >> "$GH_LOG"
    if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
      printf 'no pull requests found\\n'
      exit 1
    fi
    if [ "$1" = "pr" ] && [ "$2" = "create" ]; then
      printf 'https://github.com/example/repo/pull/22\\n'
      exit 0
    fi
    exit 99
    """)

    File.chmod!(Path.join(bin_dir, "gh"), 0o755)
    System.put_env("PATH", bin_dir <> ":" <> (System.get_env("PATH") || ""))
    System.put_env("GH_LOG", gh_log)
  end

  defp phase36_test_handoff_artifact(identifier) do
    Jason.encode!(
      %{
        "lane" => "test",
        "linear_issue_identifier" => identifier,
        "status" => "repository_edit_complete_parent_handoff_pending",
        "repo_changed" => true,
        "branch_name" => nil,
        "commit_sha" => nil,
        "pr_url" => nil,
        "changed_files" => ["test/product/runtime_test.exs", ".phase36/handoff.json"],
        "targeted_tests_run" => true,
        "test_coverage_added" => true,
        "validation_status" => "passed",
        "validation_command" => "mix test test/product/runtime_test.exs",
        "validation_reason" => "Focused regression test coverage passed.",
        "validation" => %{
          "required" => true,
          "status" => "passed",
          "command" => "mix test test/product/runtime_test.exs",
          "reason" => "Focused regression test coverage passed."
        },
        "handoff" => %{
          "linear_comment_posted" => false,
          "final_state_requested" => false
        }
      },
      pretty: true
    )
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
