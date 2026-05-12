defmodule SymphonyElixir.Protocol.Validation do
  @moduledoc """
  Reads optional validation evidence and infers whether validation is required.
  """

  alias SymphonyElixir.Protocol.FinalizationGate

  @evidence_fields [:targeted_tests_run, :test_coverage_added, :validation_command]

  @spec summarize(Path.t(), [String.t()]) :: map()
  def summarize(workspace, changed_files), do: summarize(workspace, changed_files, [])

  @spec summarize(Path.t(), [String.t()], keyword()) :: map()
  def summarize(workspace, changed_files, opts) when is_binary(workspace) and is_list(changed_files) do
    lane = opts |> Keyword.get(:lane, infer_lane(changed_files)) |> to_string()
    artifact = validation_artifact(workspace)

    case read_validation_artifact(artifact) do
      {:ok, %{} = payload} ->
        payload
        |> evidence_fields()
        |> Map.merge(%{
          validation_required: validation_required?(lane, changed_files),
          validation_status: normalize_status(payload_value(payload, :status) || payload_value(payload, :validation_status)),
          validation_reason: payload_value(payload, :reason) || payload_value(payload, :validation_reason),
          validation_artifact_path: artifact
        })

      _ ->
        if validation_required?(lane, changed_files) do
          %{
            validation_required: true,
            validation_status: :not_run,
            validation_reason: "validation evidence missing for code-bearing change",
            validation_artifact_path: artifact
          }
        else
          %{
            validation_required: false,
            validation_status: :not_run,
            validation_reason: "docs-only/text-only change; full validation not requested",
            validation_artifact_path: artifact
          }
        end
    end
  end

  def summarize(_workspace, changed_files, opts) when is_list(changed_files) do
    lane = opts |> Keyword.get(:lane, infer_lane(changed_files)) |> to_string()

    %{
      validation_required: validation_required?(lane, changed_files),
      validation_status: :not_run,
      validation_reason: "validation evidence unavailable for remote workspace"
    }
  end

  @spec validation_required?(String.t(), [String.t()]) :: boolean()
  def validation_required?(lane, changed_files) do
    normalized_lane = lane |> to_string() |> String.downcase()
    FinalizationGate.code_bearing_changes?(changed_files) or (changed_files != [] and normalized_lane not in ["docs", "research"])
  end

  @spec infer_lane([String.t()]) :: String.t()
  def infer_lane(changed_files) do
    if changed_files != [] and !FinalizationGate.code_bearing_changes?(changed_files), do: "docs", else: "feature"
  end

  defp validation_artifact(workspace), do: Path.join([workspace, ".git", "symphony-validation.json"])

  defp evidence_fields(payload) do
    payload
    |> copy_evidence_fields(@evidence_fields)
    |> maybe_put_command_alias(payload)
  end

  defp copy_evidence_fields(payload, fields) do
    Enum.reduce(fields, %{}, fn field, acc ->
      case payload_value(payload, field) do
        nil -> acc
        value -> Map.put(acc, field, value)
      end
    end)
  end

  defp maybe_put_command_alias(%{validation_command: _command} = evidence, _payload), do: evidence

  defp maybe_put_command_alias(evidence, payload) do
    case payload_value(payload, :command) do
      nil -> evidence
      command -> Map.put(evidence, :validation_command, command)
    end
  end

  defp payload_value(payload, key) when is_map(payload) do
    string_key = to_string(key)

    cond do
      Map.has_key?(payload, string_key) -> Map.get(payload, string_key)
      Map.has_key?(payload, key) -> Map.get(payload, key)
      true -> nil
    end
  end

  defp read_validation_artifact(path) do
    with true <- File.regular?(path),
         {:ok, content} <- File.read(path),
         {:ok, payload} <- Jason.decode(content) do
      {:ok, payload}
    else
      _ -> :error
    end
  end

  defp normalize_status(status) when status in ["passed", :passed], do: :passed
  defp normalize_status(status) when status in ["failed", :failed], do: :failed
  defp normalize_status(status) when status in ["allowed_failure", :allowed_failure], do: :allowed_failure
  defp normalize_status(status) when status in ["not_run", :not_run], do: :not_run
  defp normalize_status(_status), do: :not_run
end
