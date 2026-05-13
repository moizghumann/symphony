---
tracker:
  kind: linear
  project_slug: "symphony-0c79b11b75ea"
  active_states:
    - Todo
    - In Progress
    - Merging
    - Rework
  terminal_states:
    - Done
    - Duplicate
    - Canceled
polling:
  interval_ms: 5000
workspace:
  root: ~/code/symphony-workspaces
hooks:
  after_create: |
    git clone --depth 1 https://github.com/openai/symphony .
    if command -v mise >/dev/null 2>&1; then
      cd elixir && mise trust && mise exec -- mix deps.get
    fi
  before_remove: |
    cd elixir && mise exec -- mix workspace.before_remove
agent:
  max_concurrent_agents: 10
  max_turns: 20
lanes:
  docs:
    max_turns: 3
    effective_token_budget: 30000
    max_tool_calls: 12
    validation: optional
    pr_required: true
    allowed_paths:
      - AGENTS.md
      - README.md
      - WORKFLOW.md
      - docs/**
    forbidden_paths:
      - src/**
      - public/**
      - test/**
      - tests/**
      - schemas/**
      - examples/**
  bug:
    max_turns: 6
    effective_token_budget: 100000
    max_tool_calls: 35
    validation: required
    pr_required: true
  feature:
    max_turns: 8
    effective_token_budget: 150000
    max_tool_calls: 50
    validation: required
    pr_required: true
  refactor:
    max_turns: 8
    effective_token_budget: 150000
    max_tool_calls: 50
    validation: required
    pr_required: true
  test:
    max_turns: 6
    effective_token_budget: 100000
    max_tool_calls: 35
    validation: required
    pr_required: true
  chore:
    max_turns: 5
    effective_token_budget: 90000
    max_tool_calls: 30
    validation: conditional
    pr_required: true
  research:
    max_turns: 4
    effective_token_budget: 70000
    max_tool_calls: 25
    validation: none
    pr_required: false
codex:
  command: codex --config shell_environment_policy.inherit=all --config 'model="gpt-5.5"' --config model_reasoning_effort=xhigh app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
protocol:
  version: "1"
  repo_changes_require_pr: true
  human_review_requires_pr: true
  blocked_state: "Blocked"
  review_state: "Human Review"
  in_progress_state: "In Progress"
  done_state: "Done"
  canceled_state: "Canceled"
  duplicate_state: "Duplicate"
  allow_ticket_to_disable_pr: false
  generic_linear_graphql_policy: fallback_only
  validation_gate: true
  finalization_gate: true
---

You are working on Linear issue `{{ issue.identifier }}`.

Symphony has already resolved the issue packet, selected the lane, moved `Todo` issues to `In Progress`, and generated the lane-specific job packet above. Treat that packet as authoritative.

Follow the lane policy exactly:

- Use only the allowed context unless the ticket explicitly requires more.
- Avoid forbidden context by default.
- Match validation to the lane policy and ticket `Validation` section.
- Keep turns, effective tokens, and tool calls inside the stated budgets.
- Use generic `linear_graphql` only as fallback/debug; do not rediscover packet data with it.
- For research lane, stay read-only unless the ticket explicitly asks for repository changes.
- For docs lane, keep the change documentation-only and report `not run: docs-only change` unless validation was explicitly requested.
- For code-bearing lanes, capture the required failure signal or implementation evidence and run required validation.

Codex owns repository work only: inspect, edit when allowed, validate, commit, push, and summarize. Symphony owns draft PR creation, Linear handoff comments, PR URL recording, and `Human Review`/`Blocked` transitions after Codex finishes.

Do not finish with the exact marker `SYMPHONY_HANDOFF_READY` until the required lane handoff artifact exists. When repository work is complete, committed, pushed, and validated according to the lane policy, finish with that marker.

Research lane exception: if the packet says no repository artifact is required, stay read-only, inspect and list sources, write `.phase36/handoff.json` with `research_findings`, `sources_inspected`, `recommendation`, `findings_ready_to_post`, `sources_inspected_listed`, `recommendation_included`, `validation_status=not_run`, and `validation_reason=read-only research`, then emit `SYMPHONY_HANDOFF_READY`. Do not create a branch/commit/PR, post directly to Linear, or move the issue to `Human Review` unless Symphony explicitly asks for fallback.

{% if attempt %}
Continuation attempt #{{ attempt }}:

- Resume from the current workspace state.
- Do not restart broad investigation.
- Focus only on the remaining lane-scoped work or concise blocker evidence.
{% endif %}
