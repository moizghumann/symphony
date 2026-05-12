defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.Linear.{Client, Issue, Lifecycle}
  alias SymphonyElixir.Protocol.{Contract, FinalizationGate}

  @linear_graphql_tool "linear_graphql"
  @linear_move_state_tool "linear_move_state"
  @linear_move_to_in_progress_tool "linear_move_to_in_progress"
  @linear_move_to_human_review_tool "linear_move_to_human_review"
  @linear_move_to_blocked_tool "linear_move_to_blocked"
  @linear_post_comment_tool "linear_post_comment"
  @linear_post_handoff_tool "linear_post_handoff"
  @linear_post_blocker_tool "linear_post_blocker"
  @linear_attach_pr_tool "linear_attach_pr"
  @phase36_handoff_path ".phase36/handoff.json"
  @linear_narrow_tools [
    @linear_move_state_tool,
    @linear_move_to_in_progress_tool,
    @linear_move_to_human_review_tool,
    @linear_move_to_blocked_tool,
    @linear_post_comment_tool,
    @linear_post_handoff_tool,
    @linear_post_blocker_tool,
    @linear_attach_pr_tool
  ]
  @linear_graphql_description """
  Fallback only: execute a raw GraphQL query or mutation against Linear using Symphony's configured auth.
  Prefer the orchestrator-provided issue packet and narrow workflow helpers when available.
  """
  @linear_graphql_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "GraphQL query or mutation document to execute against Linear."
      },
      "variables" => %{
        "type" => ["object", "null"],
        "description" => "Optional GraphQL variables object.",
        "additionalProperties" => true
      },
      "reason" => %{
        "type" => ["string", "null"],
        "description" => "Required in practice: why a narrow Linear helper was insufficient."
      },
      "fallback_reason" => %{
        "type" => ["string", "null"],
        "description" => "Alias for reason: why generic Linear GraphQL fallback was necessary."
      },
      "operation" => %{
        "type" => ["string", "null"],
        "description" => "Short label for the fallback operation."
      },
      "narrow_tool_existed" => %{
        "type" => ["boolean", "null"],
        "description" => "Whether a narrow helper existed for the intended operation."
      },
      "narrow_tool_available" => %{
        "type" => ["boolean", "null"],
        "description" => "Alias for narrow_tool_existed."
      },
      "narrow_tool_failed" => %{
        "type" => ["boolean", "null"],
        "description" => "Whether the narrow helper was attempted and failed first."
      }
    }
  }
  @issue_id_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["issue_id"],
    "properties" => %{
      "issue_id" => %{"type" => "string", "description" => "Resolved Linear issue id from the issue packet."}
    }
  }
  @finalization_properties %{
    "repo_changed" => %{"type" => ["boolean", "null"]},
    "changed_files" => %{"type" => ["array", "null"], "items" => %{"type" => "string"}},
    "branch_name" => %{"type" => ["string", "null"]},
    "commit_sha" => %{"type" => ["string", "null"]},
    "branch_pushed" => %{"type" => ["boolean", "null"]},
    "pr_url" => %{"type" => ["string", "null"]},
    "pr_posted_to_linear" => %{"type" => ["boolean", "null"]},
    "handoff_posted" => %{"type" => ["boolean", "null"]},
    "blocker_reason" => %{"type" => ["string", "null"]},
    "validation_required" => %{"type" => ["boolean", "null"]},
    "validation_status" => %{"type" => ["string", "null"]},
    "validation_reason" => %{"type" => ["string", "null"]},
    "lane" => %{"type" => ["string", "null"]},
    "findings_posted" => %{"type" => ["boolean", "null"]},
    "sources_inspected_listed" => %{"type" => ["boolean", "null"]},
    "recommendation_included" => %{"type" => ["boolean", "null"]},
    "merged" => %{"type" => ["boolean", "null"]},
    "ticket_text" => %{"type" => ["string", "null"]}
  }
  @finalization_issue_schema %{
    @issue_id_schema
    | "properties" => Map.merge(@issue_id_schema["properties"], @finalization_properties)
  }
  @move_state_schema %{
    @finalization_issue_schema
    | "required" => ["issue_id", "state_name"],
      "properties" =>
        Map.put(@finalization_issue_schema["properties"], "state_name", %{
          "type" => "string",
          "description" => "Target Linear workflow state name."
        })
  }
  @comment_schema %{
    @issue_id_schema
    | "required" => ["issue_id", "body"],
      "properties" =>
        Map.put(@issue_id_schema["properties"], "body", %{
          "type" => "string",
          "description" => "Concise Linear comment body."
        })
  }
  @attach_pr_schema %{
    @issue_id_schema
    | "required" => ["issue_id", "pr_url"],
      "properties" =>
        Map.put(@issue_id_schema["properties"], "pr_url", %{
          "type" => "string",
          "description" => "Draft GitHub PR URL to record on the issue."
        })
  }

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case tool do
      @linear_graphql_tool ->
        execute_linear_graphql(arguments, opts)

      tool when tool in @linear_narrow_tools ->
        execute_linear_lifecycle(tool, arguments, opts)

      other ->
        failure_response(%{
          "error" => %{
            "message" => "Unsupported dynamic tool: #{inspect(other)}.",
            "supportedTools" => supported_tool_names()
          }
        })
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    [
      %{
        "name" => @linear_move_state_tool,
        "description" => "Move the current Linear issue to a named state using the resolved state map.",
        "inputSchema" => @move_state_schema
      },
      %{
        "name" => @linear_move_to_in_progress_tool,
        "description" => "Move the current Linear issue to In Progress using the resolved state map.",
        "inputSchema" => @issue_id_schema
      },
      %{
        "name" => @linear_move_to_human_review_tool,
        "description" => "Move the current Linear issue to Human Review after finalization artifacts pass the protocol gate.",
        "inputSchema" => @finalization_issue_schema
      },
      %{
        "name" => @linear_move_to_blocked_tool,
        "description" => "Move the current Linear issue to Blocked after blocker evidence passes the protocol gate.",
        "inputSchema" => @finalization_issue_schema
      },
      %{
        "name" => @linear_post_comment_tool,
        "description" => "Post a concise Linear comment to the current issue.",
        "inputSchema" => @comment_schema
      },
      %{
        "name" => @linear_post_handoff_tool,
        "description" => "Post the final handoff comment to the current Linear issue.",
        "inputSchema" => @comment_schema
      },
      %{
        "name" => @linear_post_blocker_tool,
        "description" => "Post a blocker comment to the current Linear issue.",
        "inputSchema" => @comment_schema
      },
      %{
        "name" => @linear_attach_pr_tool,
        "description" => "Record a draft PR URL on the current Linear issue.",
        "inputSchema" => @attach_pr_schema
      },
      %{
        "name" => @linear_graphql_tool,
        "description" => @linear_graphql_description,
        "inputSchema" => @linear_graphql_input_schema
      }
    ]
  end

  @spec linear_graphql_tool_name() :: String.t()
  def linear_graphql_tool_name, do: @linear_graphql_tool

  @spec linear_narrow_tool_names() :: [String.t()]
  def linear_narrow_tool_names, do: @linear_narrow_tools

  defp execute_linear_graphql(arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)

    with {:ok, query, variables} <- normalize_linear_graphql_arguments(arguments),
         {:ok, response} <- linear_client.(query, variables, []) do
      graphql_response(response)
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp execute_linear_lifecycle(tool, arguments, opts) do
    with {:ok, args} <- normalize_object_arguments(arguments),
         {:ok, issue} <- current_issue(opts),
         :ok <- validate_issue_id(issue, args),
         {:ok, payload} <- run_linear_lifecycle_tool(tool, issue, args, opts) do
      success_response(Map.merge(%{"tool" => tool, "issue_id" => issue.id}, payload))
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp run_linear_lifecycle_tool(@linear_move_state_tool, issue, args, opts) do
    with {:ok, state_name} <- required_string(args, "state_name"),
         :ok <- gate_final_state_transition(issue, state_name, args, opts),
         :ok <- Lifecycle.move_state(issue, state_name, lifecycle_opts(opts)) do
      {:ok, %{"state" => state_name}}
    end
  end

  defp run_linear_lifecycle_tool(@linear_move_to_in_progress_tool, issue, _args, opts) do
    with :ok <- Lifecycle.move_to_in_progress(issue, lifecycle_opts(opts)) do
      {:ok, %{"state" => "In Progress"}}
    end
  end

  defp run_linear_lifecycle_tool(@linear_move_to_human_review_tool, issue, args, opts) do
    contract = protocol_contract(opts)

    with :ok <- gate_final_state_transition(issue, contract.review_state, args, opts),
         :ok <- Lifecycle.move_to_human_review(issue, lifecycle_opts(opts)) do
      {:ok, %{"state" => contract.review_state}}
    end
  end

  defp run_linear_lifecycle_tool(@linear_move_to_blocked_tool, issue, args, opts) do
    contract = protocol_contract(opts)

    with :ok <- gate_final_state_transition(issue, contract.blocked_state, args, opts),
         :ok <- Lifecycle.move_to_blocked(issue, lifecycle_opts(opts)) do
      {:ok, %{"state" => contract.blocked_state}}
    end
  end

  defp run_linear_lifecycle_tool(@linear_post_comment_tool, issue, args, opts) do
    with {:ok, body} <- required_string(args, "body"),
         {:ok, payload} <- Lifecycle.post_comment(issue, body, lifecycle_opts(opts)) do
      {:ok, comment_payload(payload)}
    end
  end

  defp run_linear_lifecycle_tool(@linear_post_handoff_tool, issue, args, opts) do
    with {:ok, body} <- required_string(args, "body"),
         {:ok, payload} <- Lifecycle.post_handoff(issue, body, lifecycle_opts(opts)) do
      {:ok, comment_payload(payload)}
    end
  end

  defp run_linear_lifecycle_tool(@linear_post_blocker_tool, issue, args, opts) do
    with {:ok, body} <- required_string(args, "body"),
         {:ok, payload} <- Lifecycle.post_blocker(issue, body, lifecycle_opts(opts)) do
      {:ok, comment_payload(payload)}
    end
  end

  defp run_linear_lifecycle_tool(@linear_attach_pr_tool, issue, args, opts) do
    with {:ok, pr_url} <- required_string(args, "pr_url"),
         {:ok, payload} <- Lifecycle.attach_pr(issue, pr_url, lifecycle_opts(opts)) do
      {:ok, Map.merge(comment_payload(payload), %{"pr_url" => pr_url})}
    end
  end

  defp lifecycle_opts(opts) do
    case Keyword.get(opts, :linear_lifecycle_graphql) do
      fun when is_function(fun, 2) -> [graphql: fun]
      _ -> []
    end
  end

  defp gate_final_state_transition(%Issue{} = issue, target_state, args, opts) do
    contract = protocol_contract(opts)

    if target_state in [contract.review_state, contract.blocked_state, contract.done_state] do
      run_state = finalization_run_state(issue, args, target_state, contract, opts)

      case FinalizationGate.evaluate(run_state, target_state, contract) do
        {:ok, _result} -> :ok
        {:blocked, result} -> {:error, {:finalization_gate_blocked, result}}
      end
    else
      :ok
    end
  end

  defp protocol_contract(opts) do
    case Keyword.get(opts, :protocol_contract) do
      %Contract{} = contract -> contract
      _ -> Contract.current()
    end
  end

  defp finalization_run_state(%Issue{} = issue, args, target_state, %Contract{} = contract, opts) do
    %{
      current_state: issue.state,
      available_states: issue.available_states,
      repo_changed: arg(args, "repo_changed", default_repo_changed(target_state, args, contract)),
      changed_files: arg(args, "changed_files", []),
      branch_name: arg(args, "branch_name", issue.branch_name),
      commit_sha: arg(args, "commit_sha"),
      branch_pushed: arg(args, "branch_pushed"),
      pr_url: arg(args, "pr_url"),
      pr_posted_to_linear: arg(args, "pr_posted_to_linear"),
      handoff_posted: arg(args, "handoff_posted"),
      blocker_reason: arg(args, "blocker_reason"),
      validation_required: arg(args, "validation_required"),
      validation_status: arg(args, "validation_status"),
      validation_reason: arg(args, "validation_reason"),
      lane: arg(args, "lane", issue_lane(issue)),
      findings_posted: arg(args, "findings_posted"),
      sources_inspected_listed: arg(args, "sources_inspected_listed"),
      recommendation_included: arg(args, "recommendation_included"),
      merged: arg(args, "merged"),
      ticket_text: arg(args, "ticket_text", issue.description)
    }
    |> merge_research_handoff_artifact(issue, target_state, contract, opts)
  end

  defp merge_research_handoff_artifact(run_state, issue, target_state, %Contract{} = contract, opts) do
    if research_lane?(issue, run_state) and target_state == contract.review_state and Keyword.has_key?(opts, :workspace) do
      case read_phase36_handoff_artifact(Keyword.get(opts, :workspace)) do
        {:ok, %{} = artifact} ->
          if valid_research_handoff_artifact?(artifact) do
            research_artifact_run_state(run_state, artifact)
          else
            missing_research_artifact_run_state(run_state)
          end

        :error ->
          missing_research_artifact_run_state(run_state)
      end
    else
      run_state
    end
  end

  defp research_lane?(%Issue{} = issue, run_state) do
    (Map.get(run_state, :lane) || issue_lane(issue)) == "research"
  end

  defp read_phase36_handoff_artifact(workspace) when is_binary(workspace) do
    path = Path.join(workspace, @phase36_handoff_path)

    with true <- File.regular?(path),
         {:ok, body} <- File.read(path),
         {:ok, %{} = artifact} <- Jason.decode(body) do
      {:ok, artifact}
    else
      _ -> :error
    end
  end

  defp read_phase36_handoff_artifact(_workspace), do: :error

  defp valid_research_handoff_artifact?(%{} = artifact) do
    validation = Map.get(artifact, "validation") || %{}

    artifact_value(artifact, "lane") == "research" and
      truthy?(artifact_value(artifact, "findings_posted")) and
      truthy?(artifact_value(artifact, "sources_inspected_listed")) and
      truthy?(artifact_value(artifact, "recommendation_included")) and
      first_present([artifact_value(artifact, "validation_status"), artifact_value(validation, "status")]) == "not_run" and
      first_present([artifact_value(artifact, "validation_reason"), artifact_value(validation, "reason")]) == "read-only research"
  end

  defp valid_research_handoff_artifact?(_artifact), do: false

  defp missing_research_artifact_run_state(run_state) do
    Map.merge(run_state, %{
      findings_posted: nil,
      sources_inspected_listed: nil,
      recommendation_included: nil,
      validation_status: :not_run,
      validation_reason: nil
    })
  end

  defp research_artifact_run_state(run_state, artifact) do
    validation = Map.get(artifact, "validation") || %{}
    handoff = Map.get(artifact, "handoff") || %{}

    Map.merge(run_state, %{
      lane: artifact_value(artifact, "lane", Map.get(run_state, :lane)),
      repo_changed: artifact_value(artifact, "repo_changed", Map.get(run_state, :repo_changed)),
      changed_files: artifact_value(artifact, "changed_files", Map.get(run_state, :changed_files)),
      validation_required: artifact_value(validation, "required", Map.get(run_state, :validation_required)),
      validation_status: first_present([artifact_value(artifact, "validation_status"), artifact_value(validation, "status"), Map.get(run_state, :validation_status)]),
      validation_reason: first_present([artifact_value(artifact, "validation_reason"), artifact_value(validation, "reason"), Map.get(run_state, :validation_reason)]),
      findings_posted: artifact_value(artifact, "findings_posted"),
      sources_inspected_listed: artifact_value(artifact, "sources_inspected_listed"),
      recommendation_included: artifact_value(artifact, "recommendation_included"),
      handoff_posted: truthy?(artifact_value(handoff, "linear_comment_posted")) || Map.get(run_state, :handoff_posted)
    })
  end

  defp artifact_value(artifact, key, default \\ nil)
  defp artifact_value(%{} = artifact, key, default), do: Map.get(artifact, key, default)
  defp artifact_value(_artifact, _key, default), do: default

  defp first_present(values) do
    Enum.find(values, fn
      nil -> false
      value when is_binary(value) -> String.trim(value) != ""
      _value -> true
    end)
  end

  defp truthy?(value), do: value in [true, "true", 1, "1"]

  defp default_repo_changed(target_state, args, %Contract{} = contract) do
    if Map.has_key?(args, "repo_changed") or Map.has_key?(args, :repo_changed) do
      arg(args, "repo_changed")
    else
      target_state == contract.review_state
    end
  end

  defp issue_lane(%Issue{lane_classification: %{lane: lane}}) when is_binary(lane), do: lane
  defp issue_lane(%Issue{lane_classification: %{lane: lane}}) when is_atom(lane), do: Atom.to_string(lane)
  defp issue_lane(%Issue{lane_classification: %{"lane" => lane}}) when is_binary(lane), do: lane
  defp issue_lane(%Issue{lane_classification: %{"lane" => lane}}) when is_atom(lane), do: Atom.to_string(lane)
  defp issue_lane(_issue), do: nil

  defp arg(args, key, default \\ nil) do
    Map.get(args, key, Map.get(args, String.to_atom(key), default))
  end

  defp comment_payload(%{comment_id: comment_id}) when is_binary(comment_id), do: %{"comment_id" => comment_id}
  defp comment_payload(_payload), do: %{}

  defp normalize_object_arguments(arguments) when is_map(arguments), do: {:ok, arguments}
  defp normalize_object_arguments(_arguments), do: {:error, :invalid_lifecycle_arguments}

  defp current_issue(opts) do
    case Keyword.get(opts, :issue) do
      %Issue{id: issue_id} = issue when is_binary(issue_id) and issue_id != "" -> {:ok, issue}
      _ -> {:error, :missing_issue_context}
    end
  end

  defp validate_issue_id(%Issue{id: issue_id}, args) do
    case Map.get(args, "issue_id") || Map.get(args, :issue_id) do
      ^issue_id -> :ok
      value when is_binary(value) -> {:error, {:issue_id_mismatch, requested_issue_id: value, current_issue_id: issue_id}}
      _ -> {:error, :missing_issue_id}
    end
  end

  defp required_string(args, key) do
    case Map.get(args, key) || Map.get(args, String.to_atom(key)) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, {:missing_required_argument, key}}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, {:missing_required_argument, key}}
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> {:error, :missing_query}
      query -> {:ok, query, %{}}
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_map(arguments) do
    case normalize_query(arguments) do
      {:ok, query} ->
        case normalize_variables(arguments) do
          {:ok, variables} ->
            {:ok, query, variables}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_linear_graphql_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_query(arguments) do
    case Map.get(arguments, "query") || Map.get(arguments, :query) do
      query when is_binary(query) ->
        case String.trim(query) do
          "" -> {:error, :missing_query}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_query}
    end
  end

  defp normalize_variables(arguments) do
    case Map.get(arguments, "variables") || Map.get(arguments, :variables) || %{} do
      variables when is_map(variables) -> {:ok, variables}
      _ -> {:error, :invalid_variables}
    end
  end

  defp graphql_response(response) do
    success =
      case response do
        %{"errors" => errors} when is_list(errors) and errors != [] -> false
        %{errors: errors} when is_list(errors) and errors != [] -> false
        _ -> true
      end

    dynamic_tool_response(success, encode_payload(response))
  end

  defp failure_response(payload) do
    dynamic_tool_response(false, encode_payload(payload))
  end

  defp success_response(payload) do
    dynamic_tool_response(true, encode_payload(payload))
  end

  defp dynamic_tool_response(success, output) when is_boolean(success) and is_binary(output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => output
        }
      ]
    }
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp tool_error_payload(:missing_query) do
    %{
      "error" => %{
        "message" => "`linear_graphql` requires a non-empty `query` string."
      }
    }
  end

  defp tool_error_payload(:invalid_arguments) do
    %{
      "error" => %{
        "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
      }
    }
  end

  defp tool_error_payload(:invalid_variables) do
    %{
      "error" => %{
        "message" => "`linear_graphql.variables` must be a JSON object when provided."
      }
    }
  end

  defp tool_error_payload(:invalid_lifecycle_arguments) do
    %{
      "error" => %{
        "message" => "Linear lifecycle tools require a JSON object argument."
      }
    }
  end

  defp tool_error_payload(:missing_issue_context) do
    %{
      "error" => %{
        "message" => "Linear lifecycle tool execution requires Symphony's resolved issue context."
      }
    }
  end

  defp tool_error_payload(:missing_issue_id) do
    %{
      "error" => %{
        "message" => "Linear lifecycle tools require the resolved `issue_id` from the issue packet."
      }
    }
  end

  defp tool_error_payload({:missing_required_argument, argument}) do
    %{
      "error" => %{
        "message" => "Linear lifecycle tool missing required argument `#{argument}`."
      }
    }
  end

  defp tool_error_payload({:issue_id_mismatch, details}) do
    %{
      "error" =>
        Map.merge(
          %{"message" => "Linear lifecycle tools can only operate on the current issue."},
          Map.new(details, fn {key, value} -> {to_string(key), value} end)
        )
    }
  end

  defp tool_error_payload(%{code: "state_not_found"} = details) do
    %{
      "error" => %{
        "message" => "Requested Linear state was not found in the resolved state map.",
        "code" => "state_not_found",
        "requested_state" => details.requested_state,
        "available_states" => details.available_states
      }
    }
  end

  defp tool_error_payload({:finalization_gate_blocked, result}) do
    %{
      "error" => %{
        "message" => "Finalization gate blocked the Linear state transition.",
        "code" => "finalization_gate_blocked",
        "target_state" => Map.get(result, :target_state),
        "final_state" => Map.get(result, :final_state),
        "finalization_reason" => Map.get(result, :finalization_reason),
        "protocol_violations" => Enum.map(Map.get(result, :protocol_violations, []), &violation_payload/1),
        "protocol_warnings" => Enum.map(Map.get(result, :protocol_warnings, []), &violation_payload/1)
      }
    }
  end

  defp tool_error_payload(:missing_linear_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
      }
    }
  end

  defp tool_error_payload({:linear_api_status, status}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload({:linear_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(reason) do
    %{
      "error" => %{
        "message" => "Linear GraphQL tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end

  defp violation_payload(violation) do
    %{
      "code" => violation.code |> to_string(),
      "severity" => violation.severity |> to_string(),
      "message" => violation.message,
      "required_action" => violation.required_action,
      "evidence" => stringify_keys(violation.evidence)
    }
  end

  defp stringify_keys(map) when is_map(map), do: Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
