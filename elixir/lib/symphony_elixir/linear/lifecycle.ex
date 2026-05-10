defmodule SymphonyElixir.Linear.Lifecycle do
  @moduledoc """
  Narrow Linear lifecycle operations backed by resolved issue context.
  """

  alias SymphonyElixir.Linear.{Client, Issue}

  @allowed_states [
    "Todo",
    "In Progress",
    "Human Review",
    "Rework",
    "Merging",
    "Blocked",
    "Done",
    "Canceled",
    "Duplicate"
  ]

  @create_comment_mutation """
  mutation SymphonyCreateComment($issueId: String!, $body: String!) {
    commentCreate(input: {issueId: $issueId, body: $body}) {
      success
      comment {
        id
      }
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

  @spec allowed_states() :: [String.t()]
  def allowed_states, do: @allowed_states

  @spec resolve_issue_context(Issue.t()) :: map()
  def resolve_issue_context(%Issue{} = issue) do
    %{
      issue_id: issue.id,
      identifier: issue.identifier,
      title: issue.title,
      description: issue.description,
      url: issue.url,
      current_state: issue.state,
      project: issue.project,
      team: issue.team,
      state_ids: state_ids(issue),
      available_states: available_state_names(issue)
    }
  end

  @spec move_state(Issue.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def move_state(%Issue{} = issue, state_name, opts \\ []) when is_binary(state_name) do
    with {:ok, issue_id} <- require_issue_id(issue),
         {:ok, state_id} <- resolve_state_id(issue, state_name),
         {:ok, response} <- graphql(opts).(@update_state_mutation, %{issueId: issue_id, stateId: state_id}),
         true <- get_in(response, ["data", "issueUpdate", "success"]) == true do
      :ok
    else
      false -> {:error, :issue_update_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_update_failed}
    end
  end

  @spec move_state_by_id(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def move_state_by_id(issue_id, state_name, opts \\ [])
      when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, state_id} <- resolve_state_id_by_lookup(issue_id, state_name, opts),
         {:ok, response} <- graphql(opts).(@update_state_mutation, %{issueId: issue_id, stateId: state_id}),
         true <- get_in(response, ["data", "issueUpdate", "success"]) == true do
      :ok
    else
      false -> {:error, :issue_update_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_update_failed}
    end
  end

  @spec move_to_in_progress(Issue.t(), keyword()) :: :ok | {:error, term()}
  def move_to_in_progress(%Issue{} = issue, opts \\ []), do: move_state(issue, "In Progress", opts)

  @spec move_to_human_review(Issue.t(), keyword()) :: :ok | {:error, term()}
  def move_to_human_review(%Issue{} = issue, opts \\ []), do: move_state(issue, "Human Review", opts)

  @spec move_to_blocked(Issue.t(), keyword()) :: :ok | {:error, term()}
  def move_to_blocked(%Issue{} = issue, opts \\ []), do: move_state(issue, "Blocked", opts)

  @spec post_comment(Issue.t() | String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def post_comment(issue_or_id, body, opts \\ []) when is_binary(body) do
    with {:ok, issue_id} <- require_issue_id(issue_or_id),
         {:ok, response} <- graphql(opts).(@create_comment_mutation, %{issueId: issue_id, body: body}),
         true <- get_in(response, ["data", "commentCreate", "success"]) == true do
      {:ok, %{comment_id: get_in(response, ["data", "commentCreate", "comment", "id"])}}
    else
      false -> {:error, :comment_create_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :comment_create_failed}
    end
  end

  @spec post_handoff(Issue.t() | String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def post_handoff(issue_or_id, body, opts \\ []), do: post_comment(issue_or_id, body, opts)

  @spec post_blocker(Issue.t() | String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def post_blocker(issue_or_id, body, opts \\ []), do: post_comment(issue_or_id, body, opts)

  @spec attach_pr(Issue.t() | String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def attach_pr(issue_or_id, pr_url, opts \\ []) when is_binary(pr_url) do
    post_comment(issue_or_id, "Draft PR: #{String.trim(pr_url)}", opts)
  end

  defp graphql(opts) do
    Keyword.get(opts, :graphql, &Client.graphql/2)
  end

  defp require_issue_id(%Issue{id: issue_id}) when is_binary(issue_id) and issue_id != "", do: {:ok, issue_id}
  defp require_issue_id(issue_id) when is_binary(issue_id) and issue_id != "", do: {:ok, issue_id}
  defp require_issue_id(_issue_or_id), do: {:error, :missing_issue_id}

  defp resolve_state_id(%Issue{} = issue, state_name) do
    state_ids = state_ids(issue)
    normalized_requested = normalize_state_name(state_name)

    with true <- allowed_state?(normalized_requested),
         {_resolved_name, state_id} when is_binary(state_id) <-
           Enum.find(state_ids, fn {name, _id} -> normalize_state_name(name) == normalized_requested end) do
      {:ok, state_id}
    else
      _ ->
        {:error,
         %{
           code: "state_not_found",
           requested_state: state_name,
           available_states: available_state_names(issue)
         }}
    end
  end

  defp resolve_state_id_by_lookup(issue_id, state_name, opts) do
    with {:ok, response} <- graphql(opts).(@state_lookup_query, %{issueId: issue_id, stateName: state_name}),
         state_id when is_binary(state_id) <-
           get_in(response, ["data", "issue", "team", "states", "nodes", Access.at(0), "id"]) do
      {:ok, state_id}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :state_not_found}
    end
  end

  defp allowed_state?(normalized_state_name) do
    Enum.any?(@allowed_states, &(normalize_state_name(&1) == normalized_state_name))
  end

  defp state_ids(%Issue{available_states: states}) when is_list(states) do
    states
    |> Enum.flat_map(fn
      %{name: name, id: id} when is_binary(name) and is_binary(id) -> [{name, id}]
      %{"name" => name, "id" => id} when is_binary(name) and is_binary(id) -> [{name, id}]
      _ -> []
    end)
    |> Map.new()
  end

  defp state_ids(_issue), do: %{}

  defp available_state_names(%Issue{available_states: states}) when is_list(states) do
    states
    |> Enum.flat_map(fn
      %{name: name} when is_binary(name) -> [name]
      %{"name" => name} when is_binary(name) -> [name]
      _ -> []
    end)
  end

  defp available_state_names(_issue), do: []

  defp normalize_state_name(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end
end
