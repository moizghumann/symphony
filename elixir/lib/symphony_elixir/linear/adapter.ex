defmodule SymphonyElixir.Linear.Adapter do
  @moduledoc """
  Linear-backed tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Linear.{Client, Issue, Lifecycle}

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues, do: client_module().fetch_candidate_issues()

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids), do: client_module().fetch_issue_states_by_ids(issue_ids)

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    issue_id
    |> Lifecycle.post_comment(body, graphql: graphql_fun())
    |> ok_result()
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    Lifecycle.move_state_by_id(issue_id, state_name, graphql: graphql_fun())
  end

  @spec move_issue_to_state(term(), String.t()) :: :ok | {:error, term()}
  def move_issue_to_state(%Issue{id: issue_id} = issue, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    Lifecycle.move_state(issue, state_name, graphql: graphql_fun())
  end

  def move_issue_to_state(issue_id, state_name) when is_binary(issue_id) and is_binary(state_name) do
    update_issue_state(issue_id, state_name)
  end

  @spec move_issue_to_blocked(term()) :: :ok | {:error, term()}
  def move_issue_to_blocked(%Issue{} = issue), do: Lifecycle.move_to_blocked(issue, graphql: graphql_fun())
  def move_issue_to_blocked(issue_id), do: move_issue_to_state(issue_id, "Blocked")

  @spec post_handoff_comment(term(), String.t()) :: :ok | {:error, term()}
  def post_handoff_comment(%Issue{id: issue_id}, body) when is_binary(issue_id) and is_binary(body) do
    issue_id
    |> Lifecycle.post_handoff(body, graphql: graphql_fun())
    |> ok_result()
  end

  def post_handoff_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    create_comment(issue_id, body)
  end

  defp client_module do
    Application.get_env(:symphony_elixir, :linear_client_module, Client)
  end

  defp graphql_fun do
    module = client_module()
    &module.graphql/2
  end

  defp ok_result({:ok, _payload}), do: :ok
  defp ok_result({:error, reason}), do: {:error, reason}
end
