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
    output_path = Path.join(System.tmp_dir!(), "phase36-live-smoke-test-#{System.unique_integer([:positive])}.json")

    deps =
      inert_deps(%{
        getenv: fn
          "RUN_REAL_SMOKE" -> "true"
          "CONFIRM_LIVE_SMOKE_MUTATION" -> "true"
          "LINEAR_API_KEY" -> "linear-token"
          "GH_TOKEN" -> "gh-token"
          "GITHUB_TOKEN" -> nil
          "PHASE36_SMOKE_LANES" -> "bug,feature,refactor,chore"
          _ -> nil
        end,
        github_preflight: fn -> :ok end,
        linear_graphql: &fake_linear_graphql/2,
        run_agent: fn _issue, _preflight, _output_path ->
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
    assert evidence["requested_lanes"] == ["bug", "feature", "refactor", "chore"]
    assert Enum.map(evidence["results"], & &1["lane"]) == ["bug", "feature", "refactor", "chore"]

    File.rm(output_path)
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
        move_issue_to_state: fn _issue, _state -> :ok end,
        run_agent: fn _issue, _preflight, _output_path -> flunk("agent should not run") end,
        write_file: fn _path, _body -> :ok end,
        now: fn -> ~U[2026-05-11 00:00:00Z] end,
        shell: Mix.shell()
      },
      overrides
    )
  end

  defp fake_linear_graphql(query, variables) do
    cond do
      String.contains?(query, "Phase36LiveSmokeViewer") ->
        {:ok, %{"data" => %{"viewer" => %{"id" => "viewer-1", "name" => "Moiz", "email" => "moiz@example.com"}}}}

      String.contains?(query, "Phase36LiveSmokeTeam") ->
        {:ok, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "team-1", "name" => variables.name, "states" => %{"nodes" => states()}}]}}}}

      String.contains?(query, "Phase36LiveSmokeProject") ->
        {:ok, %{"data" => %{"projects" => %{"nodes" => [%{"id" => "project-1", "name" => variables.name, "slugId" => "phase36", "url" => "https://linear.app/project"}]}}}}

      String.contains?(query, "Phase36LiveSmokeCreateIssue") ->
        issue = issue_payload(variables.title, variables.description)
        {:ok, %{"data" => %{"issueCreate" => %{"success" => true, "issue" => issue}}}}

      String.contains?(query, "Phase36LiveSmokeIssue") ->
        {:ok, %{"data" => %{"issue" => issue_snapshot(variables.id)}}}
    end
  end

  defp states do
    Enum.map(LiveSmoke.expected_status_names(), fn name ->
      %{"id" => "state-#{String.downcase(String.replace(name, " ", "-"))}", "name" => name, "type" => "started"}
    end)
  end

  defp issue_payload(title, description) do
    %{
      "id" => "issue-#{System.unique_integer([:positive])}",
      "identifier" => "AWB-#{System.unique_integer([:positive])}",
      "title" => title,
      "description" => description,
      "url" => "https://linear.app/issue/AWB",
      "branchName" => nil,
      "state" => %{"id" => "state-todo", "name" => "Todo"},
      "project" => %{"id" => "project-1", "name" => "Symphony Agent Queue", "slugId" => "phase36", "url" => "https://linear.app/project"},
      "team" => %{"id" => "team-1", "key" => "AWB", "name" => "Agent Workbench", "states" => %{"nodes" => states()}},
      "labels" => %{"nodes" => []}
    }
  end

  defp issue_snapshot(issue_id) do
    issue_payload("Snapshot #{issue_id}", "Snapshot") |> Map.put("state", %{"id" => "state-review", "name" => "Human Review"}) |> Map.put("comments", %{"nodes" => []})
  end
end
