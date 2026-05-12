defmodule Mix.Tasks.Phase36.LiveSmokeTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Phase36.LiveSmoke
  alias SymphonyElixir.Linear.Issue

  import ExUnit.CaptureIO

  setup do
    Mix.Task.reenable("phase36.live_smoke")
    Process.delete({__MODULE__, :phase36_issue_payload})
    Process.delete({__MODULE__, :phase36_issue_state})
    Process.delete({__MODULE__, :phase36_issue_comments})
    :ok
  end

  test "supports all seven Phase 3.6 lanes and refuses unknown lanes" do
    assert LiveSmoke.supported_lane_names() == ["docs", "bug", "feature", "refactor", "test", "chore", "research"]

    assert_raise Mix.Error, ~r/Unsupported Phase 3.6 live-smoke lane "unknown"/, fn ->
      LiveSmoke.run_with_deps(["--lane", "unknown"], inert_deps())
    end
  end

  test "runs exactly selected lanes from PHASE36_SMOKE_LANES" do
    Enum.each(
      [
        {"docs,test,research", ["docs", "test", "research"]},
        {"bug,feature,refactor,chore", ["bug", "feature", "refactor", "chore"]},
        {"docs,bug,feature,refactor,test,chore,research", ["docs", "bug", "feature", "refactor", "test", "chore", "research"]}
      ],
      fn {selector, expected_lanes} ->
        output_path = temp_output_path()

        deps =
          inert_deps(%{
            getenv: selector_env(selector),
            github_preflight: fn -> :ok end,
            linear_graphql: &fake_linear_graphql/2,
            run_agent: fn issue, preflight, _output_path ->
              assert issue.state == "In Progress"
              assert issue.state_id == preflight.state_ids["In Progress"]

              {:ok, artifact_runner_result(issue)}
            end,
            write_file: &File.write!/2
          })

        assert :ok = LiveSmoke.run_with_deps(["--output", output_path], deps)

        evidence = output_path |> File.read!() |> Jason.decode!()
        assert evidence["requested_lanes"] == expected_lanes
        assert evidence["preflight"]["requested_lanes"] == expected_lanes
        assert evidence["preflight"]["supported_lanes"] == LiveSmoke.supported_lane_names()
        assert Enum.map(evidence["results"], & &1["lane"]) == expected_lanes

        File.rm(output_path)
      end
    )
  end

  test "rejects empty and duplicate lane selectors before mutation" do
    empty_deps =
      inert_deps(%{
        getenv: fn
          "RUN_REAL_SMOKE" -> "true"
          "CONFIRM_LIVE_SMOKE_MUTATION" -> "true"
          "LINEAR_API_KEY" -> "linear-token"
          "GH_TOKEN" -> "gh-token"
          "GITHUB_TOKEN" -> nil
          "PHASE36_SMOKE_LANES" -> "   "
          _ -> nil
        end,
        github_preflight: fn -> flunk("github preflight should not run") end,
        local_socket_preflight: fn -> flunk("local socket preflight should not run") end,
        linear_graphql: fn _query, _variables -> flunk("linear preflight should not run") end
      })

    assert_raise Mix.Error, ~r/Empty Phase 3\.6 live-smoke lane selector is not allowed\./, fn ->
      LiveSmoke.run_with_deps([], empty_deps)
    end

    duplicate_deps =
      inert_deps(%{
        getenv: selector_env("docs,docs"),
        github_preflight: fn -> flunk("github preflight should not run") end,
        local_socket_preflight: fn -> flunk("local socket preflight should not run") end,
        linear_graphql: fn _query, _variables -> flunk("linear preflight should not run") end
      })

    assert_raise Mix.Error, ~r/Duplicate live-smoke lanes are not allowed: docs, docs/, fn ->
      LiveSmoke.run_with_deps([], duplicate_deps)
    end
  end

  test "requires exactly Canceled spelling in Agent Workbench statuses" do
    valid_states = Enum.map(LiveSmoke.expected_status_names(), &%{"name" => &1})
    assert :ok = LiveSmoke.validate_agent_workbench_statuses(valid_states)

    invalid_states =
      LiveSmoke.expected_status_names()
      |> Enum.map(fn
        "Canceled" -> %{"name" => "Cancelled"}
        name -> %{"name" => name}
      end)

    assert {:error, diff} = LiveSmoke.validate_agent_workbench_statuses(invalid_states)
    assert diff.missing == ["Canceled"]
    assert diff.unexpected == ["Cancelled"]
  end

  test "aborts before issue creation when Mix PubSub local socket preflight fails" do
    deps =
      inert_deps(%{
        getenv: selector_env("docs"),
        github_preflight: fn -> :ok end,
        local_socket_preflight: fn -> {:error, :eperm} end,
        linear_graphql: fn query, _variables ->
          refute String.contains?(query, "Phase36LiveSmokeCreateIssue")
          flunk("Linear preflight should not run after local socket failure")
        end
      })

    assert_raise Mix.Error, ~r/Mix PubSub\/local socket preflight failed before issue creation: :eperm/, fn ->
      LiveSmoke.run_with_deps(["--output", temp_output_path()], deps)
    end
  end

  test "prints plan before refusing missing mutation confirmation" do
    deps =
      inert_deps(%{
        getenv: fn
          "RUN_REAL_SMOKE" -> "true"
          "CONFIRM_LIVE_SMOKE_MUTATION" -> nil
          "LINEAR_API_KEY" -> "linear-token"
          "GH_TOKEN" -> "gh-token"
          "GITHUB_TOKEN" -> nil
          _ -> nil
        end
      })

    output =
      capture_io(fn ->
        assert_raise Mix.Error, ~r/CONFIRM_LIVE_SMOKE_MUTATION must be true/, fn ->
          LiveSmoke.run_with_deps([], deps)
        end
      end)

    assert output =~ "Phase 3.6 live-smoke plan"
    assert output =~ "Lanes: docs, test, research"
  end

  test "resolves project id, slug, URL slug, and display name in that order" do
    cases = [
      %{
        label: "project id",
        env: %{
          "PHASE36_LINEAR_PROJECT_ID" => "project-by-id",
          "PHASE36_LINEAR_PROJECT_SLUG" => "ignored-slug",
          "PHASE36_LINEAR_PROJECT_NAME" => "Ignored Name"
        },
        project_query: "Phase36LiveSmokeProjectById",
        project: project_payload("project-by-id", "Id Project", "id-project", "https://linear.app/project/id-project")
      },
      %{
        label: "project slug",
        env: %{
          "PHASE36_LINEAR_PROJECT_SLUG" => "slug-project",
          "PHASE36_LINEAR_PROJECT_NAME" => "Ignored Name"
        },
        project_query: "Phase36LiveSmokeProjectBySlug",
        project: project_payload("project-by-slug", "Slug Project", "slug-project", "https://linear.app/project/slug-project")
      },
      %{
        label: "URL slug",
        env: %{
          "PHASE36_LINEAR_PROJECT_NAME" => "https://linear.app/acme/project/url-project"
        },
        project_query: "Phase36LiveSmokeProjectBySlug",
        project: project_payload("project-by-url", "URL Project", "url-project", "https://linear.app/project/url-project")
      },
      %{
        label: "display name",
        env: %{
          "PHASE36_LINEAR_PROJECT_NAME" => "Symphony Agent Queue"
        },
        slug_probe: "Symphony Agent Queue",
        project_query: "Phase36LiveSmokeProjectByName",
        project: project_payload("project-by-name", "Symphony Agent Queue", "symphony-agent-queue", "https://linear.app/project/symphony-agent-queue")
      }
    ]

    Enum.each(cases, fn case_data ->
      output_path = temp_output_path()

      deps =
        inert_deps(%{
          getenv: case_selector_env(case_data.env),
          github_preflight: fn -> :ok end,
          linear_graphql: fn query, variables ->
            project_resolution_graphql(query, variables, case_data)
          end,
          run_agent: fn issue, preflight, _output_path ->
            assert preflight.project["id"] == case_data.project["id"]
            assert preflight.project["name"] == case_data.project["name"]
            assert preflight.project["slugId"] == case_data.project["slugId"]
            assert preflight.project["url"] == case_data.project["url"]

            {:ok, artifact_runner_result(issue)}
          end,
          write_file: &File.write!/2
        })

      assert :ok = LiveSmoke.run_with_deps(["--output", output_path], deps)

      evidence = output_path |> File.read!() |> Jason.decode!()
      assert evidence["preflight"]["project_id"] == case_data.project["id"]
      assert evidence["preflight"]["project_name"] == case_data.project["name"]
      assert evidence["preflight"]["project_slug"] == case_data.project["slugId"]
      assert evidence["preflight"]["project_url"] == case_data.project["url"]

      File.rm(output_path)
    end)
  end

  test "refreshes Todo issues to In Progress before AgentRunner" do
    output_path = temp_output_path()
    issue_state = Agent.start_link(fn -> %{"state" => %{"id" => "state-todo", "name" => "Todo"}} end) |> elem(1)

    deps =
      inert_deps(%{
        getenv: selector_env("docs"),
        github_preflight: fn -> :ok end,
        linear_graphql: fn query, variables ->
          stateful_linear_graphql(query, variables, issue_state)
        end,
        move_issue_to_state: fn issue, "In Progress" ->
          Agent.update(issue_state, fn _ -> %{"state" => %{"id" => "state-in-progress", "name" => "In Progress"}} end)
          send(self(), {:moved_issue, issue.identifier, issue.state, issue.state_id})
          :ok
        end,
        run_agent: fn issue, preflight, _output_path ->
          assert issue.state == "In Progress"
          assert issue.state_id == preflight.state_ids["In Progress"]

          {:ok, artifact_runner_result(issue)}
        end,
        write_file: &File.write!/2
      })

    assert :ok = LiveSmoke.run_with_deps(["--output", output_path], deps)
    assert_received {:moved_issue, "AWB-123", "Todo", "state-todo"}

    evidence = output_path |> File.read!() |> Jason.decode!()
    assert evidence["preflight"]["state_ids"]["Todo"] == "state-todo"
    assert evidence["preflight"]["state_ids"]["In Progress"] == "state-in-progress"

    assert evidence["results"]
           |> Enum.map(& &1["handoff_artifact_valid"])
           |> Enum.all?(&(&1 == true))

    File.rm(output_path)
  end

  test "accepts a valid docs handoff artifact" do
    output_path = temp_output_path()

    deps =
      inert_deps(%{
        getenv: selector_env("docs"),
        github_preflight: fn -> :ok end,
        linear_graphql: &fake_linear_graphql/2,
        run_agent: fn issue, _preflight, _output_path ->
          {:ok,
           artifact_runner_result(
             issue,
             {:artifact, %{"lane" => "docs", "changed_files" => ["docs/validation/phase-3-6-orchestration-validation.md", ".phase36/handoff.json"]}},
             %{"changed_files" => ["docs/validation/phase-3-6-orchestration-validation.md", ".phase36/handoff.json"]}
           )}
        end,
        write_file: &File.write!/2
      })

    assert :ok = LiveSmoke.run_with_deps(["--output", output_path], deps)

    evidence = output_path |> File.read!() |> Jason.decode!()
    [lane_result] = evidence["results"]
    assert lane_result["handoff_artifact_valid"] == true
    assert lane_result["finalization_gate_result"] == "ok"
    assert lane_result["runner_status"] == "ok"
    assert lane_result["lane_contract_status"] == "passed"
    assert lane_result["completion_states"]["codex_process_started"] == true
    assert lane_result["completion_states"]["codex_prompt_delivered"] == true
    assert lane_result["completion_states"]["codex_work_observed"] == true
    assert lane_result["completion_states"]["symphony_handoff_ready_seen"] == true
    assert lane_result["completion_states"]["lane_contract_satisfied"] == true
    assert lane_result["sandbox_policy_type"] == "workspaceWrite"
    assert lane_result["active_workspace_git_root_writable_probe"]["status"] == "ok"
    assert lane_result["active_workspace_git_root"] in lane_result["sandbox_writable_roots"]
    assert lane_result["repo_changed"] == true
    assert lane_result["product_changed_files"] == ["docs/validation/phase-3-6-orchestration-validation.md"]
    assert lane_result["control_artifacts"] == [".phase36/handoff.json"]
    refute Enum.any?(lane_result["protocol_violations"], &(&1["code"] == "missing_handoff_artifact"))
    refute Enum.any?(lane_result["protocol_violations"], &(&1["code"] == "docs_lane_source_change"))

    File.rm(output_path)
  end

  test "fails a lane when the handoff artifact is missing" do
    output_path = temp_output_path()

    deps =
      inert_deps(%{
        getenv: selector_env("docs"),
        github_preflight: fn -> :ok end,
        linear_graphql: &fake_linear_graphql/2,
        run_agent: fn _issue, _preflight, _output_path ->
          workspace_path = temp_workspace_path()
          File.mkdir_p!(workspace_path)

          {:ok,
           %{
             "workspace_path" => workspace_path,
             "tool_call_count" => 1,
             "generic_linear_graphql_calls" => 0,
             "narrow_linear_lifecycle_calls" => 1,
             "budget_state" => "ok",
             "changed_files" => ["docs/validation/phase-3-6-orchestration-validation.md"]
           }}
        end,
        write_file: &File.write!/2
      })

    assert :ok = LiveSmoke.run_with_deps(["--output", output_path], deps)

    evidence = output_path |> File.read!() |> Jason.decode!()
    [lane_result] = evidence["results"]
    assert lane_result["handoff_artifact_valid"] == false
    assert lane_result["finalization_gate_result"] == "blocked"
    assert lane_result["runner_status"] == "error"
    assert lane_result["lane_contract_status"] == "failed"
    assert lane_result["blocked_transition"]["status"] == "blocked"
    assert Enum.any?(lane_result["protocol_violations"], &(&1["code"] == "missing_handoff_artifact"))

    File.rm(output_path)
  end

  test "fails and blocks when process starts but prompt work and handoff are not observed" do
    output_path = temp_output_path()

    deps =
      inert_deps(%{
        getenv: selector_env("docs"),
        github_preflight: fn -> :ok end,
        linear_graphql: &fake_linear_graphql/2,
        run_agent: fn _issue, _preflight, _output_path ->
          workspace_path = temp_workspace_path()
          File.mkdir_p!(workspace_path)

          {:ok,
           %{
             "workspace_path" => workspace_path,
             "codex_app_server_pid" => "12345",
             "tool_call_count" => 0,
             "generic_linear_graphql_calls" => 0,
             "narrow_linear_lifecycle_calls" => 0,
             "budget_state" => "ok",
             "changed_files" => []
           }}
        end,
        write_file: &File.write!/2
      })

    assert :ok = LiveSmoke.run_with_deps(["--output", output_path], deps)

    evidence = output_path |> File.read!() |> Jason.decode!()
    [lane_result] = evidence["results"]
    assert lane_result["runner_status"] == "error"
    assert lane_result["lane_contract_status"] == "failed"
    assert lane_result["finalization_gate_result"] == "blocked"
    assert lane_result["completion_states"]["codex_process_started"] == true
    assert lane_result["completion_states"]["codex_prompt_delivered"] == false
    assert lane_result["completion_states"]["codex_work_observed"] == false
    assert lane_result["completion_states"]["symphony_handoff_ready_seen"] == false
    assert lane_result["completion_states"]["lane_contract_satisfied"] == false
    assert lane_result["blocked_transition"]["status"] == "blocked"
    assert current_issue_state()["name"] == "Blocked"
    assert Enum.any?(lane_result["protocol_violations"], &(&1["code"] == "codex_prompt_not_delivered"))

    File.rm(output_path)
  end

  test "fails and blocks when process exits zero without handoff artifact" do
    output_path = temp_output_path()

    deps =
      inert_deps(%{
        getenv: selector_env("docs"),
        github_preflight: fn -> :ok end,
        linear_graphql: &fake_linear_graphql/2,
        run_agent: fn _issue, _preflight, _output_path ->
          workspace_path = temp_workspace_path()
          File.mkdir_p!(workspace_path)

          {:ok,
           %{
             "workspace_path" => workspace_path,
             "codex_app_server_pid" => "12345",
             "tool_call_count" => 1,
             "generic_linear_graphql_calls" => 0,
             "narrow_linear_lifecycle_calls" => 1,
             "budget_state" => "ok",
             "changed_files" => ["docs/validation/phase-3-6-orchestration-validation.md"],
             "completion_states" => %{
               "codex_process_started" => true,
               "codex_prompt_delivered" => true,
               "codex_work_observed" => true,
               "symphony_handoff_ready_seen" => false
             }
           }}
        end,
        write_file: &File.write!/2
      })

    assert :ok = LiveSmoke.run_with_deps(["--output", output_path], deps)

    evidence = output_path |> File.read!() |> Jason.decode!()
    [lane_result] = evidence["results"]
    assert lane_result["runner_status"] == "error"
    assert lane_result["lane_contract_status"] == "failed"
    assert lane_result["blocked_transition"]["status"] == "blocked"
    assert Enum.any?(lane_result["protocol_violations"], &(&1["code"] == "missing_handoff_artifact"))
    assert Enum.any?(lane_result["protocol_violations"], &(&1["code"] == "symphony_handoff_ready_not_seen"))

    File.rm(output_path)
  end

  test "fails and blocks when docs prompt is delivered without product repo change" do
    output_path = temp_output_path()

    deps =
      inert_deps(%{
        getenv: selector_env("docs"),
        github_preflight: fn -> :ok end,
        linear_graphql: &fake_linear_graphql/2,
        run_agent: fn issue, _preflight, _output_path ->
          {:ok,
           artifact_runner_result(
             issue,
             {:artifact, %{"lane" => "docs", "changed_files" => []}},
             %{"changed_files" => []}
           )}
        end,
        write_file: &File.write!/2
      })

    assert :ok = LiveSmoke.run_with_deps(["--output", output_path], deps)

    evidence = output_path |> File.read!() |> Jason.decode!()
    [lane_result] = evidence["results"]
    assert lane_result["runner_status"] == "error"
    assert lane_result["lane_contract_status"] == "failed"
    assert lane_result["completion_states"]["codex_prompt_delivered"] == true
    assert lane_result["completion_states"]["symphony_handoff_ready_seen"] == true
    assert lane_result["product_changed_files"] == []
    assert lane_result["blocked_transition"]["status"] == "blocked"
    assert Enum.any?(lane_result["protocol_violations"], &(&1["code"] == "lane_contract_product_repo_change_missing"))

    File.rm(output_path)
  end

  test "stops the requested wave after the first failed lane" do
    output_path = temp_output_path()
    agent_runs = Agent.start_link(fn -> [] end) |> elem(1)

    deps =
      inert_deps(%{
        getenv: selector_env("docs,test,research"),
        github_preflight: fn -> :ok end,
        linear_graphql: &fake_linear_graphql/2,
        run_agent: fn issue, _preflight, _output_path ->
          Agent.update(agent_runs, &[issue.identifier | &1])
          workspace_path = temp_workspace_path()
          File.mkdir_p!(workspace_path)

          {:ok,
           %{
             "workspace_path" => workspace_path,
             "tool_call_count" => 1,
             "generic_linear_graphql_calls" => 0,
             "narrow_linear_lifecycle_calls" => 1,
             "budget_state" => "ok",
             "changed_files" => ["docs/validation/phase-3-6-orchestration-validation.md"]
           }}
        end,
        write_file: &File.write!/2
      })

    assert :ok = LiveSmoke.run_with_deps(["--output", output_path], deps)

    evidence = output_path |> File.read!() |> Jason.decode!()
    assert Enum.map(evidence["results"], & &1["lane"]) == ["docs"]
    assert Agent.get(agent_runs, &length/1) == 1
    assert hd(evidence["results"])["finalization_gate_result"] == "blocked"

    File.rm(output_path)
  end

  test "fails a lane when the handoff artifact contains invalid json" do
    output_path = temp_output_path()

    deps =
      inert_deps(%{
        getenv: selector_env("docs"),
        github_preflight: fn -> :ok end,
        linear_graphql: &fake_linear_graphql/2,
        run_agent: fn issue, _preflight, _output_path ->
          {:ok, artifact_runner_result(issue, {:raw, "{not-json"})}
        end,
        write_file: &File.write!/2
      })

    assert :ok = LiveSmoke.run_with_deps(["--output", output_path], deps)

    evidence = output_path |> File.read!() |> Jason.decode!()
    [lane_result] = evidence["results"]
    assert lane_result["handoff_artifact_valid"] == false
    assert lane_result["finalization_gate_result"] == "blocked"
    assert Enum.any?(lane_result["protocol_violations"], &(&1["code"] == "invalid_handoff_artifact_json"))
    assert lane_result["control_artifacts"] == [".phase36/handoff.json"]

    File.rm(output_path)
  end

  test "accepts a research read-only artifact" do
    output_path = temp_output_path()

    deps =
      inert_deps(%{
        getenv: selector_env("research"),
        github_preflight: fn -> :ok end,
        linear_graphql: &fake_linear_graphql/2,
        run_agent: fn issue, _preflight, _output_path ->
          {:ok,
           artifact_runner_result(
             issue,
             {:artifact,
              %{
                "lane" => "research",
                "repo_changed" => false,
                "branch_name" => nil,
                "commit_sha" => nil,
                "pr_url" => nil,
                "changed_files" => [],
                "validation" => %{
                  "required" => false,
                  "status" => "not_run",
                  "command" => "not required",
                  "reason" => "read-only research lane"
                },
                "handoff" => %{
                  "linear_comment_posted" => true,
                  "final_state_requested" => "Human Review"
                },
                "protocol_notes" => ["Findings posted to Linear handoff comment."]
              }},
             %{"changed_files" => []}
           )}
        end,
        write_file: &File.write!/2
      })

    assert :ok = LiveSmoke.run_with_deps(["--output", output_path], deps)

    evidence = output_path |> File.read!() |> Jason.decode!()
    [lane_result] = evidence["results"]
    assert lane_result["handoff_artifact_valid"] == true
    assert lane_result["finalization_gate_result"] == "ok"
    assert lane_result["repo_changed"] == false
    refute Enum.any?(lane_result["protocol_violations"], &(&1["code"] == "research_findings_evidence_required"))

    File.rm(output_path)
  end

  test "timeout creates failure evidence and blocks the lane" do
    output_path = temp_output_path()
    workspace_path = temp_workspace_path()
    File.mkdir_p!(workspace_path)

    deps =
      inert_deps(%{
        getenv: selector_env("docs"),
        github_preflight: fn -> :ok end,
        linear_graphql: &fake_linear_graphql/2,
        lane_runtime_ms: 1,
        heartbeat_interval_ms: 1,
        workspace_path_for_issue: fn _issue -> workspace_path end,
        inspect_workspace_git: fn ^workspace_path ->
          %{
            "workspace_path" => workspace_path,
            "status" => " M docs/validation/phase-3-6-orchestration-validation.md",
            "branch_name" => "agent/docs-timeout",
            "commit_sha" => "0123456789abcdef0123456789abcdef01234567",
            "changed_files" => ["docs/validation/phase-3-6-orchestration-validation.md"]
          }
        end,
        run_agent: fn _issue, _preflight, _output_path ->
          receive do
          after
            5_000 -> {:ok, %{}}
          end
        end,
        write_file: &File.write!/2
      })

    assert :ok = LiveSmoke.run_with_deps(["--output", output_path], deps)

    evidence = output_path |> File.read!() |> Jason.decode!()
    [lane_result] = evidence["results"]
    assert lane_result["runner_status"] == "timeout"
    assert lane_result["finalization_gate_result"] == "blocked"
    assert get_in(lane_result, ["supervision", "status"]) == "timeout"
    assert get_in(lane_result, ["timeout_diagnostics", "git", "status"]) =~ "docs/validation"
    assert get_in(lane_result, ["timeout_diagnostics", "blocked_transition", "status"]) == "blocked"
    assert Enum.any?(lane_result["protocol_violations"], &(&1["code"] == "lane_runtime_timeout"))

    File.rm(output_path)
  end

  test "fails when GitHub PR verification does not match the artifact" do
    output_path = temp_output_path()

    deps =
      inert_deps(%{
        getenv: selector_env("docs"),
        github_preflight: fn -> :ok end,
        linear_graphql: &fake_linear_graphql/2,
        github_verify: fn _artifact, _context ->
          {:ok,
           %{
             "branch_exists" => true,
             "commit_exists" => true,
             "pr_exists" => true,
             "pr_draft" => false,
             "pr_base_ref" => "develop",
             "pr_title" => "missing issue link",
             "pr_body" => "missing issue link",
             "changed_files" => ["lib/symphony_elixir/agent_runner.ex"]
           }}
        end,
        run_agent: fn issue, _preflight, _output_path ->
          {:ok, artifact_runner_result(issue)}
        end,
        write_file: &File.write!/2
      })

    assert :ok = LiveSmoke.run_with_deps(["--output", output_path], deps)

    evidence = output_path |> File.read!() |> Jason.decode!()
    [lane_result] = evidence["results"]
    assert lane_result["finalization_gate_result"] == "blocked"
    assert Enum.any?(lane_result["protocol_violations"], &(&1["code"] == "github_pr_not_draft"))
    assert Enum.any?(lane_result["protocol_violations"], &(&1["code"] == "github_pr_wrong_base"))
    assert Enum.any?(lane_result["protocol_violations"], &(&1["code"] == "github_changed_files_mismatch"))

    File.rm(output_path)
  end

  test "fails when Linear final state verification does not match" do
    output_path = temp_output_path()

    deps =
      inert_deps(%{
        getenv: selector_env("docs"),
        github_preflight: fn -> :ok end,
        linear_graphql: &fake_linear_graphql/2,
        linear_verify: fn _issue, _artifact, _snapshot, _context ->
          {:ok,
           %{
             "final_state" => "In Progress",
             "handoff_comment_exists" => true,
             "blocker_comment_exists" => false,
             "pr_url_posted" => true,
             "research_findings_posted" => true
           }}
        end,
        run_agent: fn issue, _preflight, _output_path ->
          {:ok, artifact_runner_result(issue)}
        end,
        write_file: &File.write!/2
      })

    assert :ok = LiveSmoke.run_with_deps(["--output", output_path], deps)

    evidence = output_path |> File.read!() |> Jason.decode!()
    [lane_result] = evidence["results"]
    assert lane_result["finalization_gate_result"] == "blocked"
    assert Enum.any?(lane_result["protocol_violations"], &(&1["code"] == "linear_state_mismatch"))

    File.rm(output_path)
  end

  test "fails repo-changing artifact without pr evidence" do
    output_path = temp_output_path()

    deps =
      inert_deps(%{
        getenv: selector_env("docs"),
        github_preflight: fn -> :ok end,
        linear_graphql: &fake_linear_graphql/2,
        run_agent: fn issue, _preflight, _output_path ->
          {:ok,
           artifact_runner_result(
             issue,
             {:artifact, %{"lane" => "docs", "pr_url" => nil}},
             %{"changed_files" => ["docs/validation/phase-3-6-orchestration-validation.md"]}
           )}
        end,
        write_file: &File.write!/2
      })

    assert :ok = LiveSmoke.run_with_deps(["--output", output_path], deps)

    evidence = output_path |> File.read!() |> Jason.decode!()
    [lane_result] = evidence["results"]
    assert lane_result["finalization_gate_result"] == "blocked"
    assert Enum.any?(lane_result["protocol_violations"], &(&1["code"] == "repo_change_artifact_missing_git_fields"))
    assert Enum.any?(lane_result["protocol_violations"], &(&1["code"] == "github_pr_missing"))

    File.rm(output_path)
  end

  test "fails docs validation skip without reason" do
    output_path = temp_output_path()

    deps =
      inert_deps(%{
        getenv: selector_env("docs"),
        github_preflight: fn -> :ok end,
        linear_graphql: &fake_linear_graphql/2,
        run_agent: fn issue, _preflight, _output_path ->
          {:ok,
           artifact_runner_result(
             issue,
             {:artifact,
              %{
                "lane" => "docs",
                "validation" => %{
                  "required" => false,
                  "status" => "not_run",
                  "command" => "not required",
                  "reason" => nil
                }
              }}
           )}
        end,
        write_file: &File.write!/2
      })

    assert :ok = LiveSmoke.run_with_deps(["--output", output_path], deps)

    evidence = output_path |> File.read!() |> Jason.decode!()
    [lane_result] = evidence["results"]
    assert lane_result["finalization_gate_result"] == "blocked"
    assert Enum.any?(lane_result["protocol_violations"], &(&1["code"] == "docs_validation_reason_required"))

    File.rm(output_path)
  end

  test "fails repo_changed false while git reports changes" do
    output_path = temp_output_path()

    deps =
      inert_deps(%{
        getenv: selector_env("docs"),
        github_preflight: fn -> :ok end,
        linear_graphql: &fake_linear_graphql/2,
        run_agent: fn issue, _preflight, _output_path ->
          {:ok,
           artifact_runner_result(
             issue,
             {:artifact,
              %{
                "lane" => "docs",
                "repo_changed" => false,
                "branch_name" => nil,
                "commit_sha" => nil,
                "pr_url" => nil,
                "changed_files" => []
              }},
             %{"changed_files" => ["docs/validation/phase-3-6-orchestration-validation.md"]}
           )}
        end,
        write_file: &File.write!/2
      })

    assert :ok = LiveSmoke.run_with_deps(["--output", output_path], deps)

    evidence = output_path |> File.read!() |> Jason.decode!()
    [lane_result] = evidence["results"]
    assert lane_result["finalization_gate_result"] == "blocked"
    assert Enum.any?(lane_result["protocol_violations"], &(&1["code"] == "repo_change_artifact_mismatch"))

    File.rm(output_path)
  end

  test "writes evidence with missing fields instead of faking success" do
    output_path = temp_output_path()
    agent_runs = Agent.start_link(fn -> [] end) |> elem(1)

    deps =
      inert_deps(%{
        github_preflight: fn -> :ok end,
        linear_graphql: &fake_linear_graphql/2,
        run_agent: fn issue, _preflight, _output_path ->
          Agent.update(agent_runs, &[issue.identifier | &1])

          {:ok, artifact_runner_result(issue)}
        end,
        write_file: &File.write!/2
      })

    assert :ok = LiveSmoke.run_with_deps(["--output", output_path], deps)

    evidence = output_path |> File.read!() |> Jason.decode!()
    assert evidence["requested_lanes"] == ["docs", "test", "research"]
    assert length(evidence["results"]) == 3
    assert evidence["preflight"]["supported_lanes"] == LiveSmoke.supported_lane_names()
    assert Map.has_key?(evidence["preflight"]["state_ids"], "Todo")
    assert Map.has_key?(evidence["preflight"]["state_ids"], "In Progress")
    assert Map.has_key?(evidence["preflight"]["state_ids"], "Human Review")
    assert Map.has_key?(evidence["preflight"]["state_ids"], "Blocked")
    assert Enum.all?(evidence["results"], &("effective_tokens" in &1["missing_evidence"]))
    assert Enum.all?(evidence["results"], &(is_list(&1["code_seams_needed"]) and &1["code_seams_needed"] != []))

    File.rm(output_path)
  end

  test "generated live workflow grants git metadata writes to the managed workspace" do
    workflow = LiveSmoke.live_workflow_for_test("c7cc9de0cbf2", System.tmp_dir!())
    assert workflow =~ "writableRoots:"
    assert workflow =~ ".git"
    assert workflow =~ "networkAccess: true"
  end

  test "live-smoke Codex preflight records sandbox policy and writable git probe" do
    workspace_path = temp_workspace_path()
    git_root = Path.join(workspace_path, ".git")
    File.mkdir_p!(git_root)

    write_live_smoke_workflow!(Path.dirname(workspace_path), workspace_path)

    issue = %Issue{lane_classification: %{lane: :docs}}

    assert {:ok, canonical_workspace_path} =
             SymphonyElixir.PathSafety.canonicalize(workspace_path)

    assert {:ok, canonical_git_root} =
             SymphonyElixir.PathSafety.canonicalize(git_root)

    assert {:ok, metadata} =
             LiveSmoke.live_smoke_codex_start_preflight_for_test(canonical_workspace_path, issue, nil)

    assert metadata["sandbox_policy_type"] == "workspaceWrite"
    assert metadata["active_workspace_path"] == canonical_workspace_path
    assert metadata["active_workspace_git_root"] == canonical_git_root
    assert metadata["active_workspace_git_root_writable_probe"]["status"] == "ok"
    assert canonical_git_root in metadata["sandbox_writable_roots"]

    File.rm_rf(workspace_path)
  end

  test "live-smoke Codex preflight blocks repo-changing lanes before Codex when git root is missing" do
    workspace_path = temp_workspace_path()
    File.mkdir_p!(workspace_path)

    write_live_smoke_workflow!(Path.dirname(workspace_path), workspace_path)

    issue = %Issue{lane_classification: %{lane: :docs}}

    assert {:error, "active_workspace_git_root_missing", metadata} =
             LiveSmoke.live_smoke_codex_start_preflight_for_test(workspace_path, issue, nil)

    assert metadata["active_workspace_git_root_writable_probe"]["status"] == "missing"

    File.rm_rf(workspace_path)
  end

  test "evidence includes active sandbox roots and failed git probe" do
    output_path = temp_output_path()
    workspace_path = temp_workspace_path()
    git_root = Path.join(workspace_path, ".git")

    deps =
      inert_deps(%{
        getenv: selector_env("docs"),
        github_preflight: fn -> :ok end,
        linear_graphql: &fake_linear_graphql/2,
        run_agent: fn _issue, _preflight, _output_path ->
          {:error,
           {:before_codex_start_failed, "active_workspace_git_root_not_writable"},
           %{
             "workspace_path" => workspace_path,
             "active_workspace_path" => workspace_path,
             "active_workspace_git_root" => git_root,
             "active_workspace_git_root_writable_probe" => %{
               "status" => "error",
               "path" => Path.join(git_root, ".probe"),
               "reason" => ":eacces"
             },
             "sandbox_policy_type" => "workspaceWrite",
             "sandbox_writable_roots" => [workspace_path, git_root],
             "completion_states" => %{
               "codex_process_started" => false,
               "codex_prompt_delivered" => false,
               "codex_work_observed" => false,
               "symphony_handoff_ready_seen" => false
             }
           }}
        end,
        write_file: &File.write!/2
      })

    assert :ok = LiveSmoke.run_with_deps(["--output", output_path], deps)

    evidence = output_path |> File.read!() |> Jason.decode!()
    [lane_result] = evidence["results"]
    assert lane_result["runner_status"] == "error"
    assert lane_result["finalization_gate_result"] == "blocked"
    assert lane_result["blocked_transition"]["status"] == "blocked"
    assert lane_result["sandbox_policy_type"] == "workspaceWrite"
    assert lane_result["sandbox_writable_roots"] == [workspace_path, git_root]
    assert lane_result["active_workspace_path"] == workspace_path
    assert lane_result["active_workspace_git_root"] == git_root
    assert lane_result["active_workspace_git_root_writable_probe"]["status"] == "error"

    File.rm(output_path)
  end

  defp inert_deps(overrides \\ %{}) do
    Map.merge(
      %{
        getenv: fn
          "RUN_REAL_SMOKE" -> "true"
          "CONFIRM_LIVE_SMOKE_MUTATION" -> "true"
          "LINEAR_API_KEY" -> "linear-token"
          "GH_TOKEN" -> "gh-token"
          "GITHUB_TOKEN" -> nil
          _ -> nil
        end,
        github_preflight: fn -> flunk("github preflight should not run") end,
        local_socket_preflight: fn -> :ok end,
        linear_graphql: fn _query, _variables -> flunk("linear preflight should not run") end,
        github_verify: &valid_github_verification/2,
        linear_verify: &valid_linear_verification/4,
        inspect_workspace_git: &fake_workspace_git/1,
        workspace_path_for_issue: fn _issue -> nil end,
        move_issue_to_state: fn _issue, state ->
          Process.put({__MODULE__, :phase36_issue_state}, state_payload(state))
          :ok
        end,
        post_handoff_comment: fn _issue, body ->
          Process.put({__MODULE__, :phase36_issue_comments}, [%{"id" => "comment-blocker", "url" => "https://linear.app/comment/blocker", "body" => body}])
          :ok
        end,
        run_agent: fn _issue, _preflight, _output_path -> flunk("agent should not run") end,
        write_file: fn _path, _body -> :ok end,
        lane_runtime_ms: 60_000,
        heartbeat_interval_ms: 1_000,
        monotonic_time: fn -> System.monotonic_time(:millisecond) end,
        now: fn -> ~U[2026-05-11 00:00:00Z] end,
        shell: Mix.shell()
      },
      overrides
    )
  end

  defp temp_output_path do
    Path.join(System.tmp_dir!(), "phase36-live-smoke-test-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}.json")
  end

  defp selector_env(selector) do
    fn
      "RUN_REAL_SMOKE" -> "true"
      "CONFIRM_LIVE_SMOKE_MUTATION" -> "true"
      "LINEAR_API_KEY" -> "linear-token"
      "GH_TOKEN" -> "gh-token"
      "GITHUB_TOKEN" -> nil
      "PHASE36_SMOKE_LANES" -> selector
      _ -> nil
    end
  end

  defp case_selector_env(env_map) do
    fn
      "RUN_REAL_SMOKE" -> Map.get(env_map, "RUN_REAL_SMOKE", "true")
      "CONFIRM_LIVE_SMOKE_MUTATION" -> Map.get(env_map, "CONFIRM_LIVE_SMOKE_MUTATION", "true")
      "LINEAR_API_KEY" -> Map.get(env_map, "LINEAR_API_KEY", "linear-token")
      "GH_TOKEN" -> Map.get(env_map, "GH_TOKEN", "gh-token")
      "GITHUB_TOKEN" -> Map.get(env_map, "GITHUB_TOKEN", nil)
      key -> Map.get(env_map, key)
    end
  end

  defp artifact_runner_result(issue, artifact_mode \\ :valid, telemetry_overrides \\ %{}) do
    workspace_path = temp_workspace_path()
    File.mkdir_p!(workspace_path)
    File.mkdir_p!(Path.join(workspace_path, ".phase36"))
    File.mkdir_p!(Path.join(workspace_path, ".git"))

    case artifact_mode do
      :missing ->
        :ok

      {:raw, body} when is_binary(body) ->
        File.write!(Path.join(workspace_path, ".phase36/handoff.json"), body)

      {:artifact, overrides} when is_map(overrides) ->
        issue
        |> default_handoff_artifact()
        |> deep_merge(overrides)
        |> write_handoff_artifact!(workspace_path)

      :valid ->
        issue
        |> default_handoff_artifact()
        |> write_handoff_artifact!(workspace_path)
    end

    Map.merge(
      %{
        "workspace_path" => workspace_path,
        "tool_call_count" => 1,
        "generic_linear_graphql_calls" => 0,
        "narrow_linear_lifecycle_calls" => 1,
        "budget_state" => "ok",
        "changed_files" => ["docs/validation/phase-3-6-orchestration-validation.md"],
        "sandbox_policy_type" => "workspaceWrite",
        "sandbox_writable_roots" => [workspace_path, Path.join(workspace_path, ".git")],
        "active_workspace_path" => workspace_path,
        "active_workspace_git_root" => Path.join(workspace_path, ".git"),
        "active_workspace_git_root_writable_probe" => %{"status" => "ok", "path" => Path.join(workspace_path, ".git/.probe")},
        "codex_app_server_pid" => "12345",
        "completion_states" => %{
          "codex_process_started" => true,
          "codex_prompt_delivered" => true,
          "codex_work_observed" => true,
          "symphony_handoff_ready_seen" => true
        }
      },
      telemetry_overrides
    )
  end

  defp temp_workspace_path do
    Path.join(System.tmp_dir!(), "phase36-live-smoke-workspace-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}")
  end

  defp write_live_smoke_workflow!(workspace_root, issue_workspace) do
    original_workflow_path = SymphonyElixir.Workflow.workflow_file_path()
    workflow_path = Path.join(issue_workspace, "WORKFLOW.md")

    File.mkdir_p!(issue_workspace)

    on_exit(fn ->
      SymphonyElixir.Workflow.set_workflow_file_path(original_workflow_path)
      File.rm_rf(issue_workspace)
    end)

    File.write!(workflow_path, LiveSmoke.live_workflow_for_test("phase36", workspace_root))
    SymphonyElixir.Workflow.set_workflow_file_path(workflow_path)
  end

  defp valid_github_verification(artifact, context) do
    issue = Map.fetch!(context, :issue)
    pr_url = Map.get(artifact, "pr_url")

    {:ok,
     %{
       "branch_exists" => not is_nil(Map.get(artifact, "branch_name")),
       "commit_exists" => not is_nil(Map.get(artifact, "commit_sha")),
       "pr_exists" => is_binary(pr_url) and pr_url != "",
       "pr_draft" => true,
       "pr_base_ref" => "main",
       "pr_title" => "#{issue.identifier}: #{issue.title}",
       "pr_body" => "Linear issue: #{issue.url}",
       "changed_files" => Map.get(context, :changed_files) || []
     }}
  end

  defp valid_linear_verification(_issue, _artifact, _snapshot, context) do
    expected_state = Map.fetch!(context, :expected_final_state)
    blocked? = expected_state == "Blocked"

    {:ok,
     %{
       "final_state" => expected_state,
       "handoff_comment_exists" => not blocked?,
       "blocker_comment_exists" => blocked?,
       "pr_url_posted" => true,
       "research_findings_posted" => true
     }}
  end

  defp fake_workspace_git(workspace_path) do
    %{
      "workspace_path" => workspace_path,
      "status" => "",
      "branch_name" => nil,
      "commit_sha" => nil,
      "changed_files" => []
    }
  end

  defp default_handoff_artifact(issue) do
    lane = issue_lane(issue)

    base =
      %{
        "lane" => lane,
        "linear_issue_identifier" => issue.identifier,
        "status" => "handoff_ready",
        "repo_changed" => lane != "research",
        "branch_name" => issue.branch_name || "agent/#{lane}-artifact",
        "commit_sha" => "0123456789abcdef0123456789abcdef01234567",
        "pr_url" => "https://github.com/moizghumann/symphony/pull/7",
        "changed_files" => ["docs/validation/phase-3-6-orchestration-validation.md"],
        "validation" => %{
          "required" => lane not in ["docs", "research"],
          "status" => if(lane == "docs" or lane == "research", do: "not_run", else: "passed"),
          "command" => default_validation_command(lane),
          "reason" => default_validation_reason(lane)
        },
        "handoff" => %{
          "linear_comment_posted" => true,
          "final_state_requested" => default_final_state(lane)
        },
        "protocol_notes" => default_protocol_notes(lane)
      }
      |> Map.merge(default_lane_evidence(lane))

    case lane do
      "research" ->
        base
        |> Map.put("repo_changed", false)
        |> Map.put("branch_name", nil)
        |> Map.put("commit_sha", nil)
        |> Map.put("pr_url", nil)
        |> Map.put("changed_files", [])

      _ ->
        base
    end
  end

  defp write_handoff_artifact!(artifact, workspace_path) do
    File.write!(Path.join(workspace_path, ".phase36/handoff.json"), Jason.encode!(artifact, pretty: true))
  end

  defp default_validation_command("docs"), do: "not required"
  defp default_validation_command("research"), do: "not required"
  defp default_validation_command(_lane), do: "cd elixir && mise exec -- mix test test/mix/tasks/phase36_live_smoke_test.exs"

  defp default_validation_reason("docs"), do: "docs-only change"
  defp default_validation_reason("research"), do: "read-only research lane"
  defp default_validation_reason(_lane), do: nil

  defp default_final_state("research"), do: "Human Review"
  defp default_final_state(_lane), do: "Human Review"

  defp default_protocol_notes("research"), do: ["Findings posted to Linear handoff comment."]
  defp default_protocol_notes("refactor"), do: ["Behavior-preservation evidence recorded."]
  defp default_protocol_notes("bug"), do: ["Failure signal captured before the fix."]
  defp default_protocol_notes("feature"), do: ["User-visible feature evidence recorded."]
  defp default_protocol_notes("test"), do: ["Focused regression test coverage recorded."]
  defp default_protocol_notes("chore"), do: ["Maintenance-only scope and validation recorded."]
  defp default_protocol_notes(_lane), do: ["Phase 3.6 handoff artifact recorded."]

  defp default_lane_evidence("research") do
    %{
      "findings_posted" => true,
      "sources_inspected_listed" => true,
      "recommendation_included" => true
    }
  end

  defp default_lane_evidence("feature"), do: %{"tests_added" => true, "scope_expanded" => false}

  defp default_lane_evidence("bug") do
    %{
      "failure_signal_identified" => true,
      "affected_files_inspected" => true
    }
  end

  defp default_lane_evidence("refactor") do
    %{
      "behavior_preservation_evidence" => true,
      "behavior_changed" => false,
      "scope_expanded" => false
    }
  end

  defp default_lane_evidence("test"), do: %{"targeted_tests_run" => true, "test_coverage_added" => true}
  defp default_lane_evidence(_lane), do: %{}

  defp issue_lane(issue) do
    case Regex.run(~r/Lane:\s*([a-z]+)/, issue.description || "") do
      [_, lane] ->
        lane

      _ ->
        title_lane(issue.title) || issue.lane_classification.lane |> Atom.to_string()
    end
  end

  defp title_lane("Docs live smoke" <> _rest), do: "docs"
  defp title_lane("Add regression tests" <> _rest), do: "test"
  defp title_lane("Fix Phase 3.6 live smoke" <> _rest), do: "bug"
  defp title_lane("Feature live smoke" <> _rest), do: "feature"
  defp title_lane("Refactor live smoke" <> _rest), do: "refactor"
  defp title_lane("Chore live smoke" <> _rest), do: "chore"
  defp title_lane("Research live smoke" <> _rest), do: "research"
  defp title_lane(_title), do: nil

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      if is_map(left_value) and is_map(right_value) do
        deep_merge(left_value, right_value)
      else
        right_value
      end
    end)
  end

  defp fake_linear_graphql(query, variables) do
    cond do
      String.contains?(query, "Phase36LiveSmokeViewer") ->
        {:ok, %{"data" => %{"viewer" => %{"id" => "viewer-1", "name" => "Moiz", "email" => "moiz@example.com"}}}}

      String.contains?(query, "Phase36LiveSmokeTeam") ->
        {:ok, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "team-1", "name" => variables.name, "states" => %{"nodes" => states()}}]}}}}

      String.contains?(query, "Phase36LiveSmokeProjectById") ->
        {:ok, %{"data" => %{"projects" => %{"nodes" => [project_payload(variables.id, "Symphony Agent Queue", "phase36", "https://linear.app/project/phase36")]}}}}

      String.contains?(query, "Phase36LiveSmokeProjectBySlug") ->
        case variables.slug do
          "Symphony Agent Queue" -> {:ok, %{"data" => %{"projects" => %{"nodes" => []}}}}
          _ -> {:ok, %{"data" => %{"projects" => %{"nodes" => [project_payload("project-1", "Symphony Agent Queue", variables.slug, "https://linear.app/project/#{variables.slug}")]}}}}
        end

      String.contains?(query, "Phase36LiveSmokeProjectByName") ->
        {:ok, %{"data" => %{"projects" => %{"nodes" => [project_payload("project-1", variables.name, "phase36", "https://linear.app/project")]}}}}

      String.contains?(query, "Phase36LiveSmokeCreateIssue") ->
        issue = issue_payload(variables.title, variables.description)
        remember_issue(issue)
        {:ok, %{"data" => %{"issueCreate" => %{"success" => true, "issue" => issue}}}}

      String.contains?(query, "Phase36LiveSmokeIssue") ->
        {:ok, %{"data" => %{"issue" => issue_snapshot(variables.id, current_issue_state())}}}
    end
  end

  defp project_resolution_graphql(query, variables, case_data) do
    cond do
      String.contains?(query, "Phase36LiveSmokeViewer") ->
        {:ok, %{"data" => %{"viewer" => %{"id" => "viewer-1", "name" => "Moiz", "email" => "moiz@example.com"}}}}

      String.contains?(query, "Phase36LiveSmokeTeam") ->
        {:ok, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "team-1", "key" => "AWB", "name" => "Agent Workbench", "states" => %{"nodes" => states()}}]}}}}

      String.contains?(query, "Phase36LiveSmokeProjectById") ->
        case case_data.label do
          "project id" ->
            assert variables.id == case_data.project["id"]
            {:ok, %{"data" => %{"projects" => %{"nodes" => [case_data.project]}}}}

          _ ->
            flunk("unexpected project id lookup for #{case_data.label}")
        end

      String.contains?(query, "Phase36LiveSmokeProjectBySlug") ->
        case case_data.label do
          "project slug" ->
            assert variables.slug == case_data.project["slugId"]
            {:ok, %{"data" => %{"projects" => %{"nodes" => [case_data.project]}}}}

          "URL slug" ->
            assert variables.slug == case_data.project["slugId"]
            {:ok, %{"data" => %{"projects" => %{"nodes" => [case_data.project]}}}}

          "display name" when variables.slug == "Symphony Agent Queue" ->
            {:ok, %{"data" => %{"projects" => %{"nodes" => []}}}}

          _ ->
            flunk("unexpected project slug lookup for #{case_data.label} with #{inspect(variables)}")
        end

      String.contains?(query, "Phase36LiveSmokeProjectByName") ->
        case case_data.label do
          "display name" -> {:ok, %{"data" => %{"projects" => %{"nodes" => [case_data.project]}}}}
          _ -> flunk("unexpected project name lookup for #{case_data.label}")
        end

      String.contains?(query, "Phase36LiveSmokeCreateIssue") ->
        issue = issue_payload(variables.title, variables.description)
        remember_issue(issue)
        {:ok, %{"data" => %{"issueCreate" => %{"success" => true, "issue" => issue}}}}

      String.contains?(query, "Phase36LiveSmokeIssue") ->
        {:ok, %{"data" => %{"issue" => issue_snapshot(variables.id, current_issue_state())}}}
    end
  end

  defp stateful_linear_graphql(query, variables, issue_state) do
    cond do
      String.contains?(query, "Phase36LiveSmokeViewer") ->
        {:ok, %{"data" => %{"viewer" => %{"id" => "viewer-1", "name" => "Moiz", "email" => "moiz@example.com"}}}}

      String.contains?(query, "Phase36LiveSmokeTeam") ->
        {:ok, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "team-1", "key" => "AWB", "name" => "Agent Workbench", "states" => %{"nodes" => states()}}]}}}}

      String.contains?(query, "Phase36LiveSmokeProjectBySlug") ->
        {:ok, %{"data" => %{"projects" => %{"nodes" => [project_payload("project-1", "Symphony Agent Queue", "phase36", "https://linear.app/project/phase36")]}}}}

      String.contains?(query, "Phase36LiveSmokeProjectByName") ->
        {:ok, %{"data" => %{"projects" => %{"nodes" => [project_payload("project-1", "Symphony Agent Queue", "phase36", "https://linear.app/project/phase36")]}}}}

      String.contains?(query, "Phase36LiveSmokeCreateIssue") ->
        issue = issue_payload(variables.title, variables.description)
        Agent.update(issue_state, fn _ -> %{"state" => %{"id" => "state-todo", "name" => "Todo"}} end)
        remember_issue(issue)
        {:ok, %{"data" => %{"issueCreate" => %{"success" => true, "issue" => issue}}}}

      String.contains?(query, "Phase36LiveSmokeIssue") ->
        {:ok,
         %{
           "data" => %{
             "issue" =>
               current_issue_payload()
               |> Map.put("id", variables.id)
               |> Map.put("identifier", "AWB-123")
               |> Map.put("state", Agent.get(issue_state, & &1["state"]))
               |> Map.put("comments", %{"nodes" => []})
           }
         }}
    end
  end

  defp project_payload(id, name, slug_id, url) do
    %{"id" => id, "name" => name, "slugId" => slug_id, "url" => url}
  end

  defp states do
    Enum.map(LiveSmoke.expected_status_names(), fn name ->
      %{"id" => "state-#{String.downcase(String.replace(name, " ", "-"))}", "name" => name, "type" => "started"}
    end)
  end

  defp issue_payload(title, description) do
    %{
      "id" => "issue-#{System.unique_integer([:positive])}",
      "identifier" => "AWB-123",
      "title" => title,
      "description" => description,
      "url" => "https://linear.app/issue/AWB",
      "branchName" => nil,
      "state" => %{"id" => "state-todo", "name" => "Todo"},
      "project" => project_payload("project-1", "Symphony Agent Queue", "phase36", "https://linear.app/project"),
      "team" => %{"id" => "team-1", "key" => "AWB", "name" => "Agent Workbench", "states" => %{"nodes" => states()}},
      "labels" => %{"nodes" => []}
    }
  end

  defp issue_snapshot(issue_id, state) do
    current_issue_payload()
    |> Map.put("state", state)
    |> Map.put("id", issue_id)
    |> Map.put("comments", %{"nodes" => []})
  end

  defp remember_issue(issue) do
    Process.put({__MODULE__, :phase36_issue_payload}, issue)
  end

  defp current_issue_payload do
    Process.get(
      {__MODULE__, :phase36_issue_payload},
      issue_payload("Snapshot issue", "Snapshot")
    )
  end

  defp current_issue_state do
    Process.get({__MODULE__, :phase36_issue_state}, %{"id" => "state-in-progress", "name" => "In Progress"})
  end

  defp state_payload(state) do
    case state do
      "Todo" ->
        %{"id" => "state-todo", "name" => "Todo"}

      "In Progress" ->
        %{"id" => "state-in-progress", "name" => "In Progress"}

      "Human Review" ->
        %{"id" => "state-human-review", "name" => "Human Review"}

      "Blocked" ->
        %{"id" => "state-blocked", "name" => "Blocked"}

      other when is_binary(other) ->
        %{"id" => "state-#{String.downcase(String.replace(other, " ", "-"))}", "name" => other}
    end
  end
end
