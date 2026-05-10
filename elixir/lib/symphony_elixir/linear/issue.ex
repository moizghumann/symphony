defmodule SymphonyElixir.Linear.Issue do
  @moduledoc """
  Normalized Linear issue representation used by the orchestrator.
  """

  defstruct [
    :id,
    :identifier,
    :title,
    :description,
    :priority,
    :state,
    :state_id,
    :branch_name,
    :url,
    :project,
    :team,
    :available_states,
    :assignee_id,
    :lane_classification,
    :lane_policy,
    :job_packet,
    :orchestrator_lifecycle_events,
    blocked_by: [],
    labels: [],
    assigned_to_worker: true,
    created_at: nil,
    updated_at: nil
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          identifier: String.t() | nil,
          title: String.t() | nil,
          description: String.t() | nil,
          priority: integer() | nil,
          state: String.t() | nil,
          state_id: String.t() | nil,
          branch_name: String.t() | nil,
          url: String.t() | nil,
          project: map() | nil,
          team: map() | nil,
          available_states: [map()] | nil,
          assignee_id: String.t() | nil,
          lane_classification: map() | nil,
          lane_policy: map() | nil,
          job_packet: map() | nil,
          orchestrator_lifecycle_events: [map()] | nil,
          labels: [String.t()],
          assigned_to_worker: boolean(),
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @spec label_names(t()) :: [String.t()]
  def label_names(%__MODULE__{labels: labels}) do
    labels
  end
end
