defmodule SymphonyElixir.GitHubHandoff do
  @moduledoc """
  Publishes completed repository changes and hands a draft PR back to Linear.
  """

  require Logger

  alias SymphonyElixir.{Linear.Issue, SSH, Tracker}

  @type worker_host :: String.t() | nil
  @type result :: :no_repo_changes | {:ok, String.t()} | {:error, term()}

  @spec complete(Path.t(), Issue.t()) :: result()
  def complete(workspace, issue), do: complete(workspace, issue, nil)

  @spec complete(Path.t(), Issue.t(), worker_host()) :: result()
  def complete(workspace, %Issue{} = issue, worker_host) when is_binary(workspace) do
    with :ok <- ensure_git_repo(workspace, worker_host),
         true <- repo_changing_ticket?(workspace, worker_host),
         {:ok, branch} <- ensure_branch(workspace, issue, worker_host),
         :ok <- commit_changes(workspace, issue, worker_host),
         :ok <- push_branch(workspace, branch, worker_host),
         {:ok, pr_url} <- create_draft_pr(workspace, branch, issue, worker_host),
         :ok <- post_handoff(issue, pr_url),
         :ok <- Tracker.move_issue_to_state(issue, "Human Review") do
      {:ok, pr_url}
    else
      false ->
        :no_repo_changes

      {:error, :not_a_git_repo} ->
        :no_repo_changes

      {:error, reason} = error ->
        block_issue(issue, reason)
        error
    end
  end

  def complete(_workspace, _issue, _worker_host), do: {:error, :invalid_handoff_arguments}

  defp ensure_git_repo(workspace, worker_host) do
    case run(workspace, "git", ["rev-parse", "--is-inside-work-tree"], worker_host) do
      {:ok, output} ->
        if String.trim(output) == "true", do: :ok, else: {:error, :not_a_git_repo}

      {:error, reason} ->
        if git_not_a_repo_error?(reason), do: {:error, :not_a_git_repo}, else: {:error, {:git_repo_check_failed, reason}}
    end
  end

  defp repo_changing_ticket?(workspace, worker_host) do
    with {:ok, status} <- run(workspace, "git", ["status", "--porcelain"], worker_host),
         {:ok, ahead} <- run(workspace, "git", ["rev-list", "--count", "origin/main..HEAD"], worker_host) do
      String.trim(status) != "" or parse_count(ahead) > 0
    else
      _ -> false
    end
  end

  defp ensure_branch(workspace, %Issue{} = issue, worker_host) do
    with {:ok, branch} <- current_branch(workspace, worker_host) do
      if branch in ["", "main", "master"] do
        branch = issue_branch_name(issue)

        case run(workspace, "git", ["switch", "-c", branch], worker_host) do
          {:ok, _output} -> {:ok, branch}
          {:error, reason} -> {:error, {:git_branch_failed, reason}}
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

  defp commit_changes(workspace, %Issue{} = issue, worker_host) do
    with {:ok, _} <- run(workspace, "git", ["add", "-A"], worker_host),
         {:ok, staged} <- run(workspace, "git", ["diff", "--cached", "--name-only"], worker_host) do
      if String.trim(staged) == "" do
        :ok
      else
        case run(workspace, "git", ["commit", "-m", commit_message(issue)], worker_host) do
          {:ok, _output} -> :ok
          {:error, reason} -> {:error, {:git_commit_failed, reason}}
        end
      end
    else
      {:error, reason} -> {:error, {:git_commit_prepare_failed, reason}}
    end
  end

  defp push_branch(workspace, branch, worker_host) when is_binary(branch) do
    case run(workspace, "git", ["push", "-u", "origin", branch], worker_host) do
      {:ok, _output} -> :ok
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

  defp post_handoff(%Issue{} = issue, pr_url) when is_binary(pr_url) do
    Tracker.post_handoff_comment(issue, handoff_comment(issue, pr_url))
  end

  defp block_issue(issue, reason) do
    Logger.warning("Blocking issue after publish handoff failure issue_id=#{issue.id} issue_identifier=#{issue.identifier} reason=#{inspect(reason)}")
    _ = Tracker.post_handoff_comment(issue, blocked_comment(reason))
    _ = Tracker.move_issue_to_blocked(issue)
    :ok
  end

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

  defp git_not_a_repo_error?({_status, output}) when is_binary(output) do
    String.contains?(output, "not a git repository")
  end

  defp git_not_a_repo_error?(_reason), do: false

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
