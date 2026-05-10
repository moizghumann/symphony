# Phase 3.6 Orchestration Validation

## Summary

partial

Layer A unit tests and Layer B local dry-run simulations pass. Layer C real Linear/GitHub smoke tests were not run in this PR because they require explicit live credentials and mutating access.

## Test Matrix

| Lane | Unit tests | Dry run | Real smoke | Result |
|---|---|---|---|---|
| docs | pass | pass | not run | partial |
| bug | pass | pass | not run | partial |
| feature | pass | pass | not run | partial |
| refactor | pass | pass | not run | partial |
| test | pass | pass | not run | partial |
| chore | pass | pass | not run | partial |
| research | pass | pass | not run | partial |

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

real smoke tests not run

reason: requires explicit `RUN_REAL_SMOKE=true` plus live Linear and GitHub credentials with permission to create issues, branches, commits, draft PRs, and Linear comments/state transitions.

Required environment/auth:

- `RUN_REAL_SMOKE=true`
- Linear API key with access to team `Agent Workbench`
- GitHub credentials with write access to `moizghumann/symphony`
- Symphony configured for project `Symphony Agent Queue`
- Exact Linear statuses available: `Backlog`, `Todo`, `In Progress`, `Human Review`, `Rework`, `Merging`, `Blocked`, `Done`, `Duplicate`, `Canceled`

Manual procedure:

1. Create three fresh Linear issues in team `Agent Workbench`, project `Symphony Agent Queue`, initial state `Todo`: docs, bug or test, and research.
2. Start Symphony only after confirming `RUN_REAL_SMOKE=true`:

   ```sh
   cd elixir
   RUN_REAL_SMOKE=true mise exec -- mix run --no-halt
   ```

3. For each run, collect Linear identifier, lane, classification reason, final state, PR URL if repo changed, changed files, validation status, effective tokens, gross context tokens, cached input tokens, tool-call count, generic GraphQL calls, narrow lifecycle calls, budget state, finalization gate result, protocol violations, and protocol warnings.
4. Stop after the first three smoke tests and review results before creating the remaining lane tickets.

## Required Fixes Before Phase 4

- Run Layer C real smoke tests with `RUN_REAL_SMOKE=true`.
- Do not proceed to Phase 4 if any real smoke reaches Human Review without required artifacts or exceeds budget without being marked `pass_with_budget_warning`.

## Recommendation

Do not mark Phase 3.6 fully passed until real smoke tests run. The local validation suite is directionally correct and should be used as the preflight gate before live smoke testing.
