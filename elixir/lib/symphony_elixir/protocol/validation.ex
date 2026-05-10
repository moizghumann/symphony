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
        %{
          validation_required: validation_required?(lane, changed_files),
          validation_status: normalize_status(Map.get(payload, "status") || Map.get(payload, :status)),
          validation_reason: Map.get(payload, "reason") || Map.get(payload, :reason),
          validation_artifact_path: artifact
        }

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
