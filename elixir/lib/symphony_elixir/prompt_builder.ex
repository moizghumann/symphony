defmodule SymphonyElixir.PromptBuilder do
  @moduledoc """
  Builds agent prompts from Linear issue data.
  """

  alias SymphonyElixir.{Config, Workflow}

  @render_opts [strict_variables: true, strict_filters: true]

  @spec build_prompt(SymphonyElixir.Linear.Issue.t(), keyword()) :: String.t()
  def build_prompt(issue, opts \\ []) do
    template =
      Workflow.current()
      |> prompt_template!()
      |> parse_template!()

    rendered_prompt =
      template
      |> Solid.render!(
        %{
          "attempt" => Keyword.get(opts, :attempt),
          "issue" => issue |> Map.from_struct() |> to_solid_map()
        },
        @render_opts
      )
      |> IO.iodata_to_binary()

    [issue_packet_prompt(issue), "\n\n", rendered_prompt]
    |> IO.iodata_to_binary()
  end

  defp issue_packet_prompt(issue) do
    packet =
      issue
      |> issue_packet()
      |> Jason.encode!(pretty: false)

    """
    Symphony orchestrator issue packet:

    ```json
    #{packet}
    ```

    Orchestration boundary:

    - The issue id, state ids, project, team, title, description, and URL have already been resolved by Symphony.
    - Do not call generic Linear GraphQL for normal lifecycle actions.
    - Use the provided narrow Linear helpers for posting handoff, posting blocker, moving to Human Review, and moving to Blocked.
    - Use generic Linear GraphQL only if a narrow helper fails or if the required operation is not supported. If you use generic Linear GraphQL, explain why in the final run trace.
    - Codex owns repository work: edit, validate, commit, push, and summarize. Symphony owns final draft PR creation, the Linear handoff comment, and Human Review/Blocked state transitions.
    - When repository work is complete, committed, pushed, and validated, include the exact marker `SYMPHONY_HANDOFF_READY` in your final response so Symphony can create the draft PR.
    """
  end

  defp issue_packet(issue) do
    issue
    |> Map.from_struct()
    |> Map.take([
      :id,
      :identifier,
      :title,
      :description,
      :url,
      :state,
      :state_id,
      :project,
      :team,
      :available_states,
      :branch_name,
      :labels,
      :priority,
      :blocked_by
    ])
    |> Map.put(:state_ids, state_ids(issue))
    |> to_packet_value()
  end

  defp state_ids(%{available_states: states}) when is_list(states) do
    Map.new(states, fn
      %{name: name, id: id} -> {name, id}
      %{"name" => name, "id" => id} -> {name, id}
      _ -> {nil, nil}
    end)
    |> Map.delete(nil)
  end

  defp state_ids(_issue), do: %{}

  defp to_packet_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_packet_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp to_packet_value(%Date{} = value), do: Date.to_iso8601(value)
  defp to_packet_value(%Time{} = value), do: Time.to_iso8601(value)
  defp to_packet_value(%_{} = value), do: inspect(value)
  defp to_packet_value(value) when is_map(value), do: Map.new(value, fn {key, nested} -> {key, to_packet_value(nested)} end)
  defp to_packet_value(value) when is_list(value), do: Enum.map(value, &to_packet_value/1)
  defp to_packet_value(value), do: value

  defp prompt_template!({:ok, %{prompt_template: prompt}}), do: default_prompt(prompt)

  defp prompt_template!({:error, reason}) do
    raise RuntimeError, "workflow_unavailable: #{inspect(reason)}"
  end

  defp parse_template!(prompt) when is_binary(prompt) do
    Solid.parse!(prompt)
  rescue
    error ->
      reraise %RuntimeError{
                message: "template_parse_error: #{Exception.message(error)} template=#{inspect(prompt)}"
              },
              __STACKTRACE__
  end

  defp to_solid_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), to_solid_value(value)} end)
  end

  defp to_solid_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_solid_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp to_solid_value(%Date{} = value), do: Date.to_iso8601(value)
  defp to_solid_value(%Time{} = value), do: Time.to_iso8601(value)
  defp to_solid_value(%_{} = value), do: value |> Map.from_struct() |> to_solid_map()
  defp to_solid_value(value) when is_map(value), do: to_solid_map(value)
  defp to_solid_value(value) when is_list(value), do: Enum.map(value, &to_solid_value/1)
  defp to_solid_value(value), do: value

  defp default_prompt(prompt) when is_binary(prompt) do
    if String.trim(prompt) == "" do
      Config.workflow_prompt()
    else
      prompt
    end
  end
end
