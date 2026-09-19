---
spec: 2026-09-19-slm-ehdb-context-S4
status: draft
created: 2026-09-19T00:00:00Z
owner: claude-opus-5 (ai-meta session 2026-09-19)
---

# S4 — Replay without calling the model; re-derive as a separate mode

Phase of [`spec.md`](spec.md). **Planning only.** Depends on **S3**.

## Scope

Two named modes with different guarantees, and the read path that serves them.

**In scope:** `replay` (default) and `rederive`, the model-call counter that
distinguishes them, and the bounded-staleness read wiring.
**Out of scope:** compaction, which changes what a replay reproduces — S5.

## Flags

| Flag | Values | Default |
| :-- | :-- | :-- |
| `NOETL_SLM_REPLAY_MODE` | `replay` \| `rederive` | `replay` |
| `NOETL_EHDB_READ_CONSISTENCY` | `strong` \| `bounded` \| `exact` | `strong` |
| `NOETL_EHDB_MAX_STALENESS_MS` | int | `0` |

⚠ The last two are **M3's flags** (branch `docs/multiregion-ehdb-plan`,
`specs/active/2026-09-18-multiregion-ehdb/M3-closed-timestamp.md`). This spec
**reuses** them. If M3 lands with different names, S4 follows M3 — it does not
fork a parallel read contract.

## The two modes

| Mode | Model called? | Guarantee |
| :-- | :-- | :-- |
| `replay` | **no** | the run re-executes exactly: the recorded completion **is** the input |
| `rederive` | yes | inputs pinned (prompt, sampling params, `model_ref`); the completion **may differ** |

⭐ Replay not calling the model is the decision that makes an AI run auditable.
The audit question is *"given this context, what did the model say and what did
we do with it"* — fully answered by the log. Re-derive answers *"is this still
what it says"*, which is drift monitoring, not audit.

## What replay does and does not prove

**Proves:** the same folded prompts were assembled, the same specs were admitted
or rejected by the same validator version, the same child executions launched.
**Does not prove:** the model would say it again. Stated here, and in the plan
§8.2, rather than letting a reader infer the stronger claim.

## Reads

An SLM context read is a per-execution prefix read on D1. It uses M0's
`VisibilityResolver` / `VisibilityPlan` and M3's `ReadConsistency`.

⚠ **Two facts a later session must not trip on:**

- Per **C4**, the `primary`-serving tier has no closed timestamp until **M0.5**.
  A `bounded` read requested before then is **inert** — it behaves as `strong`.
  An inert flag that reads as armed is this program's recurring defect, so **A4
  below asserts the inertness explicitly** instead of assuming it.
- **`strong` is the correct default for the generate loop anyway**: a turn must
  see its own predecessor. Bounded staleness is for *observers* of an AI run —
  a console, a drift monitor — never for the fold that feeds the next call.

## Acceptance criteria

- **A1** — `replay` of a recorded AI execution issues **zero** model calls,
  proven by `slm_model_calls_total` staying at its pre-replay value.
- **A2** — the same replay reproduces the same admitted/rejected decisions and
  the same child execution set.
- **A3** — `rederive` issues calls (the counter moves) and is allowed to differ;
  the difference is **reported**, not treated as a failure.
- **A4** — with M0.5 absent, a `bounded` read is asserted to behave identically
  to `strong`, and that inertness is **recorded in this spec** when measured —
  not left as an assumption.

## Instrument

`slm_model_calls_total`, read before and after. ⭐ This is a counter where
**reading 0 proves nothing unless the counter is known to work** — so A3 is not
optional: the re-derive path moving the counter is what proves A1's zero is a
real zero and not a dead recorder.

⛔ Not the parity comparator, not the fold-diff endpoint.

## RED→GREEN control

Plant a model call inside the replay path — e.g. have the fold re-invoke on a
cache miss. **Expected RED:** A1 fails, `slm_model_calls_total` moves during
replay.

Second plant, for A4: hard-code the visibility plan to `bounded` and assert the
read still behaves as `strong`; if the assertion cannot fail, it is not measuring
the tier.

## Rollback

`NOETL_SLM_REPLAY_MODE=replay` is the default and the safe mode. Re-derive is
opt-in per invocation.

## Exit criteria

A1–A4 green on kind, both RED controls demonstrated, and the M0.5 dependency
recorded with its measured behaviour rather than its expected one.
