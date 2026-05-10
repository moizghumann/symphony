defmodule SymphonyElixir.Protocol.StateTransitionGuard do
  @moduledoc """
  Validates workflow state existence and legal transitions before mutations.
  """

  alias SymphonyElixir.Protocol.{Contract, Violation}

  @spec validate(map(), String.t(), Contract.t()) :: [Violation.t()]
  def validate(run_state, target_state, %Contract{} = contract) when is_map(run_state) and is_binary(target_state) do
    available_states = available_state_names(Map.get(run_state, :available_states) || Map.get(run_state, "available_states"))
    current_state = Map.get(run_state, :current_state) || Map.get(run_state, "current_state")

    []
    |> maybe_state_not_found(target_state, available_states, contract)
    |> maybe_illegal_transition(current_state, target_state, contract)
  end

  def validate(_run_state, _target_state, _contract), do: []

  defp maybe_state_not_found(violations, target_state, [], %Contract{} = contract) do
    if target_state in contract.allowed_states do
      violations
    else
      [
        Violation.blocking(:state_not_found, "Target workflow state is not part of the protocol state set.",
          required_action: "Configure a valid workflow state before transitioning.",
          evidence: %{target_state: target_state, available_states: contract.allowed_states}
        )
        | violations
      ]
    end
  end

  defp maybe_state_not_found(violations, target_state, available_states, _contract) do
    if target_state in available_states do
      violations
    else
      [
        Violation.blocking(:state_not_found, "Target workflow state was not found on the Linear team.",
          required_action: "Move the issue to Blocked and report the missing state.",
          evidence: %{target_state: target_state, available_states: available_states}
        )
        | violations
      ]
    end
  end

  defp maybe_illegal_transition(violations, current_state, target_state, %Contract{} = contract)
       when is_binary(current_state) and is_binary(target_state) do
    cond do
      current_state == target_state ->
        violations

      target_state == contract.blocked_state ->
        violations

      target_state in [contract.canceled_state, contract.duplicate_state] ->
        violations

      target_state in Map.get(contract.allowed_transitions, current_state, []) ->
        violations

      true ->
        [
          Violation.blocking(:illegal_state_transition, "Workflow state transition is not legal.",
            required_action: "Use a valid workflow transition or move to Blocked with a blocker reason.",
            evidence: %{from: current_state, to: target_state, allowed: contract.allowed_transitions}
          )
          | violations
        ]
    end
  end

  defp maybe_illegal_transition(violations, _current_state, _target_state, _contract), do: violations

  defp available_state_names(states) when is_list(states) do
    states
    |> Enum.flat_map(fn
      %{name: name} when is_binary(name) -> [name]
      %{"name" => name} when is_binary(name) -> [name]
      name when is_binary(name) -> [name]
      _ -> []
    end)
    |> Enum.uniq()
  end

  defp available_state_names(_states), do: []
end
