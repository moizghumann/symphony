defmodule SymphonyElixir.LanePolicy do
  @moduledoc """
  Data-driven lane policies for Linear issue orchestration.
  """

  @policy_version "2026-05-10.phase3"
  @lanes [:docs, :feature, :bug, :refactor, :test, :chore, :research]

  @default_policies %{
    docs: %{
      lane: :docs,
      max_turns: 3,
      target_effective_tokens: "10k-20k",
      effective_token_budget: 30_000,
      max_tool_calls: 12,
      validation_policy: "optional",
      pr_required: true,
      allowed_paths: ["AGENTS.md", "README.md", "WORKFLOW.md", "docs/**"],
      forbidden_paths: ["src/**", "public/**", "test/**", "tests/**", "schemas/**", "examples/**", "generated outputs", "dependency folders"],
      required: ["make the smallest documentation edit", "do not inspect source code unless the ticket explicitly requires it"],
      failure_behavior: "If the docs lane exceeds 30k effective tokens before a PR exists, stop and move the issue to Blocked.",
      handoff_requirements: ["commit and push repository changes", "draft PR required when files changed", "report `not run: docs-only change` unless validation was explicitly requested"]
    },
    bug: %{
      lane: :bug,
      max_turns: 6,
      target_effective_tokens: "40k-80k",
      effective_token_budget: 100_000,
      max_tool_calls: 35,
      validation_policy: "required",
      pr_required: true,
      allowed_paths: ["affected source path", "affected tests", "minimal config needed to reproduce"],
      forbidden_paths: ["unrelated source trees", "generated outputs", "dependency folders"],
      required: ["identify or reproduce the failure signal before changing code", "fix the smallest cause", "run a targeted test if available", "run npm run validate if behavior/runtime code changed"],
      failure_behavior: "If reproduction or validation cannot be completed, stop with a concise blocker.",
      handoff_requirements: ["include failure signal, fix summary, and validation evidence", "commit and push changes for draft PR"]
    },
    feature: %{
      lane: :feature,
      max_turns: 8,
      target_effective_tokens: "60k-120k",
      effective_token_budget: 150_000,
      max_tool_calls: 50,
      validation_policy: "required",
      pr_required: true,
      allowed_paths: ["relevant product surface", "relevant tests", "relevant docs"],
      forbidden_paths: ["unrelated source trees", "generated outputs", "dependency folders"],
      required: [
        "inspect relevant product surface",
        "inspect relevant tests/docs",
        "implement the smallest coherent version",
        "add or update tests when appropriate",
        "update docs if behavior changes",
        "run npm run validate"
      ],
      failure_behavior: "If implementation or validation cannot complete within budget, stop with a concise blocker.",
      handoff_requirements: ["include implementation summary and validation evidence", "commit and push changes for draft PR"]
    },
    refactor: %{
      lane: :refactor,
      max_turns: 8,
      target_effective_tokens: "60k-120k",
      effective_token_budget: 150_000,
      max_tool_calls: 50,
      validation_policy: "required",
      pr_required: true,
      allowed_paths: ["affected implementation", "tests proving preserved behavior"],
      forbidden_paths: ["unrelated behavior changes", "generated outputs", "dependency folders"],
      required: ["preserve behavior", "avoid unrelated changes", "inspect tests before changing", "run npm run validate", "document behavior-preservation evidence"],
      failure_behavior: "If behavior preservation cannot be demonstrated, stop with a concise blocker.",
      handoff_requirements: ["include behavior-preservation evidence and validation results", "commit and push changes for draft PR"]
    },
    test: %{
      lane: :test,
      max_turns: 6,
      target_effective_tokens: "40k-80k",
      effective_token_budget: 100_000,
      max_tool_calls: 35,
      validation_policy: "required",
      pr_required: true,
      allowed_paths: ["unit under test", "focused test files", "fixtures needed by those tests"],
      forbidden_paths: ["unrelated source trees", "generated outputs", "dependency folders"],
      required: ["inspect unit under test", "add focused tests", "run targeted tests", "run npm run validate if test infra or behavior changed"],
      failure_behavior: "If the target cannot be exercised, stop with a concise blocker.",
      handoff_requirements: ["include test focus and validation results", "commit and push changes for draft PR"]
    },
    chore: %{
      lane: :chore,
      max_turns: 5,
      target_effective_tokens: "30k-70k",
      effective_token_budget: 90_000,
      max_tool_calls: 30,
      validation_policy: "conditional",
      pr_required: true,
      allowed_paths: ["affected config", "affected scripts", "CI or dependency metadata"],
      forbidden_paths: ["unrelated product behavior", "generated outputs", "dependency folders unless explicitly updating dependencies"],
      required: ["inspect affected config/script only", "avoid behavior changes unless explicit", "run relevant validation", "run npm run validate if scripts/config affect build/test/runtime"],
      failure_behavior: "If maintenance validation cannot be completed, stop with a concise blocker.",
      handoff_requirements: ["include affected config/script and validation evidence", "commit and push changes for draft PR"]
    },
    research: %{
      lane: :research,
      max_turns: 4,
      target_effective_tokens: "20k-50k",
      effective_token_budget: 70_000,
      max_tool_calls: 25,
      validation_policy: "none",
      pr_required: false,
      allowed_paths: ["read-only issue-relevant files", "optional markdown report only if explicitly requested"],
      forbidden_paths: ["repo file edits unless explicitly requested", "branch/commit/PR unless a repo artifact is requested"],
      required: ["default to read-only investigation", "produce concise findings for Linear", "do not change files unless explicitly requested"],
      failure_behavior: "If findings cannot be completed, post a concise blocker.",
      handoff_requirements: ["post concise findings in Linear", "no PR unless repository files changed or a repo artifact was requested"]
    }
  }

  @spec policy_version() :: String.t()
  def policy_version, do: @policy_version

  @spec lanes() :: [atom()]
  def lanes, do: @lanes

  @spec lane?(atom() | String.t()) :: boolean()
  def lane?(lane) when is_atom(lane), do: lane in @lanes
  def lane?(lane) when is_binary(lane), do: normalize_lane(lane) in @lanes
  def lane?(_lane), do: false

  @spec normalize_lane(atom() | String.t()) :: atom() | nil
  def normalize_lane(lane) when is_atom(lane) do
    if lane?(lane), do: lane
  end

  def normalize_lane(lane) when is_binary(lane) do
    lane
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z]+/, "_")
    |> String.trim("_")
    |> case do
      "docs" -> :docs
      "documentation" -> :docs
      "feature" -> :feature
      "bug" -> :bug
      "fix" -> :bug
      "refactor" -> :refactor
      "test" -> :test
      "tests" -> :test
      "chore" -> :chore
      "research" -> :research
      "investigation" -> :research
      _ -> nil
    end
  end

  def normalize_lane(_lane), do: nil

  @spec default_policies() :: map()
  def default_policies do
    Map.new(@default_policies, fn {lane, policy} -> {lane, normalize_policy(policy)} end)
  end

  @spec policy_for(atom() | String.t(), map() | nil) :: map()
  def policy_for(lane, configured_lanes \\ nil) do
    lane = normalize_lane(lane) || :research
    configured = configured_policy(configured_lanes, lane)

    @default_policies
    |> Map.fetch!(lane)
    |> Map.merge(configured)
    |> Map.put(:lane, lane)
    |> Map.put(:policy_version, @policy_version)
    |> normalize_policy()
  end

  @spec policies(map() | nil) :: map()
  def policies(configured_lanes \\ nil) do
    Map.new(@lanes, fn lane -> {lane, policy_for(lane, configured_lanes)} end)
  end

  defp configured_policy(configured_lanes, lane) when is_map(configured_lanes) do
    Map.get(configured_lanes, Atom.to_string(lane)) ||
      Map.get(configured_lanes, lane) ||
      %{}
  end

  defp configured_policy(_configured_lanes, _lane), do: %{}

  defp normalize_policy(policy) when is_map(policy) do
    policy
    |> Map.new(fn {key, value} -> {normalize_key(key), value} end)
    |> normalize_integer(:max_turns)
    |> normalize_integer(:effective_token_budget)
    |> normalize_integer(:max_tool_calls)
    |> normalize_boolean(:pr_required)
    |> normalize_list(:allowed_paths)
    |> normalize_list(:forbidden_paths)
    |> normalize_list(:required)
    |> normalize_list(:handoff_requirements)
  end

  defp normalize_key(key) when is_atom(key), do: key

  defp normalize_key(key) when is_binary(key) do
    case String.trim(key) do
      "lane" -> :lane
      "max_turns" -> :max_turns
      "target_effective_tokens" -> :target_effective_tokens
      "effective_token_budget" -> :effective_token_budget
      "hard_effective_token_limit" -> :effective_token_budget
      "max_tool_calls" -> :max_tool_calls
      "validation" -> :validation_policy
      "validation_policy" -> :validation_policy
      "pr_required" -> :pr_required
      "allowed_paths" -> :allowed_paths
      "forbidden_paths" -> :forbidden_paths
      "required" -> :required
      "failure_behavior" -> :failure_behavior
      "handoff_requirements" -> :handoff_requirements
      other -> other
    end
  end

  defp normalize_integer(policy, key) do
    Map.update(policy, key, nil, fn
      value when is_integer(value) -> value
      value when is_binary(value) -> parse_positive_integer(value)
      _ -> nil
    end)
  end

  defp normalize_boolean(policy, key) do
    Map.update(policy, key, false, fn
      value when is_boolean(value) -> value
      value when is_binary(value) -> String.downcase(String.trim(value)) in ["true", "yes", "1"]
      _ -> false
    end)
  end

  defp normalize_list(policy, key) do
    Map.update(policy, key, [], fn
      value when is_list(value) -> Enum.map(value, &to_string/1)
      value when is_binary(value) -> [value]
      _ -> []
    end)
  end

  defp parse_positive_integer(value) do
    case Integer.parse(String.replace(value, "_", "")) do
      {integer, _} when integer > 0 -> integer
      _ -> nil
    end
  end
end
