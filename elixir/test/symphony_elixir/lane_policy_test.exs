defmodule SymphonyElixir.LanePolicyTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{JobPacket, LaneClassifier, LanePolicy}

  test "explicit labels win lane classification" do
    issue = %Issue{
      identifier: "AGE-1",
      title: "Fix README typo",
      description: "Could look like a bug, but the label is authoritative.",
      labels: ["docs"]
    }

    assert %{lane: :docs, reason: "explicit label `docs`"} = LaneClassifier.classify(issue)
  end

  test "ambiguous signals choose the least expensive safe lane" do
    issue = %Issue{
      identifier: "AGE-2",
      title: "Fix README contributor copy",
      description: "Update documentation so contributors read AGENTS.md.",
      labels: []
    }

    assert %{lane: :docs, matched_signals: signals} = LaneClassifier.classify(issue)
    assert "docs:readme" in signals
  end

  test "research lane is read-only and PR-optional by default" do
    policy = LanePolicy.policy_for(:research)

    assert policy.max_turns == 4
    assert policy.effective_token_budget == 70_000
    assert policy.max_tool_calls == 25
    refute policy.pr_required
    assert Enum.any?(policy.forbidden_paths, &String.contains?(&1, "repo file edits"))
  end

  test "bug lane requires validation and uses bug-sized budget" do
    issue = %Issue{
      identifier: "AGE-BUG",
      title: "Fix broken validation command",
      description: "The command fails with an error.",
      labels: []
    }

    assert %{lane: :bug} = LaneClassifier.classify(issue)

    packet = JobPacket.compile(issue)
    assert packet.lane == "bug"
    assert packet.validation_policy == "required"
    assert packet.turn_budget == 6
    assert packet.tool_call_budget == 35
    assert packet.token_budget.hard_effective_token_limit == 100_000
  end

  test "job packet renders lane policy budgets and context guidance" do
    issue = %Issue{
      identifier: "AGE-3",
      title: "Update README",
      description: "Only edit README.md.",
      labels: ["docs"]
    }

    packet = JobPacket.compile(issue)
    rendered = JobPacket.render_prompt(packet)

    assert packet.lane == "docs"
    assert packet.turn_budget == 3
    assert packet.tool_call_budget == 12
    assert packet.token_budget.hard_effective_token_limit == 30_000
    assert rendered =~ "Symphony lane-specific job packet"
    assert rendered =~ "For research lane, stay read-only"
  end

  test "research job packet uses narrow Linear handoff instead of PR marker by default" do
    issue = %Issue{
      identifier: "AGE-RESEARCH",
      title: "Investigate README onboarding clarity",
      description: "Read-only review. Post findings in Linear. No code changes.",
      labels: []
    }

    packet = JobPacket.compile(issue)
    rendered = JobPacket.render_prompt(packet)

    assert packet.lane == "research"
    assert packet.pr_policy == "not required unless a repository artifact is created or changed"
    assert packet.completion_policy =~ "linear_post_handoff"
    assert packet.completion_policy =~ "linear_move_to_human_review"
    assert packet.available_github_pr_flow =~ "No PR by default"
    assert rendered =~ "post findings with the narrow Linear handoff/comment path"
  end
end
