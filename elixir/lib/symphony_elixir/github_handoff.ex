defmodule SymphonyElixir.GitHubHandoff do
  @moduledoc """
  Creates the draft PR for already-pushed repository changes and hands it back to Linear.
  """

  require Logger

  alias SymphonyElixir.{Linear.Issue, SSH, Tracker}
  alias SymphonyElixir.Protocol.{Contract, FinalizationGate, Validation}

  @phase36_handoff_path ".phase36/handoff.json"

  @type worker_host :: String.t() | nil
  @type result :: :no_repo_changes | {:ok, String.t()} | {:error, term()}

  @spec complete(Path.t(), Issue.t()) :: result()
  def complete(workspace, issue), do: complete(workspace, issue, nil)

  @spec complete(Path.t(), Issue.t(), worker_host()) :: result()
  def complete(workspace, issue, worker_host), do: complete(workspace, issue, worker_host, [])

  @spec complete(Path.t(), Issue.t(), worker_host(), keyword()) :: result()
  def complete(workspace, %Issue{} = issue, worker_host, opts) when is_binary(workspace) and is_list(opts) do
    contract = Contract.current()

    with :ok <- ensure_git_repo(workspace, worker_host),
         {:ok, artifacts} <- repo_artifacts(workspace, issue, worker_host),
         true <- artifacts.repo_changed,
         {:ok, branch} <- ensure_branch(workspace, issue, worker_host, opts),
         :ok <- ensure_committed(workspace, worker_host, issue, opts),
         {:ok, commit_sha} <- head_sha(workspace, worker_host),
         :ok <- ensure_pushed(workspace, branch, worker_host, opts),
         {:ok, pr_url} <- create_draft_pr(workspace, branch, issue, worker_host),
         :ok <- post_handoff(issue, pr_url, opts),
         :ok <-
           update_phase36_handoff_artifact(workspace, %{
             branch_name: branch,
             commit_sha: commit_sha,
             pr_url: pr_url,
             changed_files: artifacts.changed_files,
             linear_comment_posted: true,
             final_state_requested: contract.review_state
           }),
         :ok <- ensure_committed(workspace, worker_host, issue, opts),
         :ok <- ensure_pushed(workspace, branch, worker_host, opts),
         :ok <-
           move_to_human_review(
             issue,
             Map.merge(artifacts, %{
               branch_name: branch,
               commit_sha: commit_sha,
               branch_pushed: true,
               pr_url: pr_url,
               pr_created: true,
               pr_is_draft: true,
               pr_posted_to_linear: true,
               handoff_posted: true
             }),
             opts
           ) do
      {:ok, pr_url}
    else
      false ->
        :no_repo_changes

      {:error, :not_a_git_repo} ->
        :no_repo_changes

      {:error, reason} = error ->
        block_issue(issue, reason, opts)
        error
    end
  end

  def complete(_workspace, _issue, _worker_host, _opts), do: {:error, :invalid_handoff_arguments}

  defp ensure_git_repo(workspace, worker_host) do
    case run(workspace, "git", ["rev-parse", "--is-inside-work-tree"], worker_host) do
      {:ok, output} ->
        if String.trim(output) == "true", do: :ok, else: {:error, :not_a_git_repo}

      {:error, reason} ->
        if git_not_a_repo_error?(reason) do
          {:error, :not_a_git_repo}
        else
          {:error, {:git_repo_check_failed, reason}}
        end
    end
  end

  defp repo_artifacts(workspace, %Issue{} = issue, worker_host) do
    with {:ok, status} <- run(workspace, "git", ["status", "--porcelain"], worker_host),
         {:ok, ahead} <- run(workspace, "git", ["rev-list", "--count", "origin/main..HEAD"], worker_host),
         {:ok, changed} <- changed_files(workspace, worker_host) do
      repo_changed = String.trim(status) != "" or parse_count(ahead) > 0 or changed != []
      lane = infer_lane(issue, changed)
      validation = Validation.summarize(workspace, changed, lane: lane)

      {:ok,
       Map.merge(validation, %{
         lane: lane,
         classification_reason: "inferred from labels/title/files during handoff",
         repo_changed: repo_changed,
         changed_files: changed,
         branch_name: nil,
         commit_sha: nil,
         pr_url: nil,
         pr_created: false,
         pr_posted_to_linear: false,
         handoff_posted: false,
         branch_pushed: false,
         current_state: issue.state,
         available_states: issue.available_states,
         ticket_text: issue_text(issue),
         budget_state: :ok
       })}
    else
      {:error, reason} -> {:error, {:repo_artifacts_failed, reason}}
    end
  end

  defp changed_files(workspace, worker_host) do
    case run(workspace, "git", ["diff", "--name-only", "origin/main...HEAD"], worker_host) do
      {:ok, output} ->
        changed_files =
          output
          |> parse_changed_files()
          |> FinalizationGate.product_changed_files()

        if changed_files == [] do
          changed_files_from_status(workspace, worker_host)
        else
          {:ok, changed_files}
        end

      {:error, _reason} ->
        changed_files_from_status(workspace, worker_host)
    end
  end

  defp changed_files_from_status(workspace, worker_host) do
    case run(workspace, "git", ["status", "--porcelain"], worker_host) do
      {:ok, output} ->
        {:ok, output |> parse_status_changed_files() |> FinalizationGate.product_changed_files()}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_changed_files(output) when is_binary(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp parse_status_changed_files(output) when is_binary(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(&String.slice(&1, 3..-1//1))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp ensure_branch(workspace, %Issue{} = issue, worker_host, opts) do
    with {:ok, branch} <- current_branch(workspace, worker_host) do
      if branch in ["", "main", "master"] do
        if Keyword.get(opts, :auto_publish_from_main, false) do
          switch_branch(workspace, issue_branch_name(issue), worker_host)
        else
          {:error, {:git_branch_failed, {:invalid_handoff_branch, branch, issue_branch_name(issue)}}}
        end
      else
        {:ok, branch}
      end
    end
  end

  defp current_branch(workspace, worker_host) do
    case run(workspace, "git", ["branch", "--show-current"], worker_host) do
      {:ok, output} -> {:ok, String.trim(output)}
      {:error, reason} -> {:error, {:git_current_branch_failed, reason}}
    end
  end

  defp switch_branch(workspace, branch, worker_host) do
    case run(workspace, "git", ["switch", "-c", branch], worker_host) do
      {:ok, _output} -> {:ok, branch}
      {:error, reason} -> {:error, {:git_branch_failed, reason}}
    end
  end

  defp head_sha(workspace, worker_host) do
    case run(workspace, "git", ["rev-parse", "HEAD"], worker_host) do
      {:ok, output} -> {:ok, String.trim(output)}
      {:error, reason} -> {:error, {:git_commit_failed, reason}}
    end
  end

  defp commit_changes(workspace, %Issue{} = issue, worker_host) do
    case run(workspace, "git", ["commit", "-m", commit_message(issue)], worker_host) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, {:git_commit_failed, reason}}
    end
  end

  defp issue_branch_name(%Issue{branch_name: branch_name}) when is_binary(branch_name) do
    case String.trim(branch_name) do
      "" -> "symphony/issue"
      branch -> branch
    end
  end

  defp issue_branch_name(%Issue{identifier: identifier}) when is_binary(identifier) do
    "symphony/" <> slug(identifier)
  end

  defp issue_branch_name(_issue), do: "symphony/issue"

  defp ensure_committed(workspace, worker_host, issue, opts) do
    case run(workspace, "git", ["status", "--porcelain"], worker_host) do
      {:ok, output} ->
        product_files =
          output
          |> parse_status_changed_files()
          |> FinalizationGate.product_changed_files()

        if product_files == [] do
          :ok
        else
          if Keyword.get(opts, :auto_publish_from_main, false) do
            with :ok <- stage_product_changes(workspace, worker_host),
                 :ok <- commit_changes(workspace, issue, worker_host) do
              :ok
            end
          else
            {:error, {:git_commit_failed, {:uncommitted_changes, output}}}
          end
        end

      {:error, reason} ->
        {:error, {:git_commit_failed, reason}}
    end
  end

  defp stage_product_changes(workspace, worker_host) do
    case run(workspace, "git", ["add", "-A", "--", ":/", ":!.phase36", ":!.phase36/**"], worker_host) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, {:git_stage_failed, reason}}
    end
  end

  defp ensure_pushed(workspace, branch, worker_host, opts) when is_binary(branch) do
    with {:ok, head_sha} <- run(workspace, "git", ["rev-parse", "HEAD"], worker_host),
         {:ok, remote_output} <- run(workspace, "git", ["ls-remote", "--heads", "origin", branch], worker_host) do
      local_sha = String.trim(head_sha)

      if remote_contains_sha?(remote_output, local_sha) do
        :ok
      else
        if Keyword.get(opts, :auto_publish_from_main, false) do
          case run(workspace, "git", ["push", "-u", "origin", branch], worker_host) do
            {:ok, _output} -> :ok
            {:error, reason} -> {:error, {:git_push_failed, reason}}
          end
        else
          {:error, {:git_push_failed, {:remote_branch_missing_head, branch, local_sha, remote_output}}}
        end
      end
    else
      {:error, reason} -> {:error, {:git_push_failed, reason}}
    end
  end

  defp create_draft_pr(workspace, branch, %Issue{} = issue, worker_host) do
    args = [
      "pr",
      "create",
      "--draft",
      "--head",
      branch,
      "--base",
      "main",
      "--title",
      pr_title(issue),
      "--body",
      pr_body(issue)
    ]

    case run(workspace, "gh", args, worker_host) do
      {:ok, output} ->
        case extract_url(output) do
          nil -> {:error, {:gh_pr_create_missing_url, output}}
          url -> {:ok, url}
        end

      {:error, reason} ->
        {:error, {:gh_pr_create_failed, reason}}
    end
  end

  defp post_handoff(%Issue{} = issue, pr_url, opts) when is_binary(pr_url) do
    body = handoff_comment(issue, pr_url)
    result = Tracker.post_handoff_comment_result(issue, body)

    record_lifecycle_call(opts, "linear_post_handoff", %{issue_id: issue.id, body: body}, result)
    normalize_lifecycle_result(result)
  end

  defp move_to_human_review(%Issue{} = issue, artifacts, opts) do
    contract = Contract.current()

    with {:ok, gate_result} <- finalization_gate_result(artifacts, contract.review_state, contract) do
      Logger.info("Finalization gate allowed Human Review issue_id=#{issue.id} issue_identifier=#{issue.identifier} reason=#{gate_result.finalization_reason}")

      result = Tracker.move_issue_to_state(issue, contract.review_state)
      record_lifecycle_call(opts, "linear_move_to_human_review", %{issue_id: issue.id}, result)
      result
    else
      {:blocked, gate_result} ->
        reason = {:finalization_gate_blocked, gate_result}
        block_issue(issue, reason, opts)
        {:error, reason}
    end
  end

  defp block_issue(issue, reason, opts) do
    Logger.warning("Blocking issue after publish handoff failure issue_id=#{issue.id} issue_identifier=#{issue.identifier} reason=#{inspect(reason)}")
    blocker_body = blocked_comment(reason)
    blocker_result = Tracker.post_handoff_comment(issue, blocker_body)
    handoff_posted? = blocker_result == :ok
    contract = Contract.current()

    gate_state = %{
      current_state: issue.state,
      available_states: issue.available_states,
      blocker_reason: inspect(reason),
      handoff_posted: handoff_posted?,
      repo_changed: false,
      changed_files: []
    }

    blocked_result =
      case FinalizationGate.evaluate(gate_state, contract.blocked_state, contract) do
        {:ok, _gate_result} -> Tracker.move_issue_to_state(issue, contract.blocked_state)
        {:blocked, gate_result} -> {:error, {:finalization_gate_blocked_blocked_transition, gate_result}}
      end

    record_lifecycle_call(opts, "linear_post_blocker", %{issue_id: issue.id, body: blocker_body}, blocker_result)
    record_lifecycle_call(opts, "linear_move_to_blocked", %{issue_id: issue.id}, blocked_result)
    :ok
  end

  defp finalization_gate_result(artifacts, target_state, contract) do
    case FinalizationGate.evaluate(artifacts, target_state, contract) do
      {:ok, gate_result} -> {:ok, gate_result}
      {:blocked, gate_result} -> {:blocked, gate_result}
    end
  end

  defp record_lifecycle_call(opts, tool_name, arguments, result) do
    case Keyword.get(opts, :lifecycle_recorder) do
      recorder when is_function(recorder, 1) ->
        recorder.(%{
          tool_name: tool_name,
          tool_arguments: arguments,
          tool_result: lifecycle_tool_result(result)
        })

      _ ->
        :ok
    end
  end

  defp normalize_lifecycle_result(:ok), do: :ok
  defp normalize_lifecycle_result({:ok, _payload}), do: :ok
  defp normalize_lifecycle_result({:error, reason}), do: {:error, reason}

  defp lifecycle_tool_result(:ok), do: %{"success" => true}

  defp lifecycle_tool_result({:ok, %{comment_id: comment_id}}) when is_binary(comment_id) do
    %{"success" => true, "comment_id" => comment_id}
  end

  defp lifecycle_tool_result({:ok, _payload}), do: %{"success" => true}
  defp lifecycle_tool_result(_result), do: %{"success" => false}

  defp commit_message(%Issue{identifier: identifier, title: title}) do
    [identifier, title]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&String.trim(to_string(&1)))
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(": ")
    |> case do
      "" -> "Apply Linear issue changes"
      message -> message
    end
  end

  defp pr_title(%Issue{identifier: identifier, title: title}), do: commit_message(%Issue{identifier: identifier, title: title})

  defp pr_body(%Issue{} = issue) do
    """
    ## Summary
    - Implements #{issue.identifier || "the Linear issue"}: #{issue.title || "Untitled issue"}

    ## Linear
    #{issue.url || "n/a"}

    ## Validation
    - See the Symphony Linear handoff comment for the agent-reported validation.
    """
  end

  defp handoff_comment(%Issue{} = issue, pr_url) do
    """
    ## Symphony Handoff

    Draft PR: #{pr_url}

    Issue: #{issue.identifier || issue.id}
    State: Human Review
    """
  end

  defp blocked_comment(reason) do
    """
    ## Symphony Handoff Blocked

    Symphony could not publish the draft PR or complete the Linear handoff.

    Blocker:
    ```text
    #{inspect(reason)}
    ```
    """
  end

  defp run(workspace, command, args, nil) do
    case System.find_executable(command) do
      nil ->
        {:error, {:command_not_found, command}}

      executable ->
        case System.cmd(executable, args, cd: workspace, stderr_to_stdout: true) do
          {output, 0} -> {:ok, output}
          {output, status} -> {:error, {status, output}}
        end
    end
  end

  defp run(workspace, command, args, worker_host) when is_binary(worker_host) do
    shell_command =
      "cd #{shell_escape(workspace)} && " <>
        ([command | args] |> Enum.map_join(" ", &shell_escape/1))

    case SSH.run(worker_host, shell_command, stderr_to_stdout: true) do
      {:ok, {output, 0}} -> {:ok, output}
      {:ok, {output, status}} -> {:error, {status, output}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp update_phase36_handoff_artifact(workspace, updates) do
    path = Path.join(workspace, @phase36_handoff_path)

    if File.exists?(path) do
      with {:ok, body} <- File.read(path),
           {:ok, %{} = artifact} <- Jason.decode(body),
           :ok <- write_phase36_handoff_artifact(path, artifact, updates) do
        :ok
      else
        _ -> :ok
      end
    else
      :ok
    end
  end

  defp write_phase36_handoff_artifact(path, artifact, updates) do
    handoff =
      artifact
      |> Map.get("handoff", %{})
      |> Map.merge(%{
        "linear_comment_posted" => updates.linear_comment_posted,
        "final_state_requested" => updates.final_state_requested
      })

    artifact =
      artifact
      |> Map.merge(%{
        "status" => "handoff_complete",
        "repo_changed" => true,
        "branch_name" => updates.branch_name,
        "commit_sha" => updates.commit_sha,
        "pr_url" => updates.pr_url,
        "changed_files" => updates.changed_files,
        "handoff" => handoff
      })

    File.write(path, Jason.encode!(artifact, pretty: true))
  end

  defp extract_url(output) when is_binary(output) do
    ~r/https?:\/\/\S+/
    |> Regex.run(output)
    |> case do
      [url | _] -> String.trim_trailing(url, ".")
      _ -> nil
    end
  end

  defp parse_count(output) when is_binary(output) do
    case Integer.parse(String.trim(output)) do
      {count, _} -> count
      _ -> 0
    end
  end

  defp infer_lane(%Issue{} = issue, changed_files) do
    text =
      ([issue.title, issue.description] ++ List.wrap(issue.labels))
      |> Enum.reject(&is_nil/1)
      |> Enum.map_join(" ", &to_string/1)
      |> String.downcase()

    text_lane = lane_from_text(text)

    cond do
      text_lane != nil -> text_lane
      changed_files != [] and !FinalizationGate.code_bearing_changes?(changed_files) -> "docs"
      true -> "feature"
    end
  end

  defp lane_from_text(text) do
    cond do
      String.contains?(text, ["bug", "fix", "regression"]) -> "bug"
      String.contains?(text, ["refactor", "cleanup"]) -> "refactor"
      String.contains?(text, ["test", "coverage", "spec"]) -> "test"
      String.contains?(text, ["chore", "ci", "config", "dependency", "deps"]) -> "chore"
      String.contains?(text, ["research", "investigate", "analysis"]) -> "research"
      String.contains?(text, ["docs", "documentation", "readme"]) -> "docs"
      true -> nil
    end
  end

  defp issue_text(%Issue{} = issue) do
    [issue.title, issue.description]
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join("\n", &to_string/1)
  end

  defp git_not_a_repo_error?({_status, output}) when is_binary(output) do
    String.contains?(output, "not a git repository")
  end

  defp git_not_a_repo_error?(_reason), do: false

  defp remote_contains_sha?(remote_output, local_sha) when is_binary(remote_output) and is_binary(local_sha) do
    remote_output
    |> String.split("\n", trim: true)
    |> Enum.any?(fn line ->
      line
      |> String.split()
      |> List.first()
      |> Kernel.==(local_sha)
    end)
  end

  defp slug(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9._-]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "issue"
      slug -> slug
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
