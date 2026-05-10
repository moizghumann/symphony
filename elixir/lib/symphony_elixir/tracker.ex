defmodule SymphonyElixir.Tracker do
  @moduledoc """
  Adapter boundary for issue tracker reads and writes.
  """

  alias SymphonyElixir.Config

  @callback fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  @callback update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  @callback move_issue_to_state(term(), String.t()) :: :ok | {:error, term()}
  @callback move_issue_to_blocked(term()) :: :ok | {:error, term()}
  @callback post_handoff_comment(term(), String.t()) :: :ok | {:error, term()}
  @callback post_handoff_comment_result(term(), String.t()) :: {:ok, map()} | {:error, term()}

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues do
    adapter().fetch_candidate_issues()
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states) do
    adapter().fetch_issues_by_states(states)
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    adapter().fetch_issue_states_by_ids(issue_ids)
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) do
    adapter().create_comment(issue_id, body)
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) do
    adapter().update_issue_state(issue_id, state_name)
  end

  @spec move_issue_to_state(term(), String.t()) :: :ok | {:error, term()}
  def move_issue_to_state(issue_or_id, state_name) do
    adapter().move_issue_to_state(issue_or_id, state_name)
  end

  @spec move_issue_to_blocked(term()) :: :ok | {:error, term()}
  def move_issue_to_blocked(issue_or_id) do
    adapter().move_issue_to_blocked(issue_or_id)
  end

  @spec post_handoff_comment(term(), String.t()) :: :ok | {:error, term()}
  def post_handoff_comment(issue_or_id, body) do
    adapter().post_handoff_comment(issue_or_id, body)
  end

  @spec post_handoff_comment_result(term(), String.t()) :: {:ok, map()} | {:error, term()}
  def post_handoff_comment_result(issue_or_id, body) do
    adapter().post_handoff_comment_result(issue_or_id, body)
  end

  @spec adapter() :: module()
  def adapter do
    case Config.settings!().tracker.kind do
      "memory" -> SymphonyElixir.Tracker.Memory
      _ -> SymphonyElixir.Linear.Adapter
    end
  end
end
