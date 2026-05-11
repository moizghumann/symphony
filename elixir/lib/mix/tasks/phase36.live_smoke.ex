defmodule Mix.Tasks.Phase36.LiveSmoke do
  use Mix.Task

  alias SymphonyElixir.AgentRunner
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
  @default_team_name "Agent Workbench"
  @default_project_name "`Symphony Agent Queue`"
  @default_lanes ["docs", "test", "research"]
  @supported_lanes ["docs", "bug", "feature", "refactor", "test", "chore", "research"]
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

  @project_query """
  query Phase36LiveSmokeProject($name: String!) {
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
    project_name = Keyword.get(opts, :project_name, @default_project_name)

    shell(deps).info(plan(lanes, output_path, team_name, project_name))

    require_env_gates!(deps)
    :ok = deps.github_preflight.()

    preflight = linear_preflight!(deps, team_name, project_name)
    shell(deps).info("Phase 3.6 preflight passed; live mutation gates are satisfied.")

    results =
      Enum.map(lanes, fn lane ->
        run_lane!(lane, preflight, output_path, deps)
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
        "linear" => "passed",
        "team_name" => team_name,
        "project_name" => project_name,
        "statuses" => @expected_status_names
      },
      "results" => results
    }

    deps.write_file.(output_path, Jason.encode!(evidence, pretty: true))
    shell(deps).info("Phase 3.6 live-smoke evidence written to #{output_path}")
    :ok
  end

  defp selected_lanes!(opts, deps) do
    lanes =
      selected_lane_values(opts, deps)
      |> Enum.flat_map(&split_lane_value/1)
      |> Enum.map(&normalize_lane!/1)

    cond do
      lanes == [] ->
        Mix.raise("At least one Phase 3.6 live-smoke lane is required.")

      Enum.uniq(lanes) != lanes ->
        Mix.raise("Duplicate live-smoke lanes are not allowed: #{Enum.join(lanes, ", ")}")

      true ->
        lanes
    end
  end

  defp selected_lane_values(opts, deps) do
    case Keyword.get_values(opts, :lane) do
      [] ->
        case deps.getenv.("PHASE36_SMOKE_LANES") do
          value when is_binary(value) and value != "" -> [value]
          _ -> @default_lanes
        end

      values ->
        values
    end
  end

  defp split_lane_value(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
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

  defp linear_preflight!(deps, team_name, project_name) do
    viewer = graphql_data!(deps, @viewer_query, %{}, "viewer")
    team = fetch_single!(graphql_data!(deps, @team_query, %{name: team_name}, "teams"), "teams", team_name)
    states = get_in(team, ["states", "nodes"]) || []

    case validate_agent_workbench_statuses(states) do
      :ok ->
        :ok

      {:error, diff} ->
        Mix.raise("Agent Workbench statuses did not exactly match Phase 3.6 contract: #{inspect(diff)}")
    end

    project = fetch_single!(graphql_data!(deps, @project_query, %{name: project_name}, "projects"), "projects", project_name)

    %{
      viewer: viewer,
      team: team,
      project: project,
      states: states,
      todo_state_id: state_id!(states, "Todo"),
      in_progress_state_id: state_id!(states, "In Progress")
    }
  end

  defp run_lane!(lane, preflight, output_path, deps) do
    issue = create_issue!(lane, preflight, deps)
    issue = start_issue!(issue, preflight, deps)
    classification = LaneClassifier.classify(issue)
    issue = %{issue | lane_classification: classification}

    runner_result =
      try do
        deps.run_agent.(issue, preflight, output_path)
      rescue
        error ->
          {:error, {error, __STACKTRACE__}}
      catch
        kind, reason ->
          {:error, {kind, reason}}
      end

    snapshot = fetch_issue_snapshot(issue.id, deps)
    evidence = evidence_for_lane(lane, issue, classification, runner_result, snapshot)

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

  defp start_issue!(issue, preflight, deps) do
    case deps.move_issue_to_state.(issue, "In Progress") do
      :ok ->
        %{issue | state: "In Progress", state_id: preflight.in_progress_state_id}

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
          stateId: preflight.todo_state_id
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
      - Leave branch creation, commit, push, and draft PR publication to the parent handoff.
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

  defp evidence_for_lane(lane, issue, classification, runner_result, snapshot) do
    telemetry = telemetry_from_runner_result(runner_result)
    comments = get_in(snapshot, ["comments", "nodes"]) || []
    pr_url = find_pr_url(comments) || Map.get(telemetry, "pr_url")
    changed_files = Map.get(telemetry, "changed_files")
    validation = Map.get(telemetry, "validation") || %{}
    final_state = get_in(snapshot, ["state", "name"]) || issue.state

    gate_result =
      finalization_gate_result(%{
        lane: lane,
        current_state: issue.state,
        available_states: issue.available_states,
        repo_changed: not blank?(pr_url) or non_empty_list?(changed_files),
        changed_files: changed_files || [],
        pr_url: pr_url,
        branch_name: Map.get(telemetry, "branch_name"),
        commit_sha: Map.get(telemetry, "commit_sha"),
        branch_pushed: not blank?(pr_url),
        pr_posted_to_linear: not blank?(pr_url),
        handoff_posted: handoff_comment(comments) != nil,
        validation_status: Map.get(validation, "status", :not_run),
        validation_reason: Map.get(validation, "reason"),
        findings_posted: lane == "research" and handoff_comment(comments) != nil,
        sources_inspected_listed: Map.get(telemetry, "sources_inspected_listed"),
        recommendation_included: Map.get(telemetry, "recommendation_included"),
        budget_state: Map.get(telemetry, "budget_state", :ok),
        generic_linear_graphql_calls: Map.get(telemetry, "generic_linear_graphql_call_details", [])
      })

    evidence =
      %{
        "linear_issue_identifier" => issue.identifier,
        "linear_issue_url" => issue.url,
        "lane" => lane,
        "classification_reason" => classification.reason,
        "final_state" => final_state,
        "pr_url" => pr_url,
        "branch_name" => Map.get(telemetry, "branch_name"),
        "changed_files" => changed_files,
        "validation_status" => Map.get(validation, "status"),
        "validation_command_result" => Map.get(validation, "command_result"),
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
        "missing_evidence" => [],
        "code_seams_needed" => []
      }

    record_missing_evidence(evidence)
  end

  defp telemetry_from_runner_result({:ok, telemetry}) when is_map(telemetry), do: telemetry
  defp telemetry_from_runner_result(_runner_result), do: %{}

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
      :ok = AgentRunner.run(issue, self(), max_turns: lane_max_turns(issue), auto_publish_from_main: true)

      {:ok,
       collect_runtime_messages(issue.id)
       |> telemetry_from_messages()}
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
      timeout_ms: 180000
      after_create: |
        git clone git@github-personal:moizghumann/symphony.git .
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
    Make the requested file edit only. Leave branch creation, commit, push, and draft PR publication to the parent handoff.
    Do not create a second clone or work from `/tmp` for repository changes.
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
        "branch_name" => git(workspace_path, ["branch", "--show-current"]),
        "commit_sha" => git(workspace_path, ["rev-parse", "HEAD"]),
        "changed_files" => git_lines(workspace_path, ["diff", "--name-only", "origin/main...HEAD"])
      }
    else
      %{}
    end
  end

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
         {:ok, repo_payload} <- run_gh_json(["repo", "view", @repo, "--json", "nameWithOwner"]) do
      case repo_payload do
        %{"nameWithOwner" => @repo} -> :ok
        payload -> Mix.raise("GitHub repo preflight returned unexpected payload: #{inspect(payload)}")
      end
    end
  end

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
      linear_graphql: &default_linear_graphql/2,
      move_issue_to_state: &Tracker.move_issue_to_state/2,
      run_agent: &default_run_agent/3,
      write_file: &File.write!/2,
      now: &DateTime.utc_now/0,
      shell: Mix.shell()
    }
  end

  defp safety_gate_summary do
    %{
      "RUN_REAL_SMOKE" => "must equal true",
      "CONFIRM_LIVE_SMOKE_MUTATION" => "must equal true",
      "LINEAR_API_KEY" => "must be present",
      "GH_TOKEN_or_GITHUB_TOKEN" => "one must be present",
      "github_preflight" => "gh auth status and repo view must pass",
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

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(nil), do: true
  defp blank?(_value), do: false

  defp shell(deps), do: Map.get(deps, :shell, Mix.shell())
end
