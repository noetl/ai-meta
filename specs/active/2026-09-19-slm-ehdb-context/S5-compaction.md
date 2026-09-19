---
spec: 2026-09-19-slm-ehdb-context-S5
status: draft
created: 2026-09-19T00:00:00Z
owner: claude-opus-5 (ai-meta session 2026-09-19)
---

# S5 — Compaction as a fold op; move the fold to the projection engine

Phase of [`spec.md`](spec.md). **Planning only.** Depends on **S4**.

## Scope

Summarise a long context as a **fold operation that emits an event**, and move
the fold from the server (S2) to D3's projection engine.

**In scope:** `slm.context.summarised`, the token-budget trigger, the recursion
bound on summarisation, the D3 move.
**Out of scope:** the D6 vector tier — not deployed; see below.

## Flags

| Flag | Values | Default |
| :-- | :-- | :-- |
| `NOETL_SLM_COMPACTION` | `off` \| `on` | `off` |

## Compaction

When the fold exceeds its token budget it emits `slm.context.summarised`
carrying a summary and **the range of `source_event_ids` it replaces**. A later
fold may choose the summary or the detail.

⭐ **The originals are never deleted.** D1 is append-only; compaction derives,
it does not destroy. That is the same shape as every other read-model here, and
it is what keeps S4's replay guarantee intact — a replay can always choose the
detail.

⚠ **Summarisation is itself a model call.** It emits its own turn events and is
subject to the same budget. A compaction that can trigger compaction is
unbounded recursion; S5 bounds summarisation depth at **1** — a summary may not
be summarised in the same execution.

## The D3 move

S2 put the fold in the server reading D1, deliberately, because D3's EHDB
projection engine is **shadow, not authoritative**. S5 moves it when D3 is ready.

⚠ **This phase is gated on something outside this umbrella.** If D3's projection
engine is still shadow, S5 ships compaction **in the server fold** and leaves the
move to a later phase. That is a legitimate outcome and this spec says so rather
than blocking compaction on an unrelated cutover.

## The vector tier is not this phase

D6 (`(collection, point_id)`; upsert / top-k cosine / delete) exists in the fixed
dataset set and is **not deployed**. When it is, `fold()` gains an optional
retrieval arm.

⛔ **Bound, carried from the layered RFC and repeated because it is the one that
matters:** *"never wire a playbook user-document ingest to `rag::ingest`"*. D6
here is the **platform's own** SLM context only. A user's documents go to the
user's own vector store via connector. noetl/ai-meta#197 tracks the guard test;
S5 does not pre-empt it.

## Acceptance criteria

- **A1** — `off`: the fold behaves exactly as S2 left it.
- **A2** — `on`: crossing the token budget emits exactly one
  `slm.context.summarised` with a contiguous, non-overlapping source range.
- **A3** — the originals remain readable; a fold can reconstruct the
  pre-summary context.
- **A4** — summarisation depth is bounded at 1.
- **A5** — S4's replay still reproduces the same decisions with compaction on.

## Instrument

`slm_context_summarised_total`, `slm_context_tokens` histogram, and a
reconstruction check that folds both with and without summaries and compares
the admitted/rejected decision sets.

## RED→GREEN control

Plant an overlapping source range (summarise events 1–10 and 8–15).
**Expected RED:** A2 fails on the overlap check. Without this control, a
summariser that double-counts context looks identical to one that does not —
and double-counted context is how a budget silently stops bounding.

Second plant for A5: make the summary lossy in a decision-relevant way (drop the
`rejected` list) and confirm A5 fails.

## Rollback

Flag to `off`. Summary events already written are additive; a fold with
compaction off ignores them.

## Exit criteria

A1–A5 green on kind, both RED controls demonstrated, and the D3 move either done
or explicitly deferred with the reason recorded here.
