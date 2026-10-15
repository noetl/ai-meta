# Plan — serve-from-embedded flip (ai-meta#332)

**DESIGN ONLY. Hard-held. Requires explicit owner go.** 2026-09-09.

## ⚠⚠ What tonight's evidence does and does not prove

The shadow has now run on prod and in kind with **0 divergences** across
thousands of appends (peak `agreed=1,826` in one pod-life, `append_failed=0`).

That is evidence about the **write path only**. `shadow_append` compares
`appended` against `rows.len()` — *"did the engine accept every record the log
was about to take"*. It never reads anything back.

So the shadow proves the engine **accepts** writes. It proves **nothing** about
whether the engine can **answer a query correctly**, which is the entire content
of the flip. Treating `diverged=0` as flip-readiness would be the
count-agreement-implies-content-agreement mistake that
[#325](https://github.com/noetl/ai-meta/issues/325) already caught once: a
comparator that deserialised five fields and compared three reported `match` on
executions that differed, and had done so all along.

**The flip therefore cannot be gated on the shadow. It needs a read-path
comparison that does not exist yet.**

## The three-stage ladder (the house idiom, not a new invention)

`NOETL_EHDB_RECOVERY_SOURCE`, `NOETL_CATALOG_READ_SOURCE` and
`NOETL_EHDB_EVENTLOG` already use `shadow` / `verify` / `primary`. The flip uses
the same ladder, and the middle rung is the point:

| stage | behaviour | what it proves |
| :-- | :-- | :-- |
| `shadow` *(today)* | engine appends alongside; nothing reads it | the engine accepts the write set |
| **`verify`** | **every read is served from Postgres AND answered from the engine; the two are compared and the divergence recorded. Postgres's answer is what the caller gets.** | the engine can *answer* — the missing evidence, gathered at zero risk |
| `primary` | the engine's answer is served | — |

⚠ `verify` is not a formality to pass through quickly. It is the only stage that
produces read-path evidence, and it produces it **while Postgres is still
answering**, so a wrong engine answer costs a metric increment rather than a
wrong result to a user.

### Proposed knob

`NOETL_EHDB_EMBEDDED_READ_SOURCE` = `off` (default) | `verify` | `primary`,
separate from `NOETL_EHDB_EMBEDDED` (which continues to govern whether the
engine is opened and written at all). Two knobs, because "stop reading from it"
and "stop writing to it" are different rollbacks and you want the cheap one
available first.

Metrics, pinned unconditionally over a closed label set:
`noetl_ehdb_embedded_read_total{outcome}` with
`agreed` / `diverged` / `engine_error` / `skipped`, plus a
`{kind}` label for the query shape being compared.

## Gate criteria — all must hold, none of them optional

| # | criterion | why |
| :-- | :-- | :-- |
| 1 | **Persistent volume in place and recovery proven on the target** | validated in kind (pod deleted, md5 identical, engine reopened on pre-existing data). Must be re-proven on the prod StatefulSet, because the storage class and disk differ. |
| 2 | **`verify` mode soaked with a real divergence budget** | ≥ 7 days and ≥ 10⁵ compared reads with `diverged = 0`; any non-zero divergence resets the clock and is root-caused first. |
| 3 | **A positive control for the comparator** | a deliberately corrupted read must be *detected*. Without it, `diverged=0` is indistinguishable from a comparator that cannot fire — the defect this program has produced repeatedly. |
| 4 | **Read-path latency measured, not assumed** | engine reads happen under the same lock the appends take; p99 must be compared against the Postgres path before it becomes the only path. |
| 5 | **N>1 ownership + fail-closed proven** | done in kind (2 shards agreeing independently; 4×503 with the owner down). Re-prove on prod topology before N>1, not before N=1 flip. |
| 6 | **Rollback rehearsed** | `READ_SOURCE` back to `verify` must restore Postgres answers with no restart. Rehearse in kind first. |

Criterion 3 is the one most likely to be skipped and the one that makes the
other numbers mean anything.

## Flip mechanism — staged and reversible

1. Ship `verify` support (code change, mutation-gated as usual). Default `off`,
   so merging changes nothing.
2. Arm `verify` on prod — env-only, full-spec diff, one env var.
3. Soak against criterion 2 + 3.
4. Flip `primary` — env-only, same discipline.
5. **Rollback at any point is `READ_SOURCE` back one rung**, env-only. No image
   change, no data migration, because Postgres never stopped being written.

⚠ The rollback stays cheap **only while Postgres remains the write authority**.
The moment the embedded engine becomes the sole writer, rollback becomes a data
migration. That is a later, separate decision and it should be recorded as such
rather than arrived at by drift.

## What could make this unsafe, honestly stated

- **The engine has never served a read in production.** Every result to date is
  about appends.
- **A single `Mutex` guards the engine.** Reads on the serving path contend with
  appends; the shadow's write-only workload has not exercised that.
- **Local state is pod-local.** With the volume it survives restarts; it does not
  survive a *node* loss unless the disk is regional. `standard-rwo` is zonal —
  decide deliberately whether that is acceptable before `primary`.
- **The 2026-09-09 load test degraded prod for ~40 minutes**, and that was with
  the engine in shadow. Load characterisation of `verify` mode belongs in kind,
  not prod.
