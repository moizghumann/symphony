defmodule SymphonyElixir.Protocol.Contract do
  @moduledoc """
  Non-negotiable workflow semantics shared by prompt capsules and code gates.
  """

  alias SymphonyElixir.Config

  @default_allowed_states [
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

  @default_transitions %{
    "Todo" => ["In Progress"],
    "In Progress" => ["Human Review", "Blocked"],
    "Rework" => ["In Progress", "Human Review", "Blocked"],
    "Human Review" => ["Rework", "Merging"],
    "Merging" => ["Done", "Blocked"]
  }

  defstruct version: "1",
            repo_changes_require_pr: true,
            human_review_requires_pr: true,
            blocked_state: "Blocked",
            review_state: "Human Review",
            in_progress_state: "In Progress",
            done_state: "Done",
            canceled_state: "Canceled",
            duplicate_state: "Duplicate",
            allow_ticket_to_disable_pr: false,
            generic_linear_graphql_policy: "fallback_only",
            validation_gate: true,
            finalization_gate: true,
            allowed_states: @default_allowed_states,
            allowed_transitions: @default_transitions

  @type t :: %__MODULE__{}

  @spec current() :: t()
  def current do
    Config.settings!()
    |> Map.get(:protocol)
    |> from_config()
  end

  @spec from_config(term()) :: t()
  def from_config(nil), do: %__MODULE__{}

  def from_config(%{} = config) do
    base = %__MODULE__{}
    allow_ticket_to_disable_pr = boolean_value(config, :allow_ticket_to_disable_pr, base.allow_ticket_to_disable_pr)

    generic_linear_graphql_policy =
      string_value(config, :generic_linear_graphql_policy, base.generic_linear_graphql_policy)

    %__MODULE__{
      base
      | version: string_value(config, :version, base.version),
        repo_changes_require_pr: boolean_value(config, :repo_changes_require_pr, base.repo_changes_require_pr),
        human_review_requires_pr: boolean_value(config, :human_review_requires_pr, base.human_review_requires_pr),
        blocked_state: string_value(config, :blocked_state, base.blocked_state),
        review_state: string_value(config, :review_state, base.review_state),
        in_progress_state: string_value(config, :in_progress_state, base.in_progress_state),
        done_state: string_value(config, :done_state, base.done_state),
        canceled_state: string_value(config, :canceled_state, base.canceled_state),
        duplicate_state: string_value(config, :duplicate_state, base.duplicate_state),
        allow_ticket_to_disable_pr: allow_ticket_to_disable_pr,
        generic_linear_graphql_policy: generic_linear_graphql_policy,
        validation_gate: boolean_value(config, :validation_gate, base.validation_gate),
        finalization_gate: boolean_value(config, :finalization_gate, base.finalization_gate)
    }
  end

  def from_config(_config), do: %__MODULE__{}

  @spec allowed_states() :: [String.t()]
  def allowed_states, do: @default_allowed_states

  @spec allowed_transitions() :: map()
  def allowed_transitions, do: @default_transitions

  defp string_value(config, key, default) do
    case Map.get(config, key) do
      value when is_binary(value) and value != "" -> value
      value when is_atom(value) -> Atom.to_string(value)
      _ -> default
    end
  end

  defp boolean_value(config, key, default) do
    case Map.get(config, key) do
      value when is_boolean(value) -> value
      _ -> default
    end
  end
end
