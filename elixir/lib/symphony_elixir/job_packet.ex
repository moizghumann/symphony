defmodule SymphonyElixir.JobPacket do
  @moduledoc """
  Compiles lane-specific Codex job packets.
  """

  alias SymphonyElixir.{LaneClassifier, LanePolicy, Linear.Issue}

  @spec compile(Issue.t(), map() | nil) :: map()
  def compile(%Issue{} = issue, configured_lanes \\ nil) do
    classification = issue.lane_classification || LaneClassifier.classify(issue)
    policy = issue.lane_policy || LanePolicy.policy_for(classification.lane, configured_lanes)

    %{
      issue: issue_context(issue),
      lane: Atom.to_string(classification.lane),
      classification_reason: classification.reason,
      matched_signals: classification.matched_signals,
      policy_version: classification.policy_version,
      allowed_files_directories: policy.allowed_paths,
      forbidden_files_directories: policy.forbidden_paths,
      validation_policy: policy.validation_policy,
      pr_policy: pr_policy(policy),
      token_budget: %{
        target_effective_tokens: policy.target_effective_tokens,
        hard_effective_token_limit: policy.effective_token_budget
      },
      turn_budget: policy.max_turns,
      tool_call_budget: policy.max_tool_calls,
      required: policy.required,
      failure_behavior: policy.failure_behavior,
      handoff_requirements: policy.handoff_requirements,
      available_narrow_linear_tools: [
        "move issue to In Progress",
        "move issue to Human Review",
        "move issue to Blocked",
        "post handoff comment",
        "post blocker comment",
        "attach or record PR URL"
      ],
      available_github_pr_flow: "Codex commits and pushes. Symphony creates `gh pr create --draft --head <branch> --base main` after `SYMPHONY_HANDOFF_READY`."
    }
  end

  @spec render_prompt(map()) :: String.t()
  def render_prompt(packet) when is_map(packet) do
    """
    Symphony lane-specific job packet:

    ```json
    #{Jason.encode!(packet, pretty: true)}
    ```

    Lane constraints:

    - Work only inside the allowed context unless the ticket explicitly requires otherwise.
    - Treat forbidden context as off-limits by default.
    - Respect validation and PR policy from the packet.
    - Keep tool use within the tool-call budget. Generic `linear_graphql` is fallback/debug only and abnormal.
    - At 80% of the effective token budget, compress your working context and finish only if still likely.
    - If the hard effective token or tool-call budget is exceeded, stop optional investigation and report a concise blocker.
    - For research lane, stay read-only unless the ticket explicitly asks for repository changes.
    - When repository work is complete, committed, pushed, and validated, include `SYMPHONY_HANDOFF_READY`.
    """
  end

  defp issue_context(%Issue{} = issue) do
    issue
    |> Map.from_struct()
    |> Map.take([:id, :identifier, :title, :description, :url, :state, :project, :team, :labels, :priority, :blocked_by])
    |> to_packet_value()
  end

  defp pr_policy(%{pr_required: true}), do: "required if repository files changed"
  defp pr_policy(%{lane: :research}), do: "not required unless a repository artifact is created or changed"
  defp pr_policy(_policy), do: "not required unless repository files changed"

  defp to_packet_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_packet_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp to_packet_value(%Date{} = value), do: Date.to_iso8601(value)
  defp to_packet_value(%Time{} = value), do: Time.to_iso8601(value)
  defp to_packet_value(%_{} = value), do: inspect(value)
  defp to_packet_value(value) when is_map(value), do: Map.new(value, fn {key, nested} -> {key, to_packet_value(nested)} end)
  defp to_packet_value(value) when is_list(value), do: Enum.map(value, &to_packet_value/1)
  defp to_packet_value(value), do: value
end
