# Phase 3.6 Orchestration Validation

## Summary

partial

Layer A unit tests and Layer B local dry-run simulations pass. The required 2026-05-11 non-mutating GitHub/Linear preflight now passes, and local validation was rerun successfully. A safe opt-in Phase 3.6 live-smoke runner now exists, but Layer C real Linear/GitHub smoke tests are still not run because the runner was added without invoking confirmed live mutations in this update.

## Test Matrix

| Lane | Unit tests | Dry run | Real smoke | Result |
|---|---|---|---|---|
| docs | pass | pass | not run, runner added | partial |
| bug | pass | pass | not run, runner supports bug as the test/bug lane choice | partial |
| feature | pass | pass | not run | partial |
| refactor | pass | pass | not run | partial |
| test | pass | pass | not run, runner added | partial |
| chore | pass | pass | not run | partial |
| research | pass | pass | not run, runner added | partial |

## Key Findings

- Lane classifier, lane policy, finalization gate, budget tracking, Linear tool fallback warnings, and dry-run traces now have a Phase 3.6 validation suite.
- The suite found classifier defects before fixes:
  - `Refactor crawler retry logic without behavior changes` was classified as `feature` because `behavior` matched a feature signal.
  - `Add regression tests for business map extraction` was classified as `bug` because `regression` matched a bug signal.
  - `Add a copy button for generated agent card JSON` was classified as `docs` because `copy` matched a docs signal.
- The fixes keep explicit refactor, test-writing, and feature button intent ahead of incidental lower-cost signals.
- The checked-in workflow status list was corrected to use `Canceled`, not `Cancelled`.

## Token Results

No real token-consuming smoke run was executed.

Local budget validation used a simulated Codex usage update:

| Gross context tokens | Cached input tokens | Effective tokens | Budget | Result |
|---:|---:|---:|---:|---|
| 104,000 | 80,000 | 24,000 | 30,000 | warning at 80%, not exceeded |

This verifies effective usage remains `input_tokens - cached_input_tokens + output_tokens`, and raw total is not treated as burn.

## Prompt / Job Packet Size

Measured with local dry-run prompt construction.

| Lane | Prompt chars | Job packet chars | Protocol capsule chars | Universal workflow included |
|---|---:|---:|---:|---|
| docs | 7,716 | 2,993 | 1,039 | false |
| bug | 7,635 | 2,928 | 1,039 | false |
| feature | 7,671 | 2,955 | 1,039 | false |
| refactor | 7,643 | 2,905 | 1,039 | false |
| test | 7,605 | 2,865 | 1,039 | false |
| chore | 7,663 | 2,950 | 1,039 | false |
| research | 7,771 | 3,046 | 1,039 | false |

Result: lane packets stayed small, the protocol capsule stayed compact, and the old universal workflow text was not reintroduced.

## Tool Usage

- Dry-run happy paths use narrow lifecycle semantics and `generic_graphql_calls = 0`.
- Generic Linear GraphQL with a narrow helper available and no narrow failure emits `unnecessary_generic_linear_graphql`.
- Generic Linear GraphQL after a narrow helper failure is allowed when a fallback reason is recorded.
- Narrow `linear_move_to_human_review` cannot bypass missing PR artifacts; the finalization gate rejects the mutation before Linear is called.

## Finalization Gate Results

- docs + repo change + PR artifacts + handoff + validation not run with docs reason: allowed.
- docs + repo change + missing PR: Blocked with `pr_required_but_missing`.
- feature + repo change + missing validation: Blocked with `validation_required_but_missing`.
- bug + repo change + missing failure signal: Blocked with `bug_failure_signal_identified`.
- refactor + validation + behavior-preservation evidence: allowed.
- test + targeted tests missing: Blocked with `tests_not_run`.
- chore + config/script change + missing validation: Blocked with `validation_required_but_missing`.
- research + no repo change + findings posted: allowed.
- research + repo artifact + missing PR: Blocked with `pr_required_but_missing`.

## Phase 3.5 Regression Checks

- no-PR ticket text with valid PR artifacts: Human Review allowed; policy override recorded as warning, not blocking.
- no-PR ticket text with missing PR: Human Review blocked; missing PR remains the blocking reason.
- narrow Human Review tool without PR artifacts: rejected by FinalizationGate; Linear state mutation is not called.

## Regressions

No Phase 1 / 2 / 3 / 3.5 runtime regressions were found in local validation.

Validated:

- Phase 1: effective token accounting is primary; raw total remains gross context; missing PR/budget failures route to Blocked.
- Phase 2: narrow lifecycle tools remain preferred; generic GraphQL fallback is visible and reasoned.
- Phase 3: lane classifier and lane policies control context, budgets, and validation expectations.
- Phase 3.5: runtime protocol contract and finalization gate block invalid Human Review transitions.

## Real Smoke Status

real smoke not run to mutation

Latest preflight and local validation attempt, 2026-05-11:

- `RUN_REAL_SMOKE=true`
- `LINEAR_API_KEY` present
- `GH_TOKEN` present
- `GITHUB_TOKEN` present
- `gh auth status` passed for GitHub account `moizghumann` using `GH_TOKEN`
- `gh repo view moizghumann/symphony --json nameWithOwner` passed with `{"nameWithOwner":"moizghumann/symphony"}`
- Linear viewer query passed for `Moiz Ghuman <moizghuman@gmail.com>`
- Linear team/status query passed for team `Agent Workbench` and returned the expected statuses: `Backlog`, `Todo`, `In Progress`, `Human Review`, `Rework`, `Merging`, `Blocked`, `Done`, `Duplicate`, `Canceled`
- `mise exec -- mix test test/symphony_elixir/phase36_orchestration_validation_test.exs` passed: 10 tests, 0 failures
- `mise exec -- mix test` passed: 279 tests, 0 failures, 2 skipped
- `mise exec -- mix specs.check` passed: all public functions have `@spec` or exemption

Runner follow-up validation, 2026-05-11:

- `mise exec -- mix test test/symphony_elixir/phase36_orchestration_validation_test.exs` passed: 10 tests, 0 failures
- `mise exec -- mix test test/mix/tasks/phase36_live_smoke_test.exs` passed: 4 tests, 0 failures
- `mise exec -- mix specs.check` passed: all public functions have `@spec` or exemption
- `mise exec -- mix test` was run once after the runner change and failed with one existing timing-sensitive orchestrator assertion:
  - `test/symphony_elixir/orchestrator_status_test.exs:1385`
  - assertion: `remaining_ms >= 9500`
  - observed: `9461`
  - final result: 283 tests, 1 failure, 2 skipped

The auth blocker from the prior attempt is resolved. The missing-runner blocker is also addressed by the new guarded Mix task:

```sh
cd elixir
RUN_REAL_SMOKE=true CONFIRM_LIVE_SMOKE_MUTATION=true mise exec -- mix phase36.live_smoke
```

Runner safety gates:

- Refuses to run unless `RUN_REAL_SMOKE=true`.
- Prints the live mutation plan before mutation and refuses to continue unless `CONFIRM_LIVE_SMOKE_MUTATION=true`.
- Refuses to run unless `LINEAR_API_KEY` is present.
- Refuses to run unless `GH_TOKEN` or `GITHUB_TOKEN` is present.
- Runs and passes non-mutating GitHub preflight before mutation:
  - `gh auth status`
  - `gh repo view moizghumann/symphony --json nameWithOwner`
- Runs and passes non-mutating Linear preflight before mutation:
  - viewer query
  - `Agent Workbench` team/state query
  - exact status verification with `Canceled`, not `Cancelled`
  - `Symphony Agent Queue` project lookup

Supported runner lanes:

- `docs`
- exactly one of `test` or `bug`
- `research`

Unsupported lanes remain not run by the runner:

- `feature`
- `refactor`
- `chore`

Runner evidence contract:

- Linear issue identifier
- Linear issue URL
- lane
- classification reason
- final state
- PR URL if repo changed
- branch name if repo changed
- changed files
- validation status
- validation command/result
- effective tokens
- gross context tokens
- cached input tokens
- output tokens
- tool-call count
- generic Linear GraphQL calls
- narrow Linear lifecycle calls
- budget state
- finalization gate result
- protocol violations
- protocol warnings
- handoff comment id or URL if available

The runner does not hardcode successful evidence. If direct `AgentRunner` telemetry does not expose a field, the evidence JSON records the field under `missing_evidence` and includes a `code_seams_needed` entry.

Live smoke was not run after adding the runner. Exact reason: running the new command with `CONFIRM_LIVE_SMOKE_MUTATION=true` would create real Linear issues and may create GitHub branches, commits, pushes, draft PRs, and Linear handoff comments. This update added and validated the safe runner only; it did not perform Layer C live-smoke mutation.

Existing live command reviewed:

- `make e2e` is a real external end-to-end test, but it is not an acceptable Phase 3.6 lane smoke runner.
- It creates a temporary Linear project and issue under the live e2e team, asks Codex to use generic `linear_graphql`, moves the issue to a completed terminal state, and verifies a temporary file/comment.
- It does not constrain execution to the first three Phase 3.6 lanes, does not exercise docs/bug-or-test/research lane policies, does not require docs/bug-test draft PR handoff evidence, and does not collect the required token/tool/finalization-gate evidence.

No Linear issue, live-smoke branch, smoke commit, smoke push, or smoke PR was created by Layer C live smoke in this attempt.

Prior blocked attempts:

- One attempt had invalid `GH_TOKEN` during the required non-mutating preflight even though `GITHUB_TOKEN` was valid. Because the required non-mutating preflight failed, live smoke was not run in that attempt. Existing Layer A/B local validation remained valid, but was not rerun as part of that blocked live-smoke attempt.
- In an earlier worker attempt, after explicit operator permission, the Codex command worker environment did not expose `RUN_REAL_SMOKE`, `LINEAR_API_KEY`, `GH_TOKEN`, or `GITHUB_TOKEN`, even though the user verified those variables in the Codex app terminal. Because the worker could not see the live-smoke gate or auth tokens, GitHub repo read and Linear team/status read were not attempted from the worker, and no mutation was allowed.

## Required Fixes Before Phase 4

- Run Layer C real smoke tests with `RUN_REAL_SMOKE=true` for the first three lanes only: docs, bug or test, and research.
- Do not proceed to Phase 4 if any real smoke reaches Human Review without required artifacts or exceeds budget without being marked `pass_with_budget_warning`.

## Recommendation

Do not mark Phase 3.6 fully passed until real smoke tests run. Phase 3.6 remains partial: preflight and local validation are green, and a safe runner now exists, but Layer C still needs real smoke evidence for docs, bug or test, and research before expanding to the remaining lanes.
