---
thread: 2026-07-14-shastara-org-gcp-provision
round: 15
from: claude
to: user
created: 2026-07-15T02:30:00Z
in_reply_to: round-06-prompt.md
status: blocked
---

# Round 15 — cli release RED: 4.18.0 tagged but NOT published (recoverable)

PR #71 merged. Semantic-release cut **4.18.0** (main tip `e000835`, tag `v4.18.0`)
but the **Semantic Release workflow FAILED** and nothing published.

## Diagnosis (no code/build problem)
- Failure is in semantic-release's **post-release** GitHub plugin:
  `AggregateError: Could not resolve to an Issue with the number of 69`.
- Cause: the merge commit / PR body referenced `#69` and `#70` (the apt-CI fix
  PRs). `@semantic-release/github`'s success step tries to comment on referenced
  issues/PRs and couldn't resolve `#69` in this context → the whole step errored.
- The **dispatch of `release-cli`** (the actual crates.io publish + apt/homebrew)
  is the step AFTER that, so it was **skipped**. The `v4.18.0` tag was created by
  `GITHUB_TOKEN`, which by GitHub's anti-loop rule does NOT trigger the
  tag-push path of `release-cli`. So nothing published.

## Verified NOT published
- crates.io: **noetl 4.18.0 ABSENT** (latest 4.17.0); **noetl-executor 0.8.0
  ABSENT** (latest 0.7.0).
- No `release-cli` run exists for 4.18.0.
- apt/homebrew: not reached.

## Recovery (clean, designed path — awaiting go)
`release-cli` (`.github/workflows/release.yml`, name "release-cli") supports
**`workflow_dispatch`** with an optional `version` input (defaults to Cargo.toml =
4.18.0). Dispatching it publishes noetl-events → executor 0.8.0 → noetl 4.18.0 +
apt + homebrew — exactly what the failed run would have dispatched. The version is
already cut + tagged; this only completes the interrupted publish. It is NOT a
force past a code failure.

## Process note (so it doesn't recur)
Don't put bare `#NN` references to OTHER repos' PRs in a release-triggering commit
body — semantic-release's success plugin tries to comment on them and fails the
run. Use full URLs or omit.

## HELD (per "STOP on red")
Not dispatching release-cli without the human go. IAM grant not applied; billing
5/10 (quota request is the user's).
