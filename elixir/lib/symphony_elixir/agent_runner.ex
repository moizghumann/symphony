defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.{Config, GitHubHandoff, Linear.Issue, PromptBuilder, Tracker, Workspace}
  alias SymphonyElixir.Protocol.{Contract, FinalizationGate}

  @handoff_ready_marker "SYMPHONY_HANDOFF_READY"

  @type worker_host :: String.t() | nil

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)

        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host) do
            run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host)
          end
        after
          Workspace.run_after_run_hook(workspace, issue, worker_host)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp codex_message_handler(recipient, issue) do
    fn message ->
      record_handoff_ready(message, issue)
      send_codex_update(recipient, issue, message)
    end
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)
    reset_handoff_ready()

    turn_context = %{
      workspace: workspace,
      codex_update_recipient: codex_update_recipient,
      opts: opts,
      issue_state_fetcher: issue_state_fetcher,
      worker_host: worker_host
    }

    with :ok <- run_before_codex_start_hook(workspace, issue, turn_context),
         {:ok, session} <- AppServer.start_session(workspace, worker_host: worker_host) do
      try do
        do_run_codex_turns(session, issue, turn_context, 1, max_turns)
      after
        AppServer.stop_session(session)
      end
    end
  end

  defp run_before_codex_start_hook(workspace, issue, turn_context) do
    case Keyword.get(turn_context.opts, :before_codex_start) do
      hook when is_function(hook, 3) ->
        case hook.(workspace, issue, turn_context.worker_host) do
          :ok ->
            :ok

          {:ok, metadata} when is_map(metadata) ->
            send_codex_update(
              turn_context.codex_update_recipient,
              issue,
              metadata
              |> Map.put_new(:event, :before_codex_start_completed)
              |> Map.put_new(:timestamp, DateTime.utc_now())
            )

            :ok

          {:error, reason, metadata} when is_map(metadata) ->
            send_codex_update(
              turn_context.codex_update_recipient,
              issue,
              metadata
              |> Map.put_new(:event, :before_codex_start_failed)
              |> Map.put_new(:reason, reason)
              |> Map.put_new(:timestamp, DateTime.utc_now())
            )

            {:error, {:before_codex_start_failed, reason}}

          {:error, reason} ->
            {:error, {:before_codex_start_failed, reason}}
        end

      _ ->
        :ok
    end
  end

  defp do_run_codex_turns(
         app_session,
         issue,
         turn_context,
         turn_number,
         max_turns
       ) do
    prompt = build_turn_prompt(issue, turn_context.opts, turn_number, max_turns)

    with {:ok, turn_session} <-
           AppServer.run_turn(
             app_session,
             prompt,
             issue,
             on_message: codex_message_handler(turn_context.codex_update_recipient, issue),
             linear_lifecycle_graphql: Keyword.get(turn_context.opts, :linear_lifecycle_graphql)
           ) do
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{turn_context.workspace} turn=#{turn_number}/#{max_turns}")

      continue_after_turn(issue, app_session, turn_context, turn_number, max_turns, handoff_ready?())
    end
  end

  defp continue_after_turn(issue, app_session, turn_context, turn_number, max_turns, handoff_ready) do
    if handoff_ready do
      complete_handoff(turn_context.workspace, issue, turn_context.worker_host, turn_context.codex_update_recipient, turn_context.opts)
    else
      continue_after_unfinished_turn(issue, app_session, turn_context, turn_number, max_turns)
    end
  end

  defp continue_after_unfinished_turn(issue, app_session, turn_context, turn_number, max_turns) do
    case continue_with_issue?(issue, turn_context.issue_state_fetcher) do
      {:continue, refreshed_issue} when turn_number < max_turns ->
        continue_codex_turn(app_session, refreshed_issue, turn_context, turn_number, max_turns)

      {:continue, refreshed_issue} ->
        Logger.info("Reached lane max_turns for #{issue_context(refreshed_issue)} with issue still active; blocking for human review")

        block_issue_for_max_turns(refreshed_issue, max_turns)

      {:done, _refreshed_issue} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp continue_codex_turn(app_session, refreshed_issue, turn_context, turn_number, max_turns) do
    Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

    do_run_codex_turns(
      app_session,
      refreshed_issue,
      turn_context,
      turn_number + 1,
      max_turns
    )
  end

  defp complete_handoff(workspace, issue, worker_host, codex_update_recipient, opts) do
    handoff_opts =
      opts
      |> Keyword.put_new(:lane, lane_name(issue))
      |> Keyword.put(:lifecycle_recorder, lifecycle_recorder(codex_update_recipient, issue))

    case GitHubHandoff.complete(workspace, issue, worker_host, handoff_opts) do
      {:ok, pr_url} ->
        Logger.info("Completed GitHub handoff for #{issue_context(issue)} pr_url=#{pr_url}")
        :ok

      {:error, reason} ->
        {:error, {:github_handoff_failed, reason}}

      :no_repo_changes ->
        :ok
    end
  end

  defp block_issue_for_max_turns(issue, max_turns) do
    handoff_result =
      Tracker.post_handoff_comment(issue, """
      ## Symphony Handoff Blocked

      Symphony stopped this run because the lane turn budget was exhausted before a draft PR handoff was ready.

      Max turns: #{max_turns}
      Lane: #{lane_name(issue)}
      """)

    _ = move_issue_to_blocked_after_handoff(issue, "max turns exhausted", handoff_result)
    :ok
  end

  defp move_issue_to_blocked_after_handoff(%Issue{} = issue, reason, handoff_result) do
    contract = Contract.current()

    gate_state = %{
      current_state: issue.state,
      available_states: issue.available_states,
      blocker_reason: reason,
      handoff_posted: handoff_result == :ok,
      repo_changed: false,
      changed_files: []
    }

    case FinalizationGate.evaluate(gate_state, contract.blocked_state, contract) do
      {:ok, _gate_result} -> Tracker.move_issue_to_blocked(issue)
      {:blocked, gate_result} -> {:error, {:finalization_gate_blocked, gate_result}}
    end
  end

  defp lane_name(%Issue{lane_classification: %{lane: lane}}), do: lane
  defp lane_name(_issue), do: "unknown"

  defp lifecycle_recorder(recipient, %Issue{id: issue_id}) when is_binary(issue_id) and is_pid(recipient) do
    fn lifecycle_event ->
      send(
        recipient,
        {:codex_worker_update, issue_id,
         lifecycle_event
         |> Map.put(:event, :linear_lifecycle_call)
         |> Map.put(:timestamp, DateTime.utc_now())}
      )
    end
  end

  defp lifecycle_recorder(_recipient, _issue), do: fn _lifecycle_event -> :ok end

  defp build_turn_prompt(issue, opts, 1, _max_turns), do: PromptBuilder.build_prompt(issue, opts)

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous Codex turn completed normally, but the Linear issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp reset_handoff_ready do
    Process.put({__MODULE__, :handoff_ready}, false)
  end

  defp record_handoff_ready(message, issue) do
    if handoff_ready_message?(message) or research_linear_handoff_complete?(message, issue) do
      Process.put({__MODULE__, :handoff_ready}, true)
    end
  end

  defp handoff_ready? do
    Process.get({__MODULE__, :handoff_ready}, false) == true
  end

  defp handoff_ready_message?(message) when is_binary(message),
    do: String.contains?(message, @handoff_ready_marker)

  defp handoff_ready_message?(%_{}), do: false

  defp handoff_ready_message?(message) when is_map(message) do
    Enum.any?(message, fn {_key, value} -> handoff_ready_message?(value) end)
  end

  defp handoff_ready_message?(message) when is_list(message) do
    Enum.any?(message, &handoff_ready_message?/1)
  end

  defp handoff_ready_message?(_message), do: false

  defp research_linear_handoff_complete?(message, %Issue{lane_classification: %{lane: :research}}) do
    linear_human_review_success_message?(message)
  end

  defp research_linear_handoff_complete?(_message, _issue), do: false

  defp linear_human_review_success_message?(%{event: event} = message)
       when event in [:tool_call_completed, :linear_lifecycle_call] do
    tool_name = Map.get(message, :tool_name) || Map.get(message, "tool_name")
    result = Map.get(message, :tool_result) || Map.get(message, "tool_result") || %{}

    tool_name == "linear_move_to_human_review" and tool_result_success?(result)
  end

  defp linear_human_review_success_message?(%_{}), do: false

  defp linear_human_review_success_message?(message) when is_map(message) do
    Enum.any?(message, fn {_key, value} -> linear_human_review_success_message?(value) end)
  end

  defp linear_human_review_success_message?(message) when is_list(message) do
    Enum.any?(message, &linear_human_review_success_message?/1)
  end

  defp linear_human_review_success_message?(_message), do: false

  defp tool_result_success?(%{"success" => true}), do: true
  defp tool_result_success?(%{success: true}), do: true
  defp tool_result_success?(_result), do: false

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp selected_worker_host(nil, []), do: nil

  defp selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
