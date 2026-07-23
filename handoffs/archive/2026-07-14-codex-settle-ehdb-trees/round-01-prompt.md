---
thread: 2026-07-14-codex-settle-ehdb-trees
round: 1
from: claude
to: codex
created: 2026-07-15T06:45:00Z
status: ready
expects_result_at: round-01-result.md
wait_phrase: "settle ehdb trees"
---

# Codex task — settle in-flight EHDB working trees, then stand by for the EHDB→NATS takeover plan

## Context
- The Python CLI-wrapper spike (noetl 5.0.0) is being PARKED, not shipped — it lacks CLI parity (23 of 24 subcommands missing; its `run` bypasses the real `PlaybookRunner`). Another agent is preserving that spike onto its own branch. **Do not touch `repos/noetl` until told it's clear.**
- The real Python 5.0.0 path (extract `repos/cli/src/main.rs` → `lib.rs`, bind the real clap dispatcher + `PlaybookRunner` via PyO3) is BLOCKED on the dirty `main.rs` / EHDB Phase D churn settling — which is exactly what this task clears.
- Program priority is now EHDB taking over from NATS. The master-plan RFC for that is being written; do NOT start building against it until it lands and the human signs off.

## Do now — settle the dirty EHDB working trees (highest value)
1. **EHDB Phase D** on `feat/ehdb-phase-d-eventstream`: finish and land the in-progress changes properly (commit / open PR / merge per the repo's normal flow). Get the working tree clean. In particular, stop `repos/cli/src/main.rs` from sitting dirty — that dirty `main.rs` is what blocked the clean lib extraction; land or revert its Phase D edits so `main.rs` is in a committed, known state.
2. **Worker WIP:** the local `repos/worker` checkout has uncommitted work — modified `kv.rs`, `metrics.rs`, `mod.rs`, `object.rs`, `vector.rs`, `metrics_server.rs` (~137 insertions) plus an untracked `src/ehdb/query.rs` (~932 lines). This looks like a SUPERSEDED pre-merge draft of the #178/#184 query-handler / Flight-SQL work already merged on `origin/main`. VERIFY whether it's genuinely superseded (diff it against what's on main); then either discard it (if redundant) or land it (if it carries anything not on main). Don't leave it uncommitted and rotting. Report which you did and why.
3. Leave the trees clean and the branches in a known, committed state so the eventual `main.rs`→`lib.rs` extraction has a stable base.

## Do NOT (for now)
- Do NOT touch `repos/noetl` until the other agent confirms the spike is preserved (it's actively working there — you'll collide).
- Do NOT attempt the `main.rs`→`lib.rs` extraction or any Python-wrapper work yet — it's blocked on step 1 settling.
- Do NOT start building the EHDB→NATS takeover — wait for the RFC + human sign-off.
- Do NOT publish anything (crates.io / PyPI) or do prod/GKE actions.

## Discipline
- No `git reset --hard` / `checkout .` / `stash` that could destroy uncommitted work you haven't first inspected and decided on.
- Don't disturb unrelated dirty state you're not explicitly settling.
- Full URLs (no bare `#NN`) in any release-triggering commit body.
- PRs open for review where the flow calls for it; report before merging anything non-trivial.

## Report back
- Phase D: landed or reverted? branch/PR state, `main.rs` now committed-clean (yes/no).
- Worker WIP: superseded-and-discarded, or carried-and-landed? evidence for the call.
- Confirm all target trees are clean and the base is stable for the later `main.rs` extraction.
- Then: standing by for the EHDB→NATS takeover plan.
