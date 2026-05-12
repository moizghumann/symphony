defmodule Mix.Tasks.Phase36.LiveSmoke do
  use Mix.Task

  alias SymphonyElixir.AgentRunner
  alias SymphonyElixir.Config
  alias SymphonyElixir.LaneClassifier
  alias SymphonyElixir.LanePolicy
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Protocol.{Contract, FinalizationGate}
  alias SymphonyElixir.Tracker
  alias SymphonyElixir.Workflow

  @shortdoc "Run guarded Phase 3.6 live smoke lanes"

  @moduledoc """
  Runs the guarded Phase 3.6 live smoke harness.

  This task refuses to mutate Linear or GitHub unless all live-smoke safety
  gates pass:

      RUN_REAL_SMOKE=true CONFIRM_LIVE_SMOKE_MUTATION=true mix phase36.live_smoke

  By default this runs `docs`, `test`, and `research`.

  Select lanes with repeated `--lane` options or a comma-separated
  `PHASE36_SMOKE_LANES` value.
  """

  @requirements ["app.start"]

  @repo "moizghumann/symphony"
  @handoff_artifact_relpath ".phase36/handoff.json"
  @default_team_name "Agent Workbench"
  @default_project_name "Symphony Agent Queue"
  @default_lanes ["docs", "test", "research"]
  @default_lane_runtime_ms 1_800_000
  @default_heartbeat_interval_ms 60_000
  @supported_lanes ["docs", "bug", "feature", "refactor", "test", "chore", "research"]
  @artifact_gate_fields [
    "affected_files_inspected",
    "behavior_change_documented",
    "behavior_changed",
    "behavior_preservation_evidence",
    "dependency_update_evidence",
    "explicitly_safe_validation_skip",
    "failure_signal_identified",
    "findings_posted",
    "recommendation_included",
    "scope_expanded",
    "sources_inspected_listed",
    "targeted_tests_run",
    "test_coverage_added",
    "tests_added",
    "tests_not_added_reason",
    "validation_required"
  ]
  @expected_status_names [
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

  @switches [
    lane: :keep,
    output: :string,
    team_name: :string,
    project_id: :string,
    project_slug: :string,
    project_name: :string,
    help: :boolean
  ]

  @viewer_query """
  query Phase36LiveSmokeViewer {
    viewer {
      id
      name
      email
    }
  }
  """

  @team_query """
  query Phase36LiveSmokeTeam($name: String!) {
    teams(filter: { name: { eq: $name } }, first: 1) {
      nodes {
        id
        name
        states(first: 50) {
          nodes {
            id
            name
            type
          }
        }
      }
    }
  }
  """

  @project_by_id_query """
  query Phase36LiveSmokeProjectById($id: String!) {
    projects(filter: { id: { eq: $id } }, first: 1) {
      nodes {
        id
        name
        slugId
        url
      }
    }
  }
  """

  @project_by_slug_query """
  query Phase36LiveSmokeProjectBySlug($slug: String!) {
    projects(filter: { slugId: { eq: $slug } }, first: 1) {
      nodes {
        id
        name
        slugId
        url
      }
    }
  }
  """

  @project_by_name_query """
  query Phase36LiveSmokeProjectByName($name: String!) {
    projects(filter: { name: { eq: $name } }, first: 1) {
      nodes {
        id
        name
        slugId
        url
      }
    }
  }
  """

  @create_issue_mutation """
  mutation Phase36LiveSmokeCreateIssue(
    $teamId: String!
    $projectId: String!
    $title: String!
    $description: String!
    $stateId: String
  ) {
    issueCreate(
      input: {
        teamId: $teamId
        projectId: $projectId
        title: $title
        description: $description
        stateId: $stateId
      }
    ) {
      success
      issue {
        id
        identifier
        title
        description
        url
        branchName
        state {
          id
          name
        }
        project {
          id
          name
          slugId
          url
        }
        team {
          id
          key
          name
          states(first: 50) {
            nodes {
              id
              name
              type
            }
          }
        }
        labels {
          nodes {
            name
          }
        }
      }
    }
  }
  """

  @issue_query """
  query Phase36LiveSmokeIssue($id: String!) {
    issue(id: $id) {
      id
      identifier
      title
      description
      url
      branchName
      state {
        id
        name
      }
      project {
        id
        name
        slugId
        url
      }
      team {
        id
        key
        name
        states(first: 50) {
          nodes {
            id
            name
            type
          }
        }
      }
      labels {
        nodes {
          name
        }
      }
      comments(first: 50) {
        nodes {
          id
          url
          body
        }
      }
    }
  }
  """

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(args) do
    run_with_deps(args, runtime_deps())
  end

  @doc false
  @spec run_with_deps([String.t()], map()) :: :ok
  def run_with_deps(args, deps) when is_list(args) and is_map(deps) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches)

    cond do
      Keyword.get(opts, :help, false) ->
        shell(deps).info(@moduledoc)

      invalid != [] ->
        Mix.raise("Invalid option(s): #{inspect(invalid)}")

      true ->
        do_run(opts, deps)
    end
  end

  @doc false
  @spec supported_lane_names() :: [String.t()]
  def supported_lane_names, do: @supported_lanes

  @doc false
  @spec expected_status_names() :: [String.t()]
  def expected_status_names, do: @expected_status_names

  @doc false
  @spec live_workflow_for_test(String.t(), String.t()) :: String.t()
  def live_workflow_for_test(project_slug, workspace_root) do
    live_workflow(project_slug, workspace_root)
  end

  @doc false
  @spec validate_agent_workbench_statuses([map()]) :: :ok | {:error, map()}
  def validate_agent_workbench_statuses(states) when is_list(states) do
    names =
      states
      |> Enum.map(fn
        %{"name" => name} -> name
        %{name: name} -> name
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    expected = MapSet.new(@expected_status_names)
    actual = MapSet.new(names)

    if actual == expected do
      :ok
    else
      {:error,
       %{
         expected: @expected_status_names,
         actual: Enum.sort(names),
         missing: expected |> MapSet.difference(actual) |> MapSet.to_list() |> Enum.sort(),
         unexpected: actual |> MapSet.difference(expected) |> MapSet.to_list() |> Enum.sort()
       }}
    end
  end

  def validate_agent_workbench_statuses(_states), do: {:error, %{expected: @expected_status_names, actual: []}}

  defp do_run(opts, deps) do
    lanes = selected_lanes!(opts, deps)
    output_path = output_path(opts, deps)
    team_name = Keyword.get(opts, :team_name, @default_team_name)
    project_id = project_id(opts, deps)
    project_slug = project_slug(opts, deps)
    project_name = project_name(opts, deps)

    shell(deps).info(plan(lanes, output_path, team_name, project_selector_label(project_id, project_slug, project_name)))

    require_env_gates!(deps)
    github_preflight = github_preflight!(deps)
    local_socket_preflight = local_socket_preflight!(deps)

    preflight = linear_preflight!(deps, team_name, project_id, project_slug, project_name, lanes)
    shell(deps).info("Phase 3.6 preflight passed; live mutation gates are satisfied.")

    results =
      Enum.reduce_while(lanes, [], fn lane, results ->
        result = run_lane!(lane, preflight, output_path, deps)
        results = results ++ [result]

        if lane_failed?(result) do
          {:halt, results}
        else
          {:cont, results}
        end
      end)

    evidence = %{
      "phase" => "3.6",
      "command" => "mix phase36.live_smoke",
      "repo" => @repo,
      "generated_at" => deps.now.() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "supported_lanes" => @supported_lanes,
      "requested_lanes" => lanes,
      "safety_gates" => safety_gate_summary(),
      "preflight" => %{
        "github" => "passed",
        "github_checks" => github_preflight,
        "linear" => "passed",
        "mix_pubsub_local_socket" => local_socket_preflight,
        "team" => %{
          "id" => preflight.team["id"],
          "key" => preflight.team["key"],
          "name" => preflight.team["name"]
        },
        "team_id" => preflight.team["id"],
        "project" => normalize_project(preflight.project),
        "project_id" => preflight.project["id"],
        "project_name" => preflight.project["name"],
        "project_slug" => preflight.project["slugId"],
        "project_url" => preflight.project["url"],
        "state_ids" => preflight.state_ids,
        "requested_lanes" => lanes,
        "supported_lanes" => @supported_lanes,
        "statuses" => @expected_status_names
      },
      "results" => results
    }

    deps.write_file.(output_path, Jason.encode!(evidence, pretty: true))
    shell(deps).info("Phase 3.6 live-smoke evidence written to #{output_path}")
    :ok
  end

  defp selected_lanes!(opts, deps) do
    case selected_lane_values(opts, deps) do
      {:default, lanes} ->
        lanes

      {:explicit, selectors} ->
        {lanes, empty_selector?} =
          selectors
          |> Enum.flat_map(&split_lane_value/1)
          |> Enum.map_reduce(false, fn lane, empty? ->
            lane = String.trim(lane)

            if lane == "" do
              {"", true}
            else
              {normalize_lane!(lane), empty?}
            end
          end)

        cond do
          empty_selector? or lanes == [] ->
            Mix.raise("Empty Phase 3.6 live-smoke lane selector is not allowed.")

          Enum.uniq(lanes) != lanes ->
            Mix.raise("Duplicate live-smoke lanes are not allowed: #{Enum.join(lanes, ", ")}")

          true ->
            lanes
        end
    end
  end

  defp lane_failed?(result) when is_map(result) do
    Map.get(result, "finalization_gate_result") == "blocked" or
      Map.get(result, "handoff_artifact_valid") == false or
      Map.get(result, "runner_status") in ["timeout", "error"]
  end

  defp lane_failed?(_result), do: true

  defp selected_lane_values(opts, deps) do
    case Keyword.get_values(opts, :lane) do
      [] ->
        case deps.getenv.("PHASE36_SMOKE_LANES") do
          nil -> {:default, @default_lanes}
          value -> {:explicit, [value]}
        end

      values ->
        {:explicit, values}
    end
  end

  defp split_lane_value(value) when is_binary(value) do
    value
    |> String.split(",", trim: false)
    |> Enum.map(&String.trim/1)
  end

  defp normalize_lane!(lane) when is_binary(lane) do
    lane = lane |> String.trim() |> String.downcase()

    if lane in @supported_lanes do
      lane
    else
      Mix.raise("Unsupported Phase 3.6 live-smoke lane #{inspect(lane)}. Supported lanes: #{Enum.join(@supported_lanes, ", ")}")
    end
  end

  defp output_path(opts, deps) do
    Keyword.get(opts, :output) ||
      Path.join(System.tmp_dir!(), "phase36-live-smoke-#{DateTime.to_unix(deps.now.())}.json")
  end

  defp project_id(opts, deps) do
    Keyword.get(opts, :project_id) || deps.getenv.("PHASE36_LINEAR_PROJECT_ID")
  end

  defp project_slug(opts, deps) do
    Keyword.get(opts, :project_slug) || deps.getenv.("PHASE36_LINEAR_PROJECT_SLUG")
  end

  defp project_name(opts, deps) do
    Keyword.get(opts, :project_name) || deps.getenv.("PHASE36_LINEAR_PROJECT_NAME") || @default_project_name
  end

  defp project_selector_label(project_id, project_slug, project_name) do
    cond do
      not blank?(project_id) -> project_id
      not blank?(project_slug) -> project_slug
      true -> project_name
    end
  end

  defp plan(lanes, output_path, team_name, project_name) do
    """
    Phase 3.6 live-smoke plan

    Repository: #{@repo}
    Linear team: #{team_name}
    Linear project: #{project_name}
    Lanes: #{Enum.join(lanes, ", ")}
    Evidence output: #{output_path}

    Mutations after confirmation:
    - create one Linear issue per requested lane if the runner needs a fresh issue
    - run requested lanes through AgentRunner
    - allow repo-changing lanes to create branches, commits, pushes, draft PRs, and Linear handoff comments through existing gates
    - collect evidence without marking unavailable telemetry as successful

    Refusing to continue unless CONFIRM_LIVE_SMOKE_MUTATION=true.
    """
  end

  defp resolve_project!(deps, project_id, project_slug, project_name) do
    cond do
      not blank?(project_id) ->
        fetch_single!(
          graphql_data!(deps, @project_by_id_query, %{id: project_id}, "projects"),
          "projects",
          project_id
        )

      not blank?(project_slug) ->
        fetch_single!(
          graphql_data!(deps, @project_by_slug_query, %{slug: project_slug}, "projects"),
          "projects",
          project_slug
        )

      true ->
        case fetch_project_by_slug!(deps, project_name) do
          nil ->
            fetch_single!(
              graphql_data!(deps, @project_by_name_query, %{name: project_name}, "projects"),
              "projects",
              project_name
            )

          project ->
            project
        end
    end
  end

  defp fetch_project_by_slug!(deps, project_name) do
    project_name
    |> project_slug_candidates()
    |> Enum.find_value(fn slug ->
      case project_nodes!(deps, @project_by_slug_query, %{slug: slug}) do
        %{"nodes" => [node | _]} -> node
        %{"nodes" => []} -> nil
        _ -> nil
      end
    end)
  end

  defp project_nodes!(deps, query, variables) do
    graphql_data!(deps, query, variables, "projects")
  end

  defp project_slug_candidates(project_name) when is_binary(project_name) do
    [url_slug(project_name), project_name]
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
  end

  defp project_slug_candidates(_project_name), do: []

  defp url_slug(project_name) when is_binary(project_name) do
    case URI.parse(project_name) do
      %URI{path: path} when is_binary(path) ->
        path
        |> String.split("/", trim: true)
        |> List.last()

      _ ->
        nil
    end
  end

  defp url_slug(_project_name), do: nil

  defp require_env_gates!(deps) do
    unless deps.getenv.("RUN_REAL_SMOKE") == "true" do
      Mix.raise("RUN_REAL_SMOKE must be true before Phase 3.6 live smoke can run.")
    end

    unless deps.getenv.("CONFIRM_LIVE_SMOKE_MUTATION") == "true" do
      Mix.raise("CONFIRM_LIVE_SMOKE_MUTATION must be true before Phase 3.6 live smoke can mutate Linear/GitHub.")
    end

    if blank?(deps.getenv.("LINEAR_API_KEY")) do
      Mix.raise("LINEAR_API_KEY must be present before Phase 3.6 live smoke can run.")
    end

    if blank?(deps.getenv.("GH_TOKEN")) and blank?(deps.getenv.("GITHUB_TOKEN")) do
      Mix.raise("GH_TOKEN or GITHUB_TOKEN must be present before Phase 3.6 live smoke can run.")
    end
  end

  defp github_preflight!(deps) do
    case deps.github_preflight.() do
      :ok ->
        %{"status" => "passed"}

      {:ok, payload} when is_map(payload) ->
        Map.put_new(stringify_keys(payload), "status", "passed")

      {:error, reason} ->
        Mix.raise("GitHub harness preflight failed before issue creation: #{inspect(reason)}")

      payload when is_map(payload) ->
        Map.put_new(stringify_keys(payload), "status", "passed")

      other ->
        Mix.raise("GitHub harness preflight returned unexpected payload before issue creation: #{inspect(other)}")
    end
  end

  defp local_socket_preflight!(deps) do
    case deps.local_socket_preflight.() do
      :ok ->
        %{"status" => "passed"}

      {:ok, payload} when is_map(payload) ->
        Map.put_new(stringify_keys(payload), "status", "passed")

      {:error, reason} ->
        Mix.raise("Mix PubSub/local socket preflight failed before issue creation: #{inspect(reason)}")

      payload when is_map(payload) ->
        Map.put_new(stringify_keys(payload), "status", "passed")

      other ->
        Mix.raise("Mix PubSub/local socket preflight returned unexpected payload before issue creation: #{inspect(other)}")
    end
  end

  defp linear_preflight!(deps, team_name, project_id, project_slug, project_name, lanes) do
    viewer = graphql_data!(deps, @viewer_query, %{}, "viewer")
    team = fetch_single!(graphql_data!(deps, @team_query, %{name: team_name}, "teams"), "teams", team_name)
    states = get_in(team, ["states", "nodes"]) || []

    case validate_agent_workbench_statuses(states) do
      :ok ->
        :ok

      {:error, diff} ->
        Mix.raise("Agent Workbench statuses did not exactly match Phase 3.6 contract: #{inspect(diff)}")
    end

    project = resolve_project!(deps, project_id, project_slug, project_name)

    %{
      viewer: viewer,
      team: team,
      project: project,
      states: states,
      state_ids: %{
        "Todo" => state_id!(states, "Todo"),
        "In Progress" => state_id!(states, "In Progress"),
        "Human Review" => state_id!(states, "Human Review"),
        "Blocked" => state_id!(states, "Blocked")
      },
      todo_state_id: state_id!(states, "Todo"),
      in_progress_state_id: state_id!(states, "In Progress"),
      human_review_state_id: state_id!(states, "Human Review"),
      blocked_state_id: state_id!(states, "Blocked"),
      requested_lanes: lanes,
      supported_lanes: @supported_lanes
    }
  end

  defp run_lane!(lane, preflight, output_path, deps) do
    issue = create_issue!(lane, preflight, deps)
    issue = start_issue!(issue, preflight, deps)
    classification = LaneClassifier.classify(issue)
    issue = %{issue | lane_classification: classification}

    runner_result = supervised_run_agent(lane, issue, preflight, output_path, deps)

    snapshot = fetch_issue_snapshot(issue.id, deps)
    evidence = evidence_for_lane(lane, issue, classification, runner_result, snapshot, deps)

    if Atom.to_string(classification.lane) != lane do
      put_in(evidence, ["protocol_warnings"], [
        %{
          "code" => "lane_classification_mismatch",
          "expected_lane" => lane,
          "actual_lane" => Atom.to_string(classification.lane)
        }
        | evidence["protocol_warnings"]
      ])
    else
      evidence
    end
  end

  defp supervised_run_agent(lane, issue, preflight, output_path, deps) do
    timeout_ms = lane_runtime_ms(deps)
    heartbeat_interval_ms = heartbeat_interval_ms(deps)
    started_at = timestamp(deps)
    started_monotonic_ms = deps.monotonic_time.()

    task =
      Task.async(fn ->
        try do
          deps.run_agent.(issue, preflight, output_path)
        rescue
          error ->
            {:error, {error, __STACKTRACE__}}
        catch
          kind, reason ->
            {:error, {kind, reason}}
        end
      end)

    supervision = %{
      "status" => "running",
      "max_lane_runtime_ms" => timeout_ms,
      "heartbeat_interval_ms" => heartbeat_interval_ms,
      "started_at" => started_at,
      "last_heartbeat_at" => started_at,
      "last_output_at" => nil,
      "workspace_path" => nil,
      "codex_session_id" => nil,
      "codex_process_id" => nil,
      "heartbeat_count" => 0
    }

    wait_for_lane(task, lane, issue, deps, started_monotonic_ms, supervision)
  end

  defp wait_for_lane(task, lane, issue, deps, started_monotonic_ms, supervision) do
    timeout_ms = supervision["max_lane_runtime_ms"]
    heartbeat_interval_ms = supervision["heartbeat_interval_ms"]
    elapsed_ms = deps.monotonic_time.() - started_monotonic_ms
    remaining_ms = max(timeout_ms - elapsed_ms, 0)

    cond do
      remaining_ms <= 0 ->
        timeout_lane(task, lane, issue, deps, started_monotonic_ms, supervision)

      true ->
        wait_ms = min(heartbeat_interval_ms, remaining_ms)

        receive do
          {ref, result} when ref == task.ref ->
            Process.demonitor(task.ref, [:flush])
            completed_supervision = completed_supervision(result, deps, started_monotonic_ms, supervision)
            attach_supervision(result, completed_supervision)

          {:DOWN, ref, :process, _pid, reason} when ref == task.ref ->
            failed_supervision =
              supervision
              |> Map.put("status", "error")
              |> Map.put("finished_at", timestamp(deps))
              |> Map.put("elapsed_ms", deps.monotonic_time.() - started_monotonic_ms)
              |> Map.put("error", inspect(reason))

            {:error, {:lane_runner_exited, reason}, %{"supervision" => failed_supervision}}
        after
          wait_ms ->
            next_supervision =
              supervision
              |> Map.put("last_heartbeat_at", timestamp(deps))
              |> Map.update!("heartbeat_count", &(&1 + 1))

            shell(deps).info("Phase 3.6 lane heartbeat lane=#{lane} issue=#{issue.identifier} elapsed_ms=#{elapsed_ms + wait_ms}")
            wait_for_lane(task, lane, issue, deps, started_monotonic_ms, next_supervision)
        end
    end
  end

  defp completed_supervision(result, deps, started_monotonic_ms, supervision) do
    telemetry = telemetry_from_runner_result(result)

    supervision
    |> Map.put("status", runner_result_status(result))
    |> Map.put("finished_at", timestamp(deps))
    |> Map.put("elapsed_ms", deps.monotonic_time.() - started_monotonic_ms)
    |> Map.put("last_output_at", Map.get(telemetry, "last_output_at") || timestamp(deps))
    |> Map.put("workspace_path", Map.get(telemetry, "workspace_path"))
    |> Map.put("codex_session_id", Map.get(telemetry, "session_id"))
    |> Map.put("codex_process_id", Map.get(telemetry, "codex_app_server_pid"))
  end

  defp timeout_lane(task, lane, issue, deps, started_monotonic_ms, supervision) do
    Task.shutdown(task, :brutal_kill)

    workspace_path = timeout_workspace_path(issue, deps)
    diagnostics = timeout_diagnostics(lane, issue, workspace_path, deps)

    timeout_supervision =
      supervision
      |> Map.put("status", "timeout")
      |> Map.put("finished_at", timestamp(deps))
      |> Map.put("elapsed_ms", deps.monotonic_time.() - started_monotonic_ms)
      |> Map.put("last_output_at", Map.get(diagnostics, "last_output_at"))
      |> Map.put("workspace_path", workspace_path)
      |> Map.put("timeout_diagnostics", diagnostics)

    {:timeout,
     %{
       "workspace_path" => workspace_path,
       "changed_files" => get_in(diagnostics, ["git", "changed_files"]) || [],
       "budget_state" => "timeout",
       "supervision" => timeout_supervision,
       "timeout_diagnostics" => diagnostics
     }}
  end

  defp attach_supervision({:ok, telemetry}, supervision) when is_map(telemetry) do
    {:ok, Map.put(telemetry, "supervision", supervision)}
  end

  defp attach_supervision({:error, reason}, supervision), do: {:error, reason, %{"supervision" => supervision}}
  defp attach_supervision({:error, reason, telemetry}, supervision) when is_map(telemetry), do: {:error, reason, Map.put(telemetry, "supervision", supervision)}
  defp attach_supervision({:timeout, telemetry}, supervision) when is_map(telemetry), do: {:timeout, Map.put(telemetry, "supervision", supervision)}
  defp attach_supervision(other, supervision), do: {:error, {:unexpected_runner_result, other}, %{"supervision" => supervision}}

  defp lane_runtime_ms(deps), do: positive_integer_setting(deps, :lane_runtime_ms, @default_lane_runtime_ms)
  defp heartbeat_interval_ms(deps), do: max(positive_integer_setting(deps, :heartbeat_interval_ms, @default_heartbeat_interval_ms), 1)

  defp positive_integer_setting(deps, key, default) do
    value = Map.get(deps, key, default)
    value = if is_function(value, 0), do: value.(), else: value

    case value do
      integer when is_integer(integer) and integer >= 0 -> integer
      string when is_binary(string) -> parse_positive_integer(string, default)
      _ -> default
    end
  end

  defp parse_positive_integer(value, default) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} when integer >= 0 -> integer
      _ -> default
    end
  end

  defp timeout_workspace_path(issue, deps) do
    case deps.workspace_path_for_issue.(issue) do
      path when is_binary(path) and path != "" -> path
      _ -> nil
    end
  end

  defp timeout_diagnostics(lane, issue, workspace_path, deps) do
    git = deps.inspect_workspace_git.(workspace_path)
    artifact = inspect_handoff_artifact(workspace_path)
    linear_before_block = fetch_issue_snapshot(issue.id, deps)

    github_artifact = %{
      "branch_name" => Map.get(git, "branch_name") || issue.branch_name,
      "commit_sha" => Map.get(git, "commit_sha"),
      "pr_url" => nil,
      "changed_files" => Map.get(git, "changed_files") || []
    }

    github =
      github_verification_payload(
        github_artifact,
        %{lane: lane, issue: issue, workspace_path: workspace_path, repo_changed: true, changed_files: github_artifact["changed_files"]},
        deps
      )

    block_result = block_timeout_issue(issue, deps)
    linear_after_block = fetch_issue_snapshot(issue.id, deps)

    %{
      "reason" => "lane_runtime_timeout",
      "workspace_path" => workspace_path,
      "git" => git,
      "artifact" => artifact,
      "linear_before_block" => linear_before_block,
      "linear_after_block" => linear_after_block,
      "github" => github,
      "blocked_transition" => block_result
    }
  end

  defp inspect_handoff_artifact(workspace_path) do
    artifact_path = handoff_artifact_path(workspace_path)

    cond do
      blank?(workspace_path) ->
        %{"path" => artifact_path, "exists" => false, "status" => "workspace_unknown"}

      not File.exists?(artifact_path) ->
        %{"path" => artifact_path, "exists" => false}

      true ->
        case File.read(artifact_path) do
          {:ok, body} ->
            %{"path" => artifact_path, "exists" => true, "valid_json" => match?({:ok, %{}}, Jason.decode(body))}

          {:error, reason} ->
            %{"path" => artifact_path, "exists" => true, "read_error" => inspect(reason)}
        end
    end
  end

  defp block_timeout_issue(issue, deps) do
    body = """
    ## Symphony Handoff Blocked

    Phase 3.6 live smoke timed out before handoff readiness could be verified.

    Issue: #{issue.identifier || issue.id}
    Reason: lane_runtime_timeout
    """

    handoff_result = deps.post_handoff_comment.(issue, body)

    if handoff_result == :ok do
      case deps.move_issue_to_state.(issue, Contract.current().blocked_state) do
        :ok -> %{"status" => "blocked", "handoff_posted" => true}
        {:error, reason} -> %{"status" => "block_failed", "handoff_posted" => true, "reason" => inspect(reason)}
        other -> %{"status" => "block_failed", "handoff_posted" => true, "reason" => inspect(other)}
      end
    else
      %{"status" => "handoff_failed", "handoff_posted" => false, "reason" => inspect(handoff_result)}
    end
  end

  defp block_completion_contract_issue(issue, blocker_reason, completion_states, deps) do
    body = """
    ## Symphony Handoff Blocked

    Phase 3.6 live smoke could not verify the AgentRunner completion contract.

    Issue: #{issue.identifier || issue.id}
    Reason: #{blocker_reason}

    Completion states:
    - codex_process_started: #{completion_states["codex_process_started"]}
    - codex_prompt_delivered: #{completion_states["codex_prompt_delivered"]}
    - codex_work_observed: #{completion_states["codex_work_observed"]}
    - symphony_handoff_ready_seen: #{completion_states["symphony_handoff_ready_seen"]}
    - lane_contract_satisfied: #{completion_states["lane_contract_satisfied"]}
    """

    handoff_result = deps.post_handoff_comment.(issue, body)

    if handoff_result == :ok do
      case deps.move_issue_to_state.(issue, Contract.current().blocked_state) do
        :ok -> %{"status" => "blocked", "handoff_posted" => true}
        {:error, reason} -> %{"status" => "block_failed", "handoff_posted" => true, "reason" => inspect(reason)}
        other -> %{"status" => "block_failed", "handoff_posted" => true, "reason" => inspect(other)}
      end
    else
      %{"status" => "handoff_failed", "handoff_posted" => false, "reason" => inspect(handoff_result)}
    end
  end

  defp start_issue!(issue, preflight, deps) do
    case deps.move_issue_to_state.(issue, "In Progress") do
      :ok ->
        refreshed_issue = fetch_issue!(issue.id, deps)

        if refreshed_issue.state_id == preflight.in_progress_state_id do
          refreshed_issue
        else
          Mix.raise("Failed to refresh #{issue.identifier} into In Progress before live smoke: #{inspect(refreshed_issue.state)}")
        end

      {:error, reason} ->
        Mix.raise("Failed to move #{issue.identifier} to In Progress before live smoke: #{inspect(reason)}")
    end
  end

  defp create_issue!(lane, preflight, deps) do
    input = issue_input(lane)

    data =
      graphql_data!(
        deps,
        @create_issue_mutation,
        %{
          teamId: preflight.team["id"],
          projectId: preflight.project["id"],
          title: input.title,
          description: input.description,
          stateId: preflight.state_ids["Todo"]
        },
        "issueCreate"
      )

    case data do
      %{"success" => true, "issue" => %{} = issue} ->
        normalize_issue(issue)

      _ ->
        Mix.raise("Linear issueCreate returned unexpected payload: #{inspect(data)}")
    end
  end

  defp issue_input("docs") do
    %{
      title: "Docs live smoke: update Phase 3.6 validation note",
      description: """
      Lane: docs

      Goal:
      Make a documentation-only update that proves repo-changing docs lane behavior.

      Scope:
      - Change only documentation under docs/.
      - Leave final commit, push, draft PR publication, Linear handoff, and final state transition to Symphony after `SYMPHONY_HANDOFF_READY`.
      - Emit SYMPHONY_HANDOFF_READY only after the repository edit is complete.

      Validation:
      - No code validation required.
      - Record validation as not run: docs-only change.
      """
    }
  end

  defp issue_input("test") do
    %{
      title: "Add regression tests for Phase 3.6 live smoke evidence",
      description: """
      Lane: test

      Goal:
      Add or update focused regression coverage for Phase 3.6 live-smoke evidence handling.

      Scope:
      - Test-only or narrowly supporting changes.
      - Run the targeted test command that covers the change.
      - Commit, push, and emit SYMPHONY_HANDOFF_READY only after validation passes.

      Validation:
      - Run the focused test command covering the added regression test.
      """
    }
  end

  defp issue_input("bug") do
    %{
      title: "Fix Phase 3.6 live smoke evidence regression",
      description: """
      Lane: bug

      Goal:
      Identify a concrete failure signal in Phase 3.6 live-smoke evidence handling and fix it.

      Scope:
      - Record the failure signal before implementing the fix.
      - Keep the change narrowly scoped to the failure.
      - Commit, push, and emit SYMPHONY_HANDOFF_READY only after validation passes.

      Validation:
      - Run the targeted test command that demonstrates the failure is fixed.
      """
    }
  end

  defp issue_input("feature") do
    %{
      title: "Feature live smoke: add a tiny Phase 3.6 runner note",
      description: """
      Lane: feature

      Goal:
      Implement the smallest coherent user-visible feature proving feature lane behavior.

      Scope:
      - Prefer a tiny documentation-backed or validation-surface feature related to Phase 3.6 evidence.
      - Include tests or docs evidence, or explicitly justify why one is not appropriate.
      - Commit, push, and emit SYMPHONY_HANDOFF_READY only after validation passes.

      Validation:
      - Run relevant validation for the changed surface.
      """
    }
  end

  defp issue_input("refactor") do
    %{
      title: "Refactor live smoke: preserve Phase 3.6 evidence behavior",
      description: """
      Lane: refactor

      Goal:
      Make a tiny behavior-preserving refactor in Phase 3.6 live-smoke evidence handling.

      Scope:
      - Preserve behavior.
      - Document behavior-preservation evidence in the handoff.
      - Commit, push, and emit SYMPHONY_HANDOFF_READY only after validation passes.

      Validation:
      - Run focused validation proving behavior is preserved.
      """
    }
  end

  defp issue_input("chore") do
    %{
      title: "Chore live smoke: maintain Phase 3.6 validation metadata",
      description: """
      Lane: chore

      Goal:
      Make a tiny maintenance-only change proving chore lane behavior.

      Scope:
      - Limit changes to validation metadata, scripts, or config directly relevant to Phase 3.6.
      - Avoid product behavior changes.
      - Commit, push, and emit SYMPHONY_HANDOFF_READY only after relevant validation passes.

      Validation:
      - Run validation relevant to the maintenance surface.
      """
    }
  end

  defp issue_input("research") do
    %{
      title: "Research live smoke: assess Phase 3.6 runner evidence gaps",
      description: """
      Lane: research

      Goal:
      Investigate Phase 3.6 live-smoke evidence gaps and post concise findings.

      Scope:
      - Read-only by default.
      - Do not create a branch, commit, or PR unless a repository artifact is explicitly required.
      - Post findings through the narrow Linear handoff path, then move to Human Review.

      Validation:
      - Not required for read-only research.
      """
    }
  end

  defp evidence_for_lane(lane, issue, classification, runner_result, snapshot, deps) do
    telemetry = telemetry_from_runner_result(runner_result)
    artifact_result = handoff_artifact_result(lane, issue, classification, telemetry)
    comments = get_in(snapshot, ["comments", "nodes"]) || []
    pr_url = artifact_value(artifact_result, ["pr_url"]) || find_pr_url(comments) || Map.get(telemetry, "pr_url")
    changed_files = artifact_value(artifact_result, ["changed_files"])
    observed_changed_files = Map.get(telemetry, "changed_files") || []
    product_changed_files = effective_changed_files(changed_files, observed_changed_files)
    control_artifacts = control_artifacts(changed_files, observed_changed_files, artifact_result)
    validation = artifact_validation(artifact_result, telemetry)
    artifact_repo_changed = artifact_value(artifact_result, ["repo_changed"])
    repo_changed = repo_changed?(artifact_repo_changed, product_changed_files, pr_url)
    final_state = artifact_value(artifact_result, ["handoff", "final_state_requested"]) || get_in(snapshot, ["state", "name"]) || issue.state
    expected_final_state = expected_final_state(runner_result, final_state)
    external_verification = external_verification_result(lane, issue, artifact_result, telemetry, snapshot, repo_changed, product_changed_files, expected_final_state, deps)

    gate_result =
      %{
        lane: lane,
        current_state: expected_final_state,
        available_states: issue.available_states,
        repo_changed: repo_changed,
        changed_files: product_changed_files,
        pr_url: pr_url,
        branch_name: artifact_value(artifact_result, ["branch_name"]) || Map.get(telemetry, "branch_name"),
        commit_sha: artifact_value(artifact_result, ["commit_sha"]) || Map.get(telemetry, "commit_sha"),
        branch_pushed: not blank?(pr_url),
        pr_posted_to_linear: not blank?(pr_url),
        handoff_posted: truthy?(artifact_value(artifact_result, ["handoff", "linear_comment_posted"])) or handoff_comment(comments) != nil,
        validation_required: Map.get(validation, "required"),
        validation_status: validation_status(validation),
        validation_reason: Map.get(validation, "reason"),
        findings_posted: findings_posted?(lane, artifact_result, comments),
        sources_inspected_listed: artifact_or_telemetry_value(artifact_result, telemetry, "sources_inspected_listed"),
        recommendation_included: artifact_or_telemetry_value(artifact_result, telemetry, "recommendation_included"),
        budget_state: Map.get(telemetry, "budget_state", :ok),
        generic_linear_graphql_calls: Map.get(telemetry, "generic_linear_graphql_call_details", [])
      }
      |> Map.merge(artifact_gate_evidence(artifact_result, telemetry))
      |> finalization_gate_result()

    evidence =
      %{
        "linear_issue_identifier" => issue.identifier,
        "linear_issue_url" => issue.url,
        "lane" => lane,
        "classification_reason" => classification.reason,
        "final_state" => final_state,
        "expected_final_state" => expected_final_state,
        "pr_url" => pr_url,
        "branch_name" => artifact_value(artifact_result, ["branch_name"]) || Map.get(telemetry, "branch_name"),
        "commit_sha" => artifact_value(artifact_result, ["commit_sha"]) || Map.get(telemetry, "commit_sha"),
        "changed_files" => product_changed_files,
        "product_changed_files" => product_changed_files,
        "control_artifacts" => control_artifacts,
        "validation_status" => validation_status(validation),
        "validation_command_result" => Map.get(validation, "command_result"),
        "validation_command" => Map.get(validation, "command"),
        "validation_reason" => Map.get(validation, "reason"),
        "targeted_tests_run" => artifact_or_telemetry_value(artifact_result, telemetry, "targeted_tests_run"),
        "test_coverage_added" => artifact_or_telemetry_value(artifact_result, telemetry, "test_coverage_added"),
        "repo_changed" => repo_changed,
        "effective_tokens" => Map.get(telemetry, "effective_tokens"),
        "gross_context_tokens" => Map.get(telemetry, "gross_context_tokens"),
        "cached_input_tokens" => Map.get(telemetry, "cached_input_tokens"),
        "output_tokens" => Map.get(telemetry, "output_tokens"),
        "tool_call_count" => Map.get(telemetry, "tool_call_count"),
        "generic_linear_graphql_calls" => Map.get(telemetry, "generic_linear_graphql_calls"),
        "narrow_linear_lifecycle_calls" => Map.get(telemetry, "narrow_linear_lifecycle_calls"),
        "budget_state" => Map.get(telemetry, "budget_state"),
        "finalization_gate_result" => gate_result["result"],
        "protocol_violations" => gate_result["violations"],
        "protocol_warnings" => gate_result["warnings"],
        "handoff_comment_id_or_url" => handoff_comment_id_or_url(comments),
        "handoff_artifact_path" => Map.get(artifact_result, "path"),
        "handoff_artifact_valid" => Map.get(artifact_result, "valid", false),
        "handoff_artifact_status" => artifact_value(artifact_result, ["status"]),
        "external_verification" => Map.drop(external_verification, ["violations"]),
        "runner_status" => runner_result_status(runner_result),
        "sandbox_policy_type" => Map.get(telemetry, "sandbox_policy_type"),
        "sandbox_writable_roots" => Map.get(telemetry, "sandbox_writable_roots"),
        "active_workspace_path" => Map.get(telemetry, "active_workspace_path") || Map.get(telemetry, "workspace_path"),
        "active_workspace_git_root" => Map.get(telemetry, "active_workspace_git_root"),
        "active_workspace_git_root_writable_probe" => Map.get(telemetry, "active_workspace_git_root_writable_probe"),
        "lane_contract_status" => nil,
        "completion_states" => %{},
        "blocker_reason" => nil,
        "blocked_transition" => nil,
        "supervision" => Map.get(telemetry, "supervision"),
        "timeout_diagnostics" => Map.get(telemetry, "timeout_diagnostics"),
        "missing_evidence" => [],
        "code_seams_needed" => []
      }

    evidence
    |> merge_runner_findings(runner_result)
    |> merge_artifact_findings(artifact_result, external_verification)
    |> apply_completion_contract(lane, issue, telemetry, deps)
    |> record_missing_evidence()
  end

  defp telemetry_from_runner_result({:ok, telemetry}) when is_map(telemetry), do: telemetry
  defp telemetry_from_runner_result({:error, _reason, telemetry}) when is_map(telemetry), do: telemetry
  defp telemetry_from_runner_result({:timeout, telemetry}) when is_map(telemetry), do: telemetry
  defp telemetry_from_runner_result(_runner_result), do: %{}

  defp runner_result_status({:ok, _telemetry}), do: "ok"
  defp runner_result_status({:timeout, _telemetry}), do: "timeout"
  defp runner_result_status({:error, _reason, _telemetry}), do: "error"
  defp runner_result_status({:error, _reason}), do: "error"
  defp runner_result_status(_runner_result), do: "error"

  defp expected_final_state(runner_result, final_state) do
    case runner_result_status(runner_result) do
      status when status in ["timeout", "error"] -> Contract.current().blocked_state
      _ -> final_state
    end
  end

  defp finalization_gate_result(run_state) do
    contract = Contract.current()

    case FinalizationGate.evaluate(run_state, contract.review_state, contract) do
      {:ok, result} -> gate_payload("ok", result)
      {:blocked, result} -> gate_payload("blocked", result)
    end
  end

  defp gate_payload(status, result) do
    %{
      "result" => status,
      "violations" => Enum.map(result.protocol_violations, &violation_payload/1),
      "warnings" => Enum.map(result.protocol_warnings, &violation_payload/1)
    }
  end

  defp violation_payload(violation) do
    violation
    |> Map.from_struct()
    |> Map.update(:code, nil, &to_string/1)
    |> Map.update(:severity, nil, &to_string/1)
    |> stringify_keys()
  end

  defp record_missing_evidence(evidence) do
    required_fields = [
      "pr_url",
      "branch_name",
      "changed_files",
      "validation_status",
      "validation_command_result",
      "effective_tokens",
      "gross_context_tokens",
      "cached_input_tokens",
      "output_tokens",
      "tool_call_count",
      "generic_linear_graphql_calls",
      "narrow_linear_lifecycle_calls",
      "budget_state",
      "handoff_comment_id_or_url"
    ]

    missing = Enum.filter(required_fields, &missing?(Map.get(evidence, &1)))

    seams =
      Enum.map(missing, fn field ->
        %{
          "field" => field,
          "seam" => seam_for_missing_field(field)
        }
      end)

    evidence
    |> Map.put("missing_evidence", missing)
    |> Map.put("code_seams_needed", seams)
  end

  defp seam_for_missing_field(field)
       when field in ["effective_tokens", "gross_context_tokens", "cached_input_tokens", "output_tokens"] do
    "Expose structured Codex usage telemetry from direct AgentRunner live-smoke runs."
  end

  defp seam_for_missing_field(field)
       when field in ["tool_call_count", "generic_linear_graphql_calls", "narrow_linear_lifecycle_calls"] do
    "Expose structured tool-call counters from direct AgentRunner live-smoke runs."
  end

  defp seam_for_missing_field("validation_status"), do: "Expose structured lane validation status from the Codex handoff."
  defp seam_for_missing_field("validation_command_result"), do: "Expose structured validation command output from the Codex handoff."
  defp seam_for_missing_field("budget_state"), do: "Expose final budget state from direct AgentRunner live-smoke runs."
  defp seam_for_missing_field(_field), do: "Collect this field from Git/Linear handoff artifacts after the live run."

  defp handoff_artifact_result(lane, issue, classification, telemetry) do
    workspace_path = Map.get(telemetry, "workspace_path")
    artifact_path = handoff_artifact_path(workspace_path)

    result =
      cond do
        blank?(workspace_path) ->
          %{"valid" => false, "violations" => [artifact_violation("missing_workspace_path", "Workspace path was not available for artifact validation.")]}

        not File.exists?(artifact_path) ->
          %{"valid" => false, "violations" => [artifact_violation("missing_handoff_artifact", "Expected #{@handoff_artifact_relpath} to exist before SYMPHONY_HANDOFF_READY.")]}

        true ->
          parse_handoff_artifact(artifact_path, lane, issue, classification, telemetry)
      end

    result
    |> Map.put("path", artifact_path)
  end

  defp parse_handoff_artifact(artifact_path, lane, issue, classification, telemetry) do
    case File.read(artifact_path) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, %{} = artifact} ->
            validate_handoff_artifact(artifact, lane, issue, classification, telemetry)

          {:ok, _value} ->
            %{"valid" => false, "violations" => [artifact_violation("invalid_handoff_artifact", "Handoff artifact must decode to a JSON object.")]}

          {:error, _reason} ->
            %{"valid" => false, "violations" => [artifact_violation("invalid_handoff_artifact_json", "Handoff artifact must contain valid JSON.")]}
        end

      {:error, reason} ->
        %{"valid" => false, "violations" => [artifact_violation("handoff_artifact_read_failed", "Handoff artifact could not be read: #{inspect(reason)}")]}
    end
  end

  defp validate_handoff_artifact(artifact, lane, issue, _classification, telemetry) do
    observed_changed_files = FinalizationGate.product_changed_files(Map.get(telemetry, "changed_files") || [])
    nested_validation = Map.get(artifact, "validation") || %{}
    validation = artifact_validation(%{"artifact" => artifact}, telemetry)
    handoff = Map.get(artifact, "handoff") || %{}
    repo_changed = truthy?(Map.get(artifact, "repo_changed"))
    protocol_notes = List.wrap(Map.get(artifact, "protocol_notes")) |> Enum.reject(&blank?/1)

    violations =
      []
      |> require_artifact_field(artifact, "lane")
      |> require_artifact_field(artifact, "linear_issue_identifier")
      |> require_artifact_field(artifact, "status")
      |> require_artifact_field(artifact, "repo_changed")
      |> require_artifact_field(artifact, "branch_name")
      |> require_artifact_field(artifact, "commit_sha")
      |> require_artifact_field(artifact, "pr_url")
      |> require_artifact_field(artifact, "changed_files")
      |> require_artifact_field(nested_validation, "required", "validation.required")
      |> require_artifact_field(nested_validation, "status", "validation.status")
      |> require_artifact_field(nested_validation, "command", "validation.command")
      |> require_artifact_field(nested_validation, "reason", "validation.reason")
      |> require_artifact_field(handoff, "linear_comment_posted", "handoff.linear_comment_posted")
      |> require_artifact_field(handoff, "final_state_requested", "handoff.final_state_requested")
      |> require_artifact_field(artifact, "protocol_notes")
      |> lane_mismatch_violations(artifact, lane, issue)
      |> repo_change_violations(lane, artifact, observed_changed_files)
      |> docs_validation_violations(lane, validation)
      |> research_artifact_violations(lane, repo_changed, handoff, protocol_notes)
      |> lane_validation_violations(lane, validation)
      |> test_artifact_violations(lane, artifact, validation)

    %{
      "artifact" => artifact,
      "valid" => violations == [],
      "violations" => violations,
      "warnings" => []
    }
  end

  defp require_artifact_field(violations, map, key, label \\ nil) do
    field_label = label || key

    if Map.has_key?(map, key) do
      violations
    else
      [artifact_violation("missing_#{String.replace(field_label, ".", "_")}", "Handoff artifact is missing required field #{field_label}.") | violations]
    end
  end

  defp lane_mismatch_violations(violations, artifact, lane, issue) do
    artifact_lane = Map.get(artifact, "lane")
    artifact_issue = Map.get(artifact, "linear_issue_identifier")

    violations
    |> maybe_add_violation(artifact_lane != lane, "handoff_artifact_lane_mismatch", "Handoff artifact lane #{inspect(artifact_lane)} did not match requested lane #{inspect(lane)}.")
    |> maybe_add_violation(
      artifact_issue != issue.identifier,
      "handoff_artifact_issue_mismatch",
      "Handoff artifact issue #{inspect(artifact_issue)} did not match Linear issue #{inspect(issue.identifier)}."
    )
  end

  defp repo_change_violations(violations, lane, artifact, observed_changed_files) do
    repo_changed = truthy?(Map.get(artifact, "repo_changed"))
    branch_name = Map.get(artifact, "branch_name")
    commit_sha = Map.get(artifact, "commit_sha")
    pr_url = Map.get(artifact, "pr_url")

    violations
    |> maybe_add_violation(
      repo_changed and repo_changing_lane?(lane) and (blank?(branch_name) or blank?(commit_sha) or blank?(pr_url)),
      "repo_change_artifact_missing_git_fields",
      "Repo-changing lane artifacts must include branch_name, commit_sha, and pr_url when repo_changed=true."
    )
    |> maybe_add_violation(
      not repo_changed and non_empty_list?(observed_changed_files),
      "repo_change_artifact_mismatch",
      "Artifact reported repo_changed=false while the workspace showed repository changes."
    )
  end

  defp docs_validation_violations(violations, lane, validation) do
    status = validation_status(validation)
    reason = Map.get(validation, "reason")

    maybe_add_violation(
      violations,
      lane == "docs" and status == "not_run" and blank?(reason),
      "docs_validation_reason_required",
      "Docs artifacts that skip validation must provide validation.reason."
    )
  end

  defp research_artifact_violations(violations, lane, repo_changed, handoff, protocol_notes) do
    maybe_add_violation(
      violations,
      lane == "research" and not repo_changed and (not truthy?(Map.get(handoff, "linear_comment_posted")) or protocol_notes == []),
      "research_findings_evidence_required",
      "Read-only research artifacts must include findings evidence in protocol_notes and confirm the Linear comment was posted."
    )
  end

  defp lane_validation_violations(violations, lane, validation) do
    status = validation_status(validation)

    maybe_add_violation(
      violations,
      lane in ["feature", "refactor", "bug", "test", "chore"] and status in [nil, "", "not_run"],
      "lane_validation_required",
      "Feature, refactor, bug, test, and chore artifacts must include executed validation evidence."
    )
  end

  defp test_artifact_violations(violations, "test", artifact, validation) do
    violations
    |> require_artifact_field(artifact, "targeted_tests_run")
    |> require_artifact_field(artifact, "test_coverage_added")
    |> maybe_add_violation(
      validation_status(validation) in [nil, ""],
      "missing_validation_status",
      "Test lane artifacts must include validation_status or validation.status."
    )
    |> maybe_add_violation(
      blank?(Map.get(validation, "command")),
      "missing_validation_command",
      "Test lane artifacts must include validation_command or validation.command."
    )
    |> maybe_add_violation(
      blank?(Map.get(validation, "reason")),
      "missing_validation_reason",
      "Test lane artifacts must include validation_reason or validation.reason."
    )
  end

  defp test_artifact_violations(violations, _lane, _artifact, _validation), do: violations

  defp external_verification_result(lane, issue, artifact_result, telemetry, snapshot, repo_changed, changed_files, expected_final_state, deps) do
    artifact = Map.get(artifact_result, "artifact") || %{}

    context = %{
      lane: lane,
      issue: issue,
      telemetry: telemetry,
      snapshot: snapshot,
      repo_changed: repo_changed,
      changed_files: changed_files,
      expected_final_state: expected_final_state,
      workspace_path: Map.get(telemetry, "workspace_path")
    }

    github = github_verification_payload(artifact, context, deps)
    linear = linear_verification_payload(issue, artifact, snapshot, context, deps)
    violations = github_verification_violations(github, context) ++ linear_verification_violations(linear, context)

    %{
      "github" => github,
      "linear" => linear,
      "valid" => violations == [],
      "violations" => violations
    }
  end

  defp github_verification_payload(artifact, context, deps) do
    if truthy?(Map.get(context, :repo_changed)) do
      case deps.github_verify.(artifact, context) do
        {:ok, payload} when is_map(payload) -> stringify_keys(payload) |> Map.put_new("status", "completed")
        {:error, reason} -> %{"status" => "error", "reason" => inspect(reason)}
        payload when is_map(payload) -> stringify_keys(payload) |> Map.put_new("status", "completed")
        other -> %{"status" => "error", "reason" => inspect(other)}
      end
    else
      %{"status" => "skipped", "reason" => "repo_changed=false"}
    end
  end

  defp linear_verification_payload(issue, artifact, snapshot, context, deps) do
    case deps.linear_verify.(issue, artifact, snapshot, context) do
      {:ok, payload} when is_map(payload) -> stringify_keys(payload) |> Map.put_new("status", "completed")
      {:error, reason} -> %{"status" => "error", "reason" => inspect(reason)}
      payload when is_map(payload) -> stringify_keys(payload) |> Map.put_new("status", "completed")
      other -> %{"status" => "error", "reason" => inspect(other)}
    end
  end

  defp github_verification_violations(%{"status" => "skipped"}, _context), do: []

  defp github_verification_violations(%{"status" => "error", "reason" => reason}, _context) do
    [artifact_violation("github_verification_failed", "GitHub external verification failed: #{reason}")]
  end

  defp github_verification_violations(verification, context) do
    changed_files = Map.get(context, :changed_files) || []
    external_changed_files = list_field(verification, "changed_files")
    external_product_changed_files = FinalizationGate.product_changed_files(external_changed_files)
    issue = Map.get(context, :issue)

    []
    |> maybe_add_violation(
      Enum.any?(external_changed_files, &FinalizationGate.control_artifact?/1),
      "github_control_artifacts_committed",
      "GitHub PR changed files included Phase 3.6 control artifacts."
    )
    |> maybe_add_violation(not truthy?(Map.get(verification, "branch_exists")), "github_branch_missing", "GitHub verification could not find the reported branch.")
    |> maybe_add_violation(not truthy?(Map.get(verification, "commit_exists")), "github_commit_missing", "GitHub verification could not find the reported commit.")
    |> maybe_add_violation(not truthy?(Map.get(verification, "pr_exists")), "github_pr_missing", "GitHub verification could not find the reported pull request.")
    |> maybe_add_violation(
      not truthy?(Map.get(verification, "pr_draft") || Map.get(verification, "is_draft") || Map.get(verification, "isDraft")),
      "github_pr_not_draft",
      "GitHub verification requires the pull request to be draft."
    )
    |> maybe_add_violation(
      (Map.get(verification, "pr_base_ref") || Map.get(verification, "baseRefName")) != "main",
      "github_pr_wrong_base",
      "GitHub verification requires the pull request to target main."
    )
    |> maybe_add_violation(not pr_links_issue?(verification, issue), "github_pr_missing_linear_link", "GitHub verification requires the PR title/body to link the Linear issue.")
    |> maybe_add_violation(
      external_product_changed_files != [] and Enum.sort(external_product_changed_files) != Enum.sort(changed_files),
      "github_changed_files_mismatch",
      "GitHub PR changed files did not match the handoff artifact."
    )
    |> maybe_add_violation(
      Map.get(context, :lane) == "docs" and FinalizationGate.code_bearing_changes?(external_product_changed_files),
      "github_changed_files_lane_mismatch",
      "Docs lane PR changed code-bearing files."
    )
  end

  defp linear_verification_violations(%{"status" => "error", "reason" => reason}, _context) do
    [artifact_violation("linear_verification_failed", "Linear external verification failed: #{reason}")]
  end

  defp linear_verification_violations(verification, context) do
    expected_state = Map.get(context, :expected_final_state)
    repo_changed = Map.get(context, :repo_changed)
    lane = Map.get(context, :lane)

    []
    |> maybe_add_violation(Map.get(verification, "final_state") != expected_state, "linear_state_mismatch", "Linear issue final state did not match the expected Phase 3.6 result.")
    |> maybe_add_violation(
      expected_state == Contract.current().blocked_state and not truthy?(Map.get(verification, "blocker_comment_exists")),
      "linear_blocker_comment_missing",
      "Blocked Phase 3.6 lanes require a blocker handoff comment."
    )
    |> maybe_add_violation(
      expected_state != Contract.current().blocked_state and not truthy?(Map.get(verification, "handoff_comment_exists")),
      "linear_handoff_comment_missing",
      "Human Review Phase 3.6 lanes require a handoff comment."
    )
    |> maybe_add_violation(repo_changed and not truthy?(Map.get(verification, "pr_url_posted")), "linear_pr_url_missing", "Repo-changing Phase 3.6 lanes require the PR URL to be posted to Linear.")
    |> maybe_add_violation(
      lane == "research" and not repo_changed and not truthy?(Map.get(verification, "research_findings_posted")),
      "linear_research_findings_missing",
      "Read-only research lanes require findings to be posted to Linear."
    )
  end

  defp merge_runner_findings(evidence, runner_result) do
    violations =
      case runner_result_status(runner_result) do
        "timeout" -> [artifact_violation("lane_runtime_timeout", "Phase 3.6 lane exceeded the supervised max runtime.")]
        "error" -> [artifact_violation("lane_runner_failed", "Phase 3.6 lane runner exited before handoff verification completed.")]
        _ -> []
      end

    evidence
    |> Map.update!("protocol_violations", &(violations ++ &1))
    |> Map.put("finalization_gate_result", if(violations == [], do: evidence["finalization_gate_result"], else: "blocked"))
  end

  defp merge_artifact_findings(evidence, artifact_result, external_verification) do
    artifact_violations = Map.get(artifact_result, "violations", [])
    artifact_warnings = Map.get(artifact_result, "warnings", [])
    external_violations = Map.get(external_verification, "violations", [])

    evidence
    |> Map.update!("protocol_violations", &(artifact_violations ++ external_violations ++ &1))
    |> Map.update!("protocol_warnings", &(artifact_warnings ++ &1))
    |> Map.put("finalization_gate_result", if(artifact_violations == [] and external_violations == [], do: evidence["finalization_gate_result"], else: "blocked"))
  end

  defp apply_completion_contract(evidence, lane, issue, telemetry, deps) do
    completion_states = completion_states(lane, evidence, telemetry)
    violations = completion_contract_violations(lane, evidence, completion_states)

    if violations == [] do
      evidence
      |> Map.put("lane_contract_status", "passed")
      |> Map.put("completion_states", completion_states)
      |> Map.put("blocker_reason", nil)
    else
      blocker_reason = completion_blocker_reason(violations)
      blocked_transition = maybe_block_completion_contract_issue(evidence, issue, blocker_reason, completion_states, deps)

      evidence
      |> Map.put("runner_status", failed_runner_status(evidence["runner_status"]))
      |> Map.put("lane_contract_status", "failed")
      |> Map.put("completion_states", Map.put(completion_states, "lane_contract_satisfied", false))
      |> Map.put("blocker_reason", blocker_reason)
      |> Map.put("blocked_transition", blocked_transition)
      |> Map.put("final_state", Contract.current().blocked_state)
      |> Map.put("expected_final_state", Contract.current().blocked_state)
      |> Map.put("finalization_gate_result", "blocked")
      |> Map.update!("protocol_violations", &(violations ++ &1))
    end
  end

  defp completion_states(lane, evidence, telemetry) do
    states = Map.get(telemetry, "completion_states") || %{}

    %{
      "codex_process_started" =>
        truthy?(Map.get(states, "codex_process_started")) or
          truthy?(Map.get(telemetry, "codex_process_started")) or not blank?(Map.get(telemetry, "codex_app_server_pid")),
      "codex_prompt_delivered" =>
        truthy?(Map.get(states, "codex_prompt_delivered")) or
          truthy?(Map.get(telemetry, "codex_prompt_delivered")) or truthy?(Map.get(telemetry, "prompt_delivered")),
      "codex_work_observed" =>
        truthy?(Map.get(states, "codex_work_observed")) or
          truthy?(Map.get(telemetry, "codex_work_observed")) or work_observed?(evidence, telemetry),
      "symphony_handoff_ready_seen" =>
        truthy?(Map.get(states, "symphony_handoff_ready_seen")) or
          truthy?(Map.get(telemetry, "symphony_handoff_ready_seen")),
      "lane_contract_satisfied" => preliminary_lane_contract_satisfied?(lane, evidence)
    }
  end

  defp work_observed?(evidence, telemetry) do
    integer_field(telemetry, "tool_call_count") > 0 or
      non_empty_list?(Map.get(evidence, "product_changed_files")) or
      non_empty_list?(Map.get(telemetry, "changed_files")) or
      not blank?(Map.get(telemetry, "last_output_at"))
  end

  defp preliminary_lane_contract_satisfied?(lane, evidence) do
    Map.get(evidence, "finalization_gate_result") == "ok" and
      Map.get(evidence, "handoff_artifact_valid") == true and
      (not repo_changing_lane?(lane) or non_empty_list?(Map.get(evidence, "product_changed_files")))
  end

  defp completion_contract_violations(lane, evidence, completion_states) do
    []
    |> maybe_add_completion_violation(
      not truthy?(completion_states["codex_prompt_delivered"]),
      "codex_prompt_not_delivered",
      "Codex process/session completion is insufficient because prompt delivery was not observed."
    )
    |> maybe_add_completion_violation(
      not truthy?(completion_states["codex_work_observed"]),
      "codex_work_not_observed",
      "Codex process/session completion is insufficient because no Codex work or product repository change was observed."
    )
    |> maybe_add_completion_violation(
      not truthy?(completion_states["symphony_handoff_ready_seen"]),
      "symphony_handoff_ready_not_seen",
      "Lane completion signal SYMPHONY_HANDOFF_READY was not observed."
    )
    |> maybe_add_completion_violation(
      repo_changing_lane?(lane) and Map.get(evidence, "handoff_artifact_valid") != true,
      "lane_contract_handoff_artifact_failed",
      "Repo-changing Phase 3.6 lanes require a valid .phase36/handoff.json artifact."
    )
    |> maybe_add_completion_violation(
      repo_changing_lane?(lane) and not non_empty_list?(Map.get(evidence, "product_changed_files")),
      "lane_contract_product_repo_change_missing",
      "Repo-changing Phase 3.6 lanes require at least one product repository change."
    )
    |> maybe_add_completion_violation(
      Map.get(evidence, "finalization_gate_result") != "ok",
      "lane_contract_finalization_gate_blocked",
      "Lane completion contract is not satisfied while the finalization gate is blocked."
    )
  end

  defp maybe_add_completion_violation(violations, true, code, message), do: [artifact_violation(code, message) | violations]
  defp maybe_add_completion_violation(violations, false, _code, _message), do: violations

  defp completion_blocker_reason([%{"code" => code} | _]), do: code
  defp completion_blocker_reason(_violations), do: "lane_completion_contract_failed"

  defp maybe_block_completion_contract_issue(%{"blocked_transition" => %{"status" => "blocked"}} = _evidence, _issue, _reason, _states, _deps) do
    %{"status" => "already_blocked", "handoff_posted" => true}
  end

  defp maybe_block_completion_contract_issue(%{"runner_status" => "timeout"} = evidence, _issue, _reason, _states, _deps) do
    get_in(evidence, ["timeout_diagnostics", "blocked_transition"]) || %{"status" => "timeout_block_handled"}
  end

  defp maybe_block_completion_contract_issue(_evidence, issue, blocker_reason, completion_states, deps) do
    block_completion_contract_issue(issue, blocker_reason, completion_states, deps)
  end

  defp failed_runner_status("timeout"), do: "timeout"
  defp failed_runner_status(_status), do: "error"

  defp artifact_value(%{"artifact" => artifact}, path) when is_map(artifact), do: get_in(artifact, path)
  defp artifact_value(_artifact_result, _path), do: nil

  defp artifact_validation(%{"artifact" => artifact}, telemetry) when is_map(artifact) do
    nested = Map.get(artifact, "validation") || %{}
    telemetry_validation = Map.get(telemetry, "validation") || %{}

    %{
      "required" => first_present([Map.get(artifact, "validation_required"), Map.get(nested, "required"), Map.get(telemetry_validation, "required")]),
      "status" => first_present([Map.get(artifact, "validation_status"), Map.get(nested, "status"), Map.get(telemetry_validation, "status")]),
      "command" => first_present([Map.get(artifact, "validation_command"), Map.get(nested, "command"), Map.get(telemetry_validation, "command")]),
      "reason" => first_present([Map.get(artifact, "validation_reason"), Map.get(nested, "reason"), Map.get(telemetry_validation, "reason")]),
      "command_result" => first_present([Map.get(artifact, "validation_command_result"), Map.get(nested, "command_result"), Map.get(telemetry_validation, "command_result")])
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp artifact_validation(_artifact_result, telemetry), do: Map.get(telemetry, "validation") || %{}

  defp first_present(values) do
    Enum.find(values, fn
      nil -> false
      value when is_binary(value) -> String.trim(value) != ""
      _value -> true
    end)
  end

  defp artifact_or_telemetry_value(artifact_result, telemetry, field) do
    case artifact_value(artifact_result, [field]) do
      nil -> Map.get(telemetry, field)
      value -> value
    end
  end

  defp artifact_gate_evidence(artifact_result, telemetry) do
    Map.new(@artifact_gate_fields, fn field ->
      {String.to_atom(field), artifact_or_telemetry_value(artifact_result, telemetry, field)}
    end)
    |> Enum.reject(fn {_field, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp effective_changed_files(changed_files, observed_changed_files) do
    observed_changed_files
    |> changed_files_or(changed_files)
    |> FinalizationGate.product_changed_files()
  end

  defp changed_files_or(files, _fallback) when is_list(files) and files != [], do: files
  defp changed_files_or(_files, fallback) when is_list(fallback), do: fallback
  defp changed_files_or(_files, _fallback), do: []

  defp control_artifacts(changed_files, observed_changed_files, artifact_result) do
    artifact_files =
      if handoff_artifact_exists?(artifact_result) do
        [@handoff_artifact_relpath]
      else
        []
      end

    (artifact_files ++ List.wrap(changed_files) ++ List.wrap(observed_changed_files))
    |> Enum.map(&to_string/1)
    |> Enum.filter(&FinalizationGate.control_artifact?/1)
    |> Enum.uniq()
  end

  defp handoff_artifact_exists?(%{"path" => path}) when is_binary(path), do: File.exists?(path)
  defp handoff_artifact_exists?(_artifact_result), do: false

  defp handoff_artifact_path(workspace_path) when is_binary(workspace_path), do: Path.join(workspace_path, @handoff_artifact_relpath)
  defp handoff_artifact_path(_workspace_path), do: @handoff_artifact_relpath

  defp repo_changed?(artifact_repo_changed, observed_changed_files, pr_url) do
    truthy?(artifact_repo_changed) or non_empty_list?(observed_changed_files) or not blank?(pr_url)
  end

  defp findings_posted?(lane, artifact_result, comments) do
    lane == "research" and (truthy?(artifact_value(artifact_result, ["handoff", "linear_comment_posted"])) or handoff_comment(comments) != nil)
  end

  defp validation_status(%{} = validation) do
    value = Map.get(validation, "status")
    if is_atom(value), do: Atom.to_string(value), else: value
  end

  defp validation_status(_validation), do: nil

  defp repo_changing_lane?(lane), do: lane in ["docs", "bug", "feature", "refactor", "test", "chore"]

  defp artifact_violation(code, message), do: %{"code" => code, "message" => message, "severity" => "error"}

  defp maybe_add_violation(violations, true, code, message), do: [artifact_violation(code, message) | violations]
  defp maybe_add_violation(violations, false, _code, _message), do: violations

  defp list_field(map, key) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      values when is_list(values) -> Enum.map(values, &to_string/1)
      _ -> []
    end
  end

  defp pr_links_issue?(verification, %Issue{} = issue) do
    title = Map.get(verification, "pr_title") || Map.get(verification, "title") || ""
    body = Map.get(verification, "pr_body") || Map.get(verification, "body") || ""
    text = title <> "\n" <> body
    identifier = issue.identifier || issue.id || ""

    String.contains?(text, identifier) and (blank?(issue.url) or String.contains?(text, issue.url))
  end

  defp pr_links_issue?(_verification, _issue), do: false

  defp fetch_issue!(issue_id, deps) do
    deps
    |> graphql_data!(@issue_query, %{id: issue_id}, "issue")
    |> normalize_issue()
  end

  defp fetch_issue_snapshot(issue_id, deps) do
    case deps.linear_graphql.(@issue_query, %{id: issue_id}) do
      {:ok, %{"data" => %{"issue" => %{} = issue}}} -> issue
      _ -> %{}
    end
  end

  defp normalize_issue(issue) do
    %Issue{
      id: issue["id"],
      identifier: issue["identifier"],
      title: issue["title"],
      description: issue["description"],
      state: get_in(issue, ["state", "name"]),
      state_id: get_in(issue, ["state", "id"]),
      branch_name: issue["branchName"],
      url: issue["url"],
      project: normalize_project(issue["project"]),
      team: normalize_team(issue["team"]),
      available_states: get_in(issue, ["team", "states", "nodes"]) || [],
      labels: extract_labels(issue)
    }
  end

  defp normalize_project(%{} = project) do
    %{
      id: project["id"],
      name: project["name"],
      slug_id: project["slugId"],
      url: project["url"]
    }
  end

  defp normalize_project(_project), do: nil

  defp normalize_team(%{} = team) do
    %{
      id: team["id"],
      key: team["key"],
      name: team["name"]
    }
  end

  defp normalize_team(_team), do: nil

  defp extract_labels(%{"labels" => %{"nodes" => labels}}) when is_list(labels) do
    labels
    |> Enum.map(& &1["name"])
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&String.downcase/1)
  end

  defp extract_labels(_issue), do: []

  defp graphql_data!(deps, query, variables, key) do
    case deps.linear_graphql.(query, variables) do
      {:ok, %{"data" => %{^key => value}}} ->
        value

      {:ok, %{"errors" => errors}} ->
        Mix.raise("Linear GraphQL #{key} failed: #{inspect(errors)}")

      {:ok, payload} ->
        Mix.raise("Linear GraphQL #{key} returned unexpected payload: #{inspect(payload)}")

      {:error, reason} ->
        Mix.raise("Linear GraphQL #{key} request failed: #{inspect(reason)}")
    end
  end

  defp fetch_single!(%{"nodes" => [node | _]}, _name, _value), do: node
  defp fetch_single!(_payload, name, value), do: Mix.raise("Expected Linear #{name} named #{inspect(value)} to exist.")

  defp state_id!(states, state_name) do
    states
    |> Enum.find(fn state -> state["name"] == state_name || state[:name] == state_name end)
    |> case do
      %{"id" => id} when is_binary(id) -> id
      %{id: id} when is_binary(id) -> id
      _ -> Mix.raise("Expected Linear state #{inspect(state_name)} to exist.")
    end
  end

  defp default_run_agent(issue, preflight, output_path) do
    workflow_path = live_workflow_file!(preflight, output_path)
    original_workflow_path = Workflow.workflow_file_path()
    orchestrator_pid = Process.whereis(SymphonyElixir.Orchestrator)

    try do
      if is_pid(orchestrator_pid) do
        :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator)
      end

      Workflow.set_workflow_file_path(workflow_path)

      case AgentRunner.run(issue, self(),
             max_turns: lane_max_turns(issue),
             auto_publish_from_main: true,
             before_codex_start: &live_smoke_codex_start_preflight/3
           ) do
        :ok ->
          {:ok,
           collect_runtime_messages(issue.id)
           |> telemetry_from_messages()}

        other ->
          {:error, {:unexpected_agent_runner_result, other}, collect_runtime_messages(issue.id) |> telemetry_from_messages()}
      end
    rescue
      error ->
        {:error, {error, __STACKTRACE__}, collect_runtime_messages(issue.id) |> telemetry_from_messages()}
    catch
      kind, reason ->
        {:error, {kind, reason}, collect_runtime_messages(issue.id) |> telemetry_from_messages()}
    after
      restart_orchestrator_if_needed()
      Workflow.set_workflow_file_path(original_workflow_path)
    end
  end

  defp live_workflow_file!(preflight, output_path) do
    root = Path.join(System.tmp_dir!(), "phase36-live-smoke-workspaces")
    workflow_path = Path.join(Path.dirname(output_path), "phase36-live-smoke-WORKFLOW.md")
    File.mkdir_p!(Path.dirname(workflow_path))

    File.write!(workflow_path, live_workflow(preflight.project["slugId"], root))
    workflow_path
  end

  @doc false
  @spec live_smoke_codex_start_preflight_for_test(Path.t(), Issue.t(), term()) ::
          :ok | {:ok, map()} | {:error, String.t(), map()}
  def live_smoke_codex_start_preflight_for_test(workspace, issue, worker_host) do
    live_smoke_codex_start_preflight(workspace, issue, worker_host)
  end

  defp live_smoke_codex_start_preflight(workspace, issue, nil) do
    metadata = live_smoke_sandbox_metadata(workspace)

    if repo_changing_issue?(issue) do
      probe = Map.get(metadata, "active_workspace_git_root_writable_probe") || %{}

      cond do
        probe["status"] == "ok" ->
          if active_git_root_in_sandbox?(metadata) do
            {:ok, metadata}
          else
            {:error, "active_workspace_git_root_not_in_sandbox_writable_roots", metadata}
          end

        probe["status"] == "missing" ->
          {:error, "active_workspace_git_root_missing", metadata}

        true ->
          {:error, "active_workspace_git_root_not_writable", metadata}
      end
    else
      {:ok, metadata}
    end
  end

  defp live_smoke_codex_start_preflight(workspace, _issue, worker_host) when is_binary(worker_host) do
    {:ok,
     %{
       "active_workspace_path" => workspace,
       "active_workspace_git_root" => Path.join(workspace, ".git"),
       "active_workspace_git_root_writable_probe" => %{
         "status" => "skipped",
         "reason" => "remote_worker_preflight_not_supported_locally"
       }
     }}
  end

  defp live_smoke_sandbox_metadata(workspace) do
    git_root = Path.join(workspace, ".git")
    runtime_settings = Config.codex_runtime_settings(workspace)

    policy =
      case runtime_settings do
        {:ok, settings} -> settings.turn_sandbox_policy
        {:error, _reason} -> %{}
      end

    %{
      "active_workspace_path" => workspace,
      "active_workspace_git_root" => git_root,
      "active_workspace_git_root_writable_probe" => probe_git_root_writable(git_root),
      "sandbox_policy_type" => sandbox_policy_type(policy),
      "sandbox_writable_roots" => sandbox_writable_roots(policy)
    }
  end

  defp repo_changing_issue?(%Issue{lane_classification: %{lane: lane}}) when is_atom(lane) do
    repo_changing_lane?(Atom.to_string(lane))
  end

  defp repo_changing_issue?(%Issue{lane_classification: %{lane: lane}}) when is_binary(lane) do
    repo_changing_lane?(lane)
  end

  defp repo_changing_issue?(_issue), do: true

  defp active_git_root_in_sandbox?(metadata) do
    git_root = Map.get(metadata, "active_workspace_git_root")
    writable_roots = Map.get(metadata, "sandbox_writable_roots") || []

    is_binary(git_root) and git_root in writable_roots
  end

  defp probe_git_root_writable(git_root) when is_binary(git_root) do
    cond do
      not File.dir?(git_root) ->
        %{"status" => "missing", "path" => git_root}

      true ->
        probe_path = Path.join(git_root, ".symphony-live-smoke-write-probe-#{System.unique_integer([:positive])}")

        case File.write(probe_path, "probe") do
          :ok ->
            _ = File.rm(probe_path)
            %{"status" => "ok", "path" => probe_path}

          {:error, reason} ->
            %{"status" => "error", "path" => probe_path, "reason" => inspect(reason)}
        end
    end
  end

  defp sandbox_policy_type(policy) when is_map(policy), do: Map.get(policy, "type") || Map.get(policy, :type)
  defp sandbox_policy_type(_policy), do: nil

  defp sandbox_writable_roots(policy) when is_map(policy) do
    case Map.get(policy, "writableRoots") || Map.get(policy, :writableRoots) do
      roots when is_list(roots) -> Enum.map(roots, &to_string/1)
      _ -> []
    end
  end

  defp sandbox_writable_roots(_policy), do: []

  defp live_workflow(project_slug, workspace_root) do
    """
    ---
    tracker:
      kind: linear
      project_slug: "#{project_slug}"
      active_states:
        - Todo
        - In Progress
        - Merging
        - Rework
      terminal_states:
        - Done
        - Duplicate
        - Canceled
    workspace:
      root: #{workspace_root}
    hooks:
      timeout_ms: 600000
      after_create: |
        git clone --branch main --single-branch git@github-personal:moizghumann/symphony.git .
        git rev-parse --verify HEAD
        test -f elixir/mix.exs
        if command -v mise >/dev/null 2>&1; then
          cd elixir && mise trust && mise exec -- mix deps.get
        fi
    agent:
      max_concurrent_agents: 1
      max_turns: 8
    codex:
      command: codex --config shell_environment_policy.inherit=all --config 'model="gpt-5.5"' --config model_reasoning_effort=xhigh app-server
      approval_policy: never
      thread_sandbox: workspace-write
      turn_sandbox_policy:
        type: workspaceWrite
        writableRoots:
          - #{workspace_root}
          - #{workspace_root}/.git
        networkAccess: true
    protocol:
      version: "1"
      repo_changes_require_pr: true
      human_review_requires_pr: true
      blocked_state: "Blocked"
      review_state: "Human Review"
      in_progress_state: "In Progress"
      done_state: "Done"
      canceled_state: "Canceled"
      duplicate_state: "Duplicate"
      allow_ticket_to_disable_pr: false
      generic_linear_graphql_policy: fallback_only
      validation_gate: true
      finalization_gate: true
    ---

    You are working on Linear issue `{{ issue.identifier }}`.

    This is a Phase 3.6 live-smoke run for `moizghumann/symphony`.
    Follow the lane packet exactly. Do not start Phase 4.
    Do not weaken protocol gates. Do not fake live-smoke success.
    The current working directory is already the managed repository clone.
    Make the requested lane-scoped edit only.
    Do not create a second clone or work from `/tmp` for repository changes.
    Before emitting `SYMPHONY_HANDOFF_READY`, write `.phase36/handoff.json` in the managed workspace.
    For repo-changing lanes, this artifact is the pre-handoff contract: keep every required key present, use `null` only for branch/commit/PR values that Symphony finalizes after `SYMPHONY_HANDOFF_READY`, and explain those provisional values in `protocol_notes`.
    The handoff artifact must be valid JSON and include:
    - `lane`
    - `linear_issue_identifier`
    - `status`
    - `repo_changed`
    - `branch_name`
    - `commit_sha`
    - `pr_url`
    - `changed_files`
    - `validation.required`
    - `validation.status`
    - `validation.command`
    - `validation.reason`
    - `handoff.linear_comment_posted`
    - `handoff.final_state_requested`
    - `protocol_notes`
    For `test` lane artifacts, also include explicit top-level evidence fields:
    - `targeted_tests_run`: `true` only when the targeted validation was run
    - `test_coverage_added`: `true` only when test coverage was added or improved
    - `validation_command`: exact command that was run
    - `validation_status`: `passed`, `failed`, or `not_run`
    - `validation_reason`: short evidence summary
    Do not emit `SYMPHONY_HANDOFF_READY` until the file exists and reflects the final handoff state.
    """
  end

  defp lane_max_turns(%Issue{lane_classification: %{lane: lane}}) when is_atom(lane) do
    LanePolicy.policy_for(lane).max_turns
  end

  defp lane_max_turns(_issue), do: 3

  defp collect_runtime_messages(issue_id) do
    receive do
      {:worker_runtime_info, ^issue_id, runtime_info} ->
        [runtime_info | collect_runtime_messages(issue_id)]

      {:codex_worker_update, ^issue_id, message} ->
        [message | collect_runtime_messages(issue_id)]
    after
      0 -> []
    end
  end

  defp telemetry_from_messages(messages) do
    %{
      "tool_call_count" => count_tool_calls(messages),
      "generic_linear_graphql_calls" => count_tool_calls(messages, "linear_graphql"),
      "narrow_linear_lifecycle_calls" => count_narrow_lifecycle_calls(messages),
      "generic_linear_graphql_call_details" => generic_graphql_details(messages)
    }
    |> Map.merge(token_usage(messages))
    |> Map.merge(workspace_git_telemetry(messages))
    |> Map.merge(session_telemetry(messages))
    |> Map.merge(sandbox_telemetry(messages))
    |> Map.merge(completion_telemetry(messages))
  end

  defp count_tool_calls(messages) do
    Enum.count(messages, fn message ->
      event = map_get(message, :event)
      event in [:tool_call_completed, :tool_call_failed, "tool_call_completed", "tool_call_failed"]
    end)
  end

  defp count_tool_calls(messages, tool_name) do
    Enum.count(messages, fn message ->
      map_get(message, :tool_name) == tool_name
    end)
  end

  defp count_narrow_lifecycle_calls(messages) do
    Enum.count(messages, fn message ->
      tool_name = map_get(message, :tool_name)
      is_binary(tool_name) and String.starts_with?(tool_name, "linear_") and tool_name != "linear_graphql"
    end)
  end

  defp generic_graphql_details(messages) do
    messages
    |> Enum.filter(&(map_get(&1, :tool_name) == "linear_graphql"))
    |> Enum.map(fn message ->
      %{
        operation: graphql_operation(map_get(message, :tool_arguments) || %{}),
        fallback_reason: nil,
        narrow_tool_available: true,
        narrow_tool_failed: false
      }
    end)
  end

  defp graphql_operation(%{"query" => query}) when is_binary(query), do: query |> String.split() |> Enum.take(2) |> Enum.join(" ")
  defp graphql_operation(_args), do: "unknown"

  defp token_usage(messages) do
    usage =
      messages
      |> Enum.map(&find_usage/1)
      |> Enum.reject(&is_nil/1)
      |> List.last()

    case usage do
      %{} ->
        input = integer_field(usage, "input_tokens")
        cached = integer_field(usage, "cached_input_tokens")
        output = integer_field(usage, "output_tokens")
        total = integer_field(usage, "total_tokens")

        %{
          "effective_tokens" => input - cached + output,
          "gross_context_tokens" => total,
          "cached_input_tokens" => cached,
          "output_tokens" => output,
          "budget_state" => "ok"
        }

      _ ->
        %{}
    end
  end

  defp find_usage(%{} = message) do
    cond do
      Map.has_key?(message, "usage") -> message["usage"]
      Map.has_key?(message, :usage) -> message[:usage]
      true -> message |> Map.values() |> Enum.find_value(&find_usage/1)
    end
  end

  defp find_usage(list) when is_list(list), do: Enum.find_value(list, &find_usage/1)
  defp find_usage(_value), do: nil

  defp workspace_git_telemetry(messages) do
    runtime_info =
      Enum.find(messages, fn
        %{workspace_path: path} when is_binary(path) -> true
        %{"workspace_path" => path} when is_binary(path) -> true
        _ -> false
      end)

    workspace_path = map_get(runtime_info || %{}, :workspace_path)

    if is_binary(workspace_path) and File.dir?(Path.join(workspace_path, ".git")) do
      %{
        "workspace_path" => workspace_path,
        "branch_name" => git(workspace_path, ["branch", "--show-current"]),
        "commit_sha" => git(workspace_path, ["rev-parse", "HEAD"]),
        "changed_files" => git_lines(workspace_path, ["diff", "--name-only", "origin/main...HEAD"])
      }
    else
      case workspace_path do
        path when is_binary(path) -> %{"workspace_path" => path}
        _ -> %{}
      end
    end
  end

  defp session_telemetry(messages) do
    %{
      "session_id" => messages |> Enum.find_value(&map_get(&1, :session_id)),
      "codex_app_server_pid" => messages |> Enum.find_value(&map_get(&1, :codex_app_server_pid)),
      "last_output_at" => messages |> Enum.map(&map_get(&1, :timestamp)) |> Enum.reject(&is_nil/1) |> List.last() |> normalize_timestamp()
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp sandbox_telemetry(messages) do
    %{
      "sandbox_policy_type" => messages |> Enum.find_value(&map_get(&1, :sandbox_policy_type)),
      "sandbox_writable_roots" => messages |> Enum.find_value(&map_get(&1, :sandbox_writable_roots)),
      "active_workspace_path" => messages |> Enum.find_value(&map_get(&1, :active_workspace_path)),
      "active_workspace_git_root" => messages |> Enum.find_value(&map_get(&1, :active_workspace_git_root)),
      "active_workspace_git_root_writable_probe" => messages |> Enum.find_value(&map_get(&1, :active_workspace_git_root_writable_probe))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp completion_telemetry(messages) do
    states = %{
      "codex_process_started" => Enum.any?(messages, &(not blank?(map_get(&1, :codex_app_server_pid)))),
      "codex_prompt_delivered" => Enum.any?(messages, &(map_get(&1, :event) in [:prompt_delivered, "prompt_delivered"])),
      "codex_work_observed" => Enum.any?(messages, &work_message?/1),
      "symphony_handoff_ready_seen" => Enum.any?(messages, &handoff_ready_message?/1),
      "lane_contract_satisfied" => false
    }

    %{
      "completion_states" => states,
      "codex_process_started" => states["codex_process_started"],
      "codex_prompt_delivered" => states["codex_prompt_delivered"],
      "codex_work_observed" => states["codex_work_observed"],
      "symphony_handoff_ready_seen" => states["symphony_handoff_ready_seen"]
    }
  end

  defp work_message?(message) do
    event = map_get(message, :event)

    event in [
      :stream_output,
      "stream_output",
      :tool_call_completed,
      "tool_call_completed",
      :tool_call_failed,
      "tool_call_failed",
      :notification,
      "notification",
      :turn_completed,
      "turn_completed"
    ]
  end

  defp handoff_ready_message?(message) when is_binary(message),
    do: String.contains?(message, "SYMPHONY_HANDOFF_READY")

  defp handoff_ready_message?(%_{}), do: false

  defp handoff_ready_message?(message) when is_map(message) do
    Enum.any?(message, fn {_key, value} -> handoff_ready_message?(value) end)
  end

  defp handoff_ready_message?(message) when is_list(message) do
    Enum.any?(message, &handoff_ready_message?/1)
  end

  defp handoff_ready_message?(_message), do: false

  defp normalize_timestamp(%DateTime{} = timestamp), do: timestamp |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  defp normalize_timestamp(timestamp) when is_binary(timestamp), do: timestamp
  defp normalize_timestamp(_timestamp), do: nil

  defp git(workspace, args) do
    case System.cmd("git", args, cd: workspace, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      _ -> nil
    end
  end

  defp git_lines(workspace, args) do
    case git(workspace, args) do
      nil -> nil
      "" -> []
      output -> String.split(output, "\n", trim: true)
    end
  end

  defp restart_orchestrator_if_needed do
    if is_nil(Process.whereis(SymphonyElixir.Orchestrator)) do
      case Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, :not_found} -> :ok
      end
    end
  end

  defp default_github_preflight do
    with :ok <- run_gh(["auth", "status"]),
         {:ok, repo_payload} <- run_gh_json(["repo", "view", @repo, "--json", "nameWithOwner,viewerPermission,defaultBranchRef"]) do
      case repo_payload do
        %{"nameWithOwner" => @repo} ->
          viewer_permission = Map.get(repo_payload, "viewerPermission")

          if github_push_permission?(viewer_permission) do
            {:ok,
             %{
               "auth_read" => "passed",
               "repo" => @repo,
               "viewer_permission" => viewer_permission,
               "push_permission_check" => "passed",
               "default_branch" => get_in(repo_payload, ["defaultBranchRef", "name"])
             }}
          else
            Mix.raise("GitHub repo preflight did not confirm push permission for #{@repo}: #{inspect(viewer_permission)}")
          end

        payload ->
          Mix.raise("GitHub repo preflight returned unexpected payload: #{inspect(payload)}")
      end
    end
  end

  defp github_push_permission?(permission), do: permission in ["WRITE", "MAINTAIN", "ADMIN"]

  defp default_local_socket_preflight do
    case :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}]) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        {:ok, %{"socket" => "passed"}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp default_github_verify(artifact, context) do
    branch_name = Map.get(artifact, "branch_name")
    commit_sha = Map.get(artifact, "commit_sha")
    pr_url = Map.get(artifact, "pr_url")
    workspace_path = Map.get(context, :workspace_path)

    with true <- is_binary(pr_url) and pr_url != "",
         {:ok, pr_payload} <- run_gh_json_safe(["pr", "view", pr_url, "--json", "url,isDraft,baseRefName,title,body,headRefName,files,commits"]) do
      {:ok,
       %{
         "status" => "completed",
         "branch_exists" => github_branch_exists?(workspace_path, branch_name),
         "commit_exists" => github_commit_exists?(commit_sha),
         "pr_exists" => true,
         "pr_draft" => Map.get(pr_payload, "isDraft"),
         "pr_base_ref" => Map.get(pr_payload, "baseRefName"),
         "pr_title" => Map.get(pr_payload, "title"),
         "pr_body" => Map.get(pr_payload, "body"),
         "pr_url" => Map.get(pr_payload, "url"),
         "changed_files" => pr_changed_files(pr_payload)
       }}
    else
      {:error, reason} ->
        {:ok,
         %{
           "status" => "completed",
           "branch_exists" => github_branch_exists?(workspace_path, branch_name),
           "commit_exists" => github_commit_exists?(commit_sha),
           "pr_exists" => false,
           "pr_lookup_error" => inspect(reason),
           "changed_files" => []
         }}

      false ->
        {:ok,
         %{
           "status" => "completed",
           "branch_exists" => github_branch_exists?(workspace_path, branch_name),
           "commit_exists" => github_commit_exists?(commit_sha),
           "pr_exists" => false,
           "pr_lookup_error" => "missing_pr_url",
           "changed_files" => []
         }}
    end
  end

  defp github_branch_exists?(workspace_path, branch_name) when is_binary(workspace_path) and is_binary(branch_name) do
    case git(workspace_path, ["ls-remote", "--heads", "origin", branch_name]) do
      output when is_binary(output) -> String.trim(output) != ""
      _ -> false
    end
  end

  defp github_branch_exists?(_workspace_path, _branch_name), do: false

  defp github_commit_exists?(commit_sha) when is_binary(commit_sha) and commit_sha != "" do
    case run_gh(["api", "repos/#{@repo}/commits/#{commit_sha}"]) do
      :ok -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp github_commit_exists?(_commit_sha), do: false

  defp pr_changed_files(%{"files" => files}) when is_list(files) do
    files
    |> Enum.map(fn
      %{"path" => path} -> path
      %{path: path} -> path
      _ -> nil
    end)
    |> Enum.reject(&blank?/1)
  end

  defp pr_changed_files(_payload), do: []

  defp default_linear_verify(_issue, artifact, snapshot, context) do
    comments = get_in(snapshot, ["comments", "nodes"]) || []
    pr_url = Map.get(artifact, "pr_url")
    expected_state = Map.get(context, :expected_final_state)
    repo_changed = Map.get(context, :repo_changed)
    lane = Map.get(context, :lane)

    {:ok,
     %{
       "status" => "completed",
       "final_state" => get_in(snapshot, ["state", "name"]),
       "expected_final_state" => expected_state,
       "handoff_comment_exists" => handoff_comment(comments) != nil,
       "blocker_comment_exists" => blocker_comment(comments) != nil,
       "pr_url_posted" => not repo_changed or comment_body_contains(comments, pr_url),
       "research_findings_posted" => lane != "research" or repo_changed or handoff_comment(comments) != nil
     }}
  end

  defp default_inspect_workspace_git(workspace_path) when is_binary(workspace_path) do
    %{
      "workspace_path" => workspace_path,
      "status" => git(workspace_path, ["status", "--short"]),
      "branch_name" => git(workspace_path, ["branch", "--show-current"]),
      "commit_sha" => git(workspace_path, ["rev-parse", "HEAD"]),
      "changed_files" => git_lines(workspace_path, ["diff", "--name-only", "origin/main...HEAD"])
    }
  end

  defp default_inspect_workspace_git(_workspace_path), do: %{"status" => "workspace_unknown", "changed_files" => []}

  defp default_workspace_path_for_issue(%Issue{identifier: identifier}) when is_binary(identifier) do
    safe_identifier = String.replace(identifier, ~r/[^a-zA-Z0-9._-]/, "_")
    Path.join(Config.settings!().workspace.root, safe_identifier)
  end

  defp default_workspace_path_for_issue(_issue), do: nil

  defp run_gh(args) do
    case System.cmd("gh", args, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> Mix.raise("gh #{Enum.join(args, " ")} failed with status #{status}: #{output}")
    end
  end

  defp run_gh_json(args) do
    case System.cmd("gh", args, stderr_to_stdout: true) do
      {output, 0} -> Jason.decode(output)
      {output, status} -> Mix.raise("gh #{Enum.join(args, " ")} failed with status #{status}: #{output}")
    end
  end

  defp run_gh_json_safe(args) do
    case System.cmd("gh", args, stderr_to_stdout: true) do
      {output, 0} -> Jason.decode(output)
      {output, status} -> {:error, {status, output}}
    end
  end

  defp default_linear_graphql(query, variables) do
    token = System.get_env("LINEAR_API_KEY")

    Req.post("https://api.linear.app/graphql",
      headers: [{"Authorization", token}, {"Content-Type", "application/json"}],
      json: %{"query" => query, "variables" => variables},
      connect_options: [timeout: 30_000]
    )
    |> case do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, response} -> {:error, {:linear_api_status, response.status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp runtime_deps do
    %{
      getenv: &System.get_env/1,
      github_preflight: &default_github_preflight/0,
      local_socket_preflight: &default_local_socket_preflight/0,
      linear_graphql: &default_linear_graphql/2,
      github_verify: &default_github_verify/2,
      linear_verify: &default_linear_verify/4,
      inspect_workspace_git: &default_inspect_workspace_git/1,
      workspace_path_for_issue: &default_workspace_path_for_issue/1,
      move_issue_to_state: &Tracker.move_issue_to_state/2,
      post_handoff_comment: &Tracker.post_handoff_comment/2,
      run_agent: &default_run_agent/3,
      write_file: &File.write!/2,
      lane_runtime_ms: fn -> env_integer("PHASE36_LANE_TIMEOUT_MS", @default_lane_runtime_ms) end,
      heartbeat_interval_ms: fn -> env_integer("PHASE36_HEARTBEAT_INTERVAL_MS", @default_heartbeat_interval_ms) end,
      monotonic_time: fn -> System.monotonic_time(:millisecond) end,
      now: &DateTime.utc_now/0,
      shell: Mix.shell()
    }
  end

  defp env_integer(name, default) do
    case System.get_env(name) do
      nil -> default
      value -> parse_positive_integer(value, default)
    end
  end

  defp timestamp(deps) do
    deps.now.()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp safety_gate_summary do
    %{
      "RUN_REAL_SMOKE" => "must equal true",
      "CONFIRM_LIVE_SMOKE_MUTATION" => "must equal true",
      "LINEAR_API_KEY" => "must be present",
      "GH_TOKEN_or_GITHUB_TOKEN" => "one must be present",
      "github_preflight" => "gh auth status, repo view, and non-mutating push permission check must pass",
      "mix_pubsub_local_socket_preflight" => "local socket creation must pass under the command environment",
      "linear_preflight" => "viewer and exact Agent Workbench statuses must pass"
    }
  end

  defp find_pr_url(comments) do
    comments
    |> Enum.map(& &1["body"])
    |> Enum.reject(&is_nil/1)
    |> Enum.find_value(fn body ->
      ~r/Draft PR:\s*(https?:\/\/\S+)/
      |> Regex.run(body)
      |> case do
        [_match, url] -> String.trim_trailing(url, ".")
        _ -> nil
      end
    end)
  end

  defp handoff_comment(comments) do
    Enum.find(comments, fn comment ->
      body = comment["body"] || ""
      String.contains?(body, "Symphony Handoff") or String.contains?(body, "Draft PR:")
    end)
  end

  defp blocker_comment(comments) do
    Enum.find(comments, fn comment ->
      body = comment["body"] || ""
      String.contains?(body, "Symphony Handoff Blocked") or String.contains?(String.downcase(body), "blocker")
    end)
  end

  defp comment_body_contains(_comments, value) when not is_binary(value) or value == "", do: false

  defp comment_body_contains(comments, value) do
    Enum.any?(comments, fn comment ->
      body = comment["body"] || ""
      String.contains?(body, value)
    end)
  end

  defp handoff_comment_id_or_url(comments) do
    case handoff_comment(comments) do
      %{"url" => url} when is_binary(url) -> url
      %{"id" => id} when is_binary(id) -> id
      _ -> nil
    end
  end

  defp map_get(nil, _key), do: nil
  defp map_get(map, key) when is_map(map) and is_atom(key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp integer_field(map, key) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      value when is_integer(value) -> value
      _ -> 0
    end
  end

  defp stringify_keys(map) when is_map(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp missing?(nil), do: true
  defp missing?([]), do: true
  defp missing?(""), do: true
  defp missing?(_value), do: false

  defp non_empty_list?(value), do: is_list(value) and value != []

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(1), do: true
  defp truthy?(_value), do: false

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(nil), do: true
  defp blank?(_value), do: false

  defp shell(deps), do: Map.get(deps, :shell, Mix.shell())
end
