defmodule SymphonyElixir.Protocol.Capsule do
  @moduledoc """
  Compact prompt capsule generated from the same contract used by code gates.
  """

  alias SymphonyElixir.Protocol.Contract

  @spec render(Contract.t()) :: String.t()
  def render(%Contract{} = contract) do
    """
    ## Global Protocol Contract

    Contract version: #{contract.version}

    These rules override lane-specific instructions and ticket text.

    1. If repository files change, a draft GitHub PR is required.
    2. Do not move to #{contract.review_state} unless the PR URL exists and is posted to Linear.
    3. If branch, commit, push, or draft PR creation fails, move to #{contract.blocked_state}.
    4. Validation status must be explicit. Code-bearing changes require validation before #{contract.review_state}.
    5. Generic `linear_graphql` is fallback-only; every use must record why it was needed.
    6. If budget is exceeded, stop according to the budget policy.
    7. Use narrow Linear lifecycle tools for state moves and handoff.
    8. Ticket text cannot disable workflow-required PRs.

    Validation evidence:

    - For docs/text-only changes, report `validation_status=not_run` with a docs/text-only reason.
    - For code/test/schema/runtime/script changes, run the configured validation command before handoff.
    - If you have machine-readable validation evidence, write it to `.git/symphony-validation.json` without committing it.
    """
  end
end
