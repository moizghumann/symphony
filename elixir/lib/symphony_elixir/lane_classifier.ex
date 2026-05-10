defmodule SymphonyElixir.LaneClassifier do
  @moduledoc """
  Deterministically classifies Linear issues into orchestration lanes.
  """

  alias SymphonyElixir.{LanePolicy, Linear.Issue}

  @signals [
    bug: ~w(fix bug broken error regression failure failing crash incorrect wrong),
    feature: ~w(add implement support new endpoint ui cli capability behavior),
    refactor: ["refactor", "cleanup architecture", "restructure", "reorganize"],
    test: ["test", "tests", "coverage", "fixture", "fixtures", "regression test"],
    docs: ["readme", "docs", "documentation", "copy", "agents.md", "workflow.md", "contributor"],
    research: ["investigate", "audit", "research", "plan", "compare", "feasibility", "architecture review", "recommendation"],
    chore: ["upgrade", "config", "script", "ci", "dependency", "dependencies", "formatting", "repo hygiene"]
  ]

  @spec classify(Issue.t()) :: map()
  def classify(%Issue{} = issue) do
    labels = Issue.label_names(issue)

    case explicit_label_lane(labels) do
      {lane, label} ->
        classification(lane, "explicit label `#{label}`", ["label:#{label}"], 1.0)

      nil ->
        classify_from_text(issue)
    end
  end

  def classify(_issue), do: classification(:research, "missing issue context; defaulted to research", [], 0.2)

  defp explicit_label_lane(labels) when is_list(labels) do
    Enum.find_value(labels, fn label ->
      with label when is_binary(label) <- label,
           lane when not is_nil(lane) <- LanePolicy.normalize_lane(label) do
        {lane, label}
      else
        _ -> nil
      end
    end)
  end

  defp explicit_label_lane(_labels), do: nil

  defp classify_from_text(%Issue{} = issue) do
    text = issue_text(issue)

    matches =
      @signals
      |> Enum.flat_map(fn {lane, signals} ->
        matched =
          signals
          |> Enum.filter(&signal_match?(text, &1))
          |> Enum.map(&"#{lane}:#{&1}")

        if matched == [], do: [], else: [{lane, matched}]
      end)

    cond do
      matches == [] ->
        classification(:research, "no deterministic lane signal matched; defaulted to research", [], 0.3)

      research_explicit?(text) ->
        {_lane, matched_signals} = Enum.find(matches, fn {lane, _signals} -> lane == :research end)
        classification(:research, "matched explicit read-only research signal", matched_signals, 0.9)

      match?([{_lane, _matched_signals}], matches) ->
        [{lane, matched_signals}] = matches
        classification(lane, "matched #{lane} signal", matched_signals, 0.8)

      true ->
        {lane, matched_signals} = least_expensive_safe_match(matches)
        other_lanes = matches |> Enum.map(&elem(&1, 0)) |> Enum.reject(&(&1 == lane)) |> Enum.uniq()

        classification(
          lane,
          "multiple lane signals matched; chose least expensive safe lane over #{Enum.join(Enum.map(other_lanes, &Atom.to_string/1), ", ")}",
          matched_signals,
          0.65
        )
    end
  end

  defp least_expensive_safe_match(matches) do
    Enum.min_by(matches, fn {lane, _signals} ->
      policy = LanePolicy.policy_for(lane)
      {policy.effective_token_budget || 999_999_999, policy.max_tool_calls || 999_999, Atom.to_string(lane)}
    end)
  end

  defp issue_text(%Issue{} = issue) do
    [
      issue.title,
      issue.description,
      section_text(issue.description, ["Goal", "Scope", "Out of scope", "Acceptance criteria", "Validation"]),
      label_text(issue.labels),
      project_text(issue.project),
      state_text(issue.state)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> String.downcase()
  end

  defp section_text(description, section_names) when is_binary(description) do
    Enum.map_join(section_names, "\n", fn section ->
      pattern = ~r/(?:^|\n)\s*#+\s*#{Regex.escape(section)}\s*\n(?<body>.*?)(?=\n\s*#+\s*[A-Za-z ]+\s*\n|\z)/is

      case Regex.named_captures(pattern, description) do
        %{"body" => body} -> body
        _ -> ""
      end
    end)
  end

  defp section_text(_description, _section_names), do: ""

  defp label_text(labels) when is_list(labels) do
    labels
    |> Enum.map(&project_value_text/1)
    |> Enum.join(" ")
  end

  defp label_text(_labels), do: ""

  defp project_text(project) when is_map(project) do
    project
    |> Map.values()
    |> Enum.map(&project_value_text/1)
    |> Enum.join(" ")
  end

  defp project_text(project) when is_binary(project), do: project
  defp project_text(_project), do: ""

  defp project_value_text(value) when is_binary(value), do: value
  defp project_value_text(value) when is_atom(value), do: Atom.to_string(value)
  defp project_value_text(value) when is_number(value), do: to_string(value)
  defp project_value_text(value), do: inspect(value)

  defp state_text(state) when is_binary(state), do: state
  defp state_text(_state), do: ""

  defp signal_match?(text, signal) when is_binary(text) and is_binary(signal) do
    normalized = String.downcase(signal)

    if String.contains?(normalized, " ") or String.contains?(normalized, ".") do
      String.contains?(text, normalized)
    else
      Regex.match?(~r/(^|[^a-z0-9])#{Regex.escape(normalized)}([^a-z0-9]|$)/, text)
    end
  end

  defp research_explicit?(text) when is_binary(text) do
    signal_match?(text, "investigate") and
      (String.contains?(text, "read-only") or String.contains?(text, "no code changes") or
         String.contains?(text, "post findings"))
  end

  defp classification(lane, reason, matched_signals, confidence) do
    %{
      lane: lane,
      confidence: confidence,
      reason: reason,
      matched_signals: matched_signals,
      policy_version: LanePolicy.policy_version()
    }
  end
end
