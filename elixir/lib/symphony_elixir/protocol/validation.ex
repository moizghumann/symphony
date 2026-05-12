defmodule SymphonyElixir.Protocol.Validation do
  @moduledoc """
  Reads optional validation evidence and infers whether validation is required.
  """

  alias SymphonyElixir.Protocol.FinalizationGate

  @spec summarize(Path.t(), [String.t()]) :: map()
  def summarize(workspace, changed_files), do: summarize(workspace, changed_files, [])

  @spec summarize(Path.t(), [String.t()], keyword()) :: map()
  def summarize(workspace, changed_files, opts) when is_binary(workspace) and is_list(changed_files) do
    lane = opts |> Keyword.get(:lane, infer_lane(changed_files)) |> to_string()
    artifact = validation_artifact(workspace)

    case read_validation_artifact(artifact) do
      {:ok, %{} = payload} ->
        payload
        |> artifact_summary(lane, changed_files, artifact)
        |> put_artifact_evidence(payload, "targeted_tests_run", :targeted_tests_run)
        |> put_artifact_evidence(payload, "test_coverage_added", :test_coverage_added)

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

  defp artifact_summary(payload, lane, changed_files, artifact) do
    %{
      validation_required: validation_required?(lane, changed_files),
      validation_status: validation_status(payload),
      validation_reason: validation_reason(payload),
      validation_artifact_path: artifact
    }
    |> put_validation_command(payload)
  end

  defp validation_status(payload) do
    status =
      payload_value(payload, "status", :status) ||
        payload_value(payload, "validation_status", :validation_status)

    normalize_status(status)
  end

  defp validation_reason(payload) do
    payload_value(payload, "reason", :reason) ||
      payload_value(payload, "validation_reason", :validation_reason)
  end

  defp put_validation_command(summary, payload) do
    case payload_value(payload, "validation_command", :validation_command) || payload_value(payload, "command", :command) do
      nil -> summary
      command -> Map.put(summary, :validation_command, command)
    end
  end

  defp put_artifact_evidence(summary, payload, string_key, atom_key) do
    case payload_fetch(payload, string_key, atom_key) do
      {:ok, value} -> Map.put(summary, atom_key, normalize_evidence_value(value))
      :error -> summary
    end
  end

  defp payload_value(payload, string_key, atom_key) do
    case payload_fetch(payload, string_key, atom_key) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  defp payload_fetch(payload, string_key, atom_key) do
    case Map.fetch(payload, string_key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(payload, atom_key)
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

  defp normalize_evidence_value("true"), do: true
  defp normalize_evidence_value("false"), do: false
  defp normalize_evidence_value(value), do: value
end
