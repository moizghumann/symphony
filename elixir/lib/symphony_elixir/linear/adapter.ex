defmodule SymphonyElixir.Linear.Adapter do
  @moduledoc """
  Linear-backed tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Linear.Client

  @create_comment_mutation """
  mutation SymphonyCreateComment($issueId: String!, $body: String!) {
    commentCreate(input: {issueId: $issueId, body: $body}) {
      success
    }
  }
  """

  @update_state_mutation """
  mutation SymphonyUpdateIssueState($issueId: String!, $stateId: String!) {
    issueUpdate(id: $issueId, input: {stateId: $stateId}) {
      success
    }
  }
  """

  @state_lookup_query """
  query SymphonyResolveStateId($issueId: String!, $stateName: String!) {
    issue(id: $issueId) {
      team {
        states(filter: {name: {eq: $stateName}}, first: 1) {
          nodes {
            id
          }
        }
      }
    }
  }
  """

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues, do: client_module().fetch_candidate_issues()

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids), do: client_module().fetch_issue_states_by_ids(issue_ids)

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    with {:ok, response} <- client_module().graphql(@create_comment_mutation, %{issueId: issue_id, body: body}),
         true <- get_in(response, ["data", "commentCreate", "success"]) == true do
      :ok
    else
      false -> {:error, :comment_create_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :comment_create_failed}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    update_issue_state_by_id(issue_id, state_name, nil)
  end

  @spec move_issue_to_state(term(), String.t()) :: :ok | {:error, term()}
  def move_issue_to_state(%Issue{id: issue_id} = issue, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    update_issue_state_by_id(issue_id, state_name, resolved_state_id_from_issue(issue, state_name))
  end

  def move_issue_to_state(issue_id, state_name) when is_binary(issue_id) and is_binary(state_name) do
    update_issue_state(issue_id, state_name)
  end

  @spec move_issue_to_blocked(term()) :: :ok | {:error, term()}
  def move_issue_to_blocked(issue_or_id), do: move_issue_to_state(issue_or_id, "Blocked")

  @spec post_handoff_comment(term(), String.t()) :: :ok | {:error, term()}
  def post_handoff_comment(%Issue{id: issue_id}, body) when is_binary(issue_id) and is_binary(body) do
    create_comment(issue_id, body)
  end

  def post_handoff_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    create_comment(issue_id, body)
  end

  defp client_module do
    Application.get_env(:symphony_elixir, :linear_client_module, Client)
  end

  defp update_issue_state_by_id(issue_id, state_name, preferred_state_id) do
    with {:ok, state_id} <- ensure_state_id(issue_id, state_name, preferred_state_id),
         {:ok, response} <-
           client_module().graphql(@update_state_mutation, %{issueId: issue_id, stateId: state_id}),
         true <- get_in(response, ["data", "issueUpdate", "success"]) == true do
      :ok
    else
      false -> {:error, :issue_update_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_update_failed}
    end
  end

  defp ensure_state_id(_issue_id, _state_name, state_id) when is_binary(state_id), do: {:ok, state_id}
  defp ensure_state_id(issue_id, state_name, _preferred_state_id), do: resolve_state_id(issue_id, state_name)

  defp resolved_state_id_from_issue(%Issue{available_states: states}, state_name) when is_list(states) do
    normalized_target = normalize_state_name(state_name)

    Enum.find_value(states, fn
      %{id: id, name: name} when is_binary(id) and is_binary(name) ->
        if normalize_state_name(name) == normalized_target, do: id

      %{"id" => id, "name" => name} when is_binary(id) and is_binary(name) ->
        if normalize_state_name(name) == normalized_target, do: id

      _ ->
        nil
    end)
  end

  defp resolved_state_id_from_issue(_issue, _state_name), do: nil

  defp normalize_state_name(state_name) when is_binary(state_name) do
    state_name |> String.trim() |> String.downcase()
  end

  defp resolve_state_id(issue_id, state_name) do
    with {:ok, response} <-
           client_module().graphql(@state_lookup_query, %{issueId: issue_id, stateName: state_name}),
         state_id when is_binary(state_id) <-
           get_in(response, ["data", "issue", "team", "states", "nodes", Access.at(0), "id"]) do
      {:ok, state_id}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :state_not_found}
    end
  end
end
