defmodule Mix.Tasks.Phase36.LiveSmokeTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Phase36.LiveSmoke

  import ExUnit.CaptureIO

  setup do
    Mix.Task.reenable("phase36.live_smoke")
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

              {:ok,
               %{
                 "tool_call_count" => 1,
                 "generic_linear_graphql_calls" => 0,
                 "narrow_linear_lifecycle_calls" => 1,
                 "budget_state" => "ok"
               }}
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
        linear_graphql: fn _query, _variables -> flunk("linear preflight should not run") end
      })

    assert_raise Mix.Error, ~r/Empty Phase 3\.6 live-smoke lane selector is not allowed\./, fn ->
      LiveSmoke.run_with_deps([], empty_deps)
    end

    duplicate_deps =
      inert_deps(%{
        getenv: selector_env("docs,docs"),
        github_preflight: fn -> flunk("github preflight should not run") end,
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
          run_agent: fn _issue, preflight, _output_path ->
            assert preflight.project["id"] == case_data.project["id"]
            assert preflight.project["name"] == case_data.project["name"]
            assert preflight.project["slugId"] == case_data.project["slugId"]
            assert preflight.project["url"] == case_data.project["url"]

            {:ok,
             %{
               "tool_call_count" => 1,
               "generic_linear_graphql_calls" => 0,
               "narrow_linear_lifecycle_calls" => 1,
               "budget_state" => "ok"
             }}
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

          {:ok,
           %{
             "tool_call_count" => 1,
             "generic_linear_graphql_calls" => 0,
             "narrow_linear_lifecycle_calls" => 1,
             "budget_state" => "ok"
           }}
        end,
        write_file: &File.write!/2
      })

    assert :ok = LiveSmoke.run_with_deps(["--output", output_path], deps)
    assert_received {:moved_issue, "AWB-123", "Todo", "state-todo"}

    evidence = output_path |> File.read!() |> Jason.decode!()
    assert evidence["preflight"]["state_ids"]["Todo"] == "state-todo"
    assert evidence["preflight"]["state_ids"]["In Progress"] == "state-in-progress"
    assert evidence["results"] |> Enum.map(& &1["final_state"]) |> Enum.all?(&(&1 == "In Progress"))

    File.rm(output_path)
  end

  test "writes evidence with missing fields instead of faking success" do
    output_path = Path.join(System.tmp_dir!(), "phase36-live-smoke-test-#{System.unique_integer([:positive])}.json")
    agent_runs = Agent.start_link(fn -> [] end) |> elem(1)

    deps =
      inert_deps(%{
        github_preflight: fn -> :ok end,
        linear_graphql: &fake_linear_graphql/2,
        run_agent: fn issue, _preflight, _output_path ->
          Agent.update(agent_runs, &[issue.identifier | &1])

          {:ok,
           %{
             "tool_call_count" => 1,
             "generic_linear_graphql_calls" => 0,
             "narrow_linear_lifecycle_calls" => 1,
             "budget_state" => "ok"
           }}
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
        linear_graphql: fn _query, _variables -> flunk("linear preflight should not run") end,
        move_issue_to_state: fn _issue, state ->
          Process.put({__MODULE__, :phase36_issue_state}, state_payload(state))
          :ok
        end,
        run_agent: fn _issue, _preflight, _output_path -> flunk("agent should not run") end,
        write_file: fn _path, _body -> :ok end,
        now: fn -> ~U[2026-05-11 00:00:00Z] end,
        shell: Mix.shell()
      },
      overrides
    )
  end

  defp temp_output_path do
    Path.join(System.tmp_dir!(), "phase36-live-smoke-test-#{System.unique_integer([:positive])}.json")
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
        {:ok, %{"data" => %{"issueCreate" => %{"success" => true, "issue" => issue}}}}

      String.contains?(query, "Phase36LiveSmokeIssue") ->
        {:ok,
         %{
           "data" => %{
             "issue" =>
               issue_payload("Snapshot #{variables.id}", "Snapshot")
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
    issue_payload("Snapshot #{issue_id}", "Snapshot")
    |> Map.put("state", state)
    |> Map.put("comments", %{"nodes" => []})
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
