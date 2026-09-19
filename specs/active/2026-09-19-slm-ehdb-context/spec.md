---
spec: 2026-09-19-slm-ehdb-context
status: draft
created: 2026-09-19T00:00:00Z
owner: claude-opus-5 (ai-meta session 2026-09-19)
---

# SLM execution context on EHDB — umbrella spec

**Planning only. No prod change, no running config touched, nothing merged to
`main`.** Design source:
[`SLM-EHDB-CONTEXT-PLAN.md`](../../../loops/active/2026-09-11-ehdb-resilient-core-phases/handover/SLM-EHDB-CONTEXT-PLAN.md).

One spec per phase lives beside this one:

| Phase | Spec | Gating flag | Default |
| :-- | :-- | :-- | :-- |
| S0 | [`S0-envelope-compat.md`](S0-envelope-compat.md) | *(none — identity proof)* | — |
| S1 | [`S1-context-events.md`](S1-context-events.md) | `NOETL_SLM_CONTEXT_EVENTS` | `off` |
| S2 | [`S2-fold.md`](S2-fold.md) | `NOETL_SLM_CONTEXT_FOLD` | `off` |
| S3 | [`S3-stepgen-gate.md`](S3-stepgen-gate.md) | `NOETL_SLM_STEPGEN` | `off` |
| S4 | [`S4-replay.md`](S4-replay.md) | `NOETL_SLM_REPLAY_MODE` | `replay` |
| S5 | [`S5-compaction.md`](S5-compaction.md) | `NOETL_SLM_COMPACTION` | `off` |
| S6 | [`S6-gemma4-serving.md`](S6-gemma4-serving.md) | `NOETL_SLM_MODEL_REF` | unset |

## Implementation status (2026-09-19)

⛔ **Nothing merged. Kind/test only. No prod change.**

| Phase | State | Where |
| :-- | :-- | :-- |
| S0 | ✅ **met** | `noetl/ehdb` `feat/slm-context-s0-frame-invariants` @ `bdf9b5a` — 14 tests |
| S1 | ◐ types landed; emission pending | `noetl/ehdb` `feat/slm-context-s1-s2-events-fold` @ `9a293da` — 6 tests |
| S2 | ◐ fold landed; shadow-compare pending | same commit — 13 tests |
| S3 | ◐ **propose-only met**; execute-mode is the owner gate | `noetl/ehdb` `feat/slm-context-s3-propose-gate` @ `a89c4e5` — 27 tests |
| S4–S6 | not started | — |

S1–S3 landed as the crate `ehdb-slm-context`: types, one pure fold, and a pure
admission gate. **Inert by construction** — nothing calls it, and the gate has
no execution path at all. Forks settled 2026-09-19: **F2 = catalog entry** under
a dedicated prefix; **F4 = `noop` alone**, with `python` **denied outright** (terminal, not
approvable) and `http` excluded because its URL permits exfiltration and SSRF
regardless of method — execution remains owner-gated.

⏸ **Stopped at the owner gate.** The remaining work is flipping execute-mode on,
which needs the owner's confirm, `DslValidator` implemented in `noetl-server`
over its two `pub` parser fns, the register→call path wired, and ⚠ a **tagged
`ehdb` release** — the server pins ehdb by tag, so it cannot consume a branch.

## Problem

noetl can route between models (`diagnose_execution.yaml:479–493`, **VERIFIED**)
but cannot accumulate the context of an AI-driven run as platform state, and
cannot let a model propose work under provenance and a gate. AI execution context
lives in generic event payloads and per-step Python parsing; there is no fold
that assembles the next prompt, and no schema gate between "the model emitted a
step" and "a worker ran it" — because the model cannot emit a step at all.

## Goals

- Make AI execution context an **append-only event stream on D1** plus a
  **deterministic fold** into a working context — reusing D1's declared access
  pattern, adding no dataset and no index.
- Let a model **propose** a step spec that is schema-validated, policy-gated,
  budget-bounded and provenance-tracked before anything executes.
- Give an AI run a **replay guarantee that does not re-invoke the model**, and
  name the weaker "re-derive" mode separately.
- Serve **Gemma 4 locally** through the existing `tool.kind: mcp` seam as a
  pointer swap, never a new tool kind.

## Non-Goals

- Training, fine-tuning, evaluating or packaging a model — that is
  `docs/rfc/domain-slm-platform.md`; this umbrella *consumes* its G3/G5 and
  re-specifies nothing.
- A new tool kind, a new EHDB dataset (D11), or a new execution primitive.
- Making sampled completions reproducible. See the plan §8.2 — the design states
  the limit rather than implying the stronger claim.
- User-document RAG. D6 use here is platform SLM context only; the layered RFC's
  *"never wire a playbook user-document ingest to `rag::ingest`"* bound holds.
- Re-scoping the in-flight stage-1 / `digest_mismatch` track.

## Constraints

Inherited, and every phase is downstream of them:

- **C1** — EHDB has no consensus and will not grow one (`ehdb-l0/src/lib.rs:85`).
- **C2** — ordering is leaderful per shard (`ehdb-l0/src/engine.rs:712`).
- **C3** — `FRAME_HEADER_LEN` is a fixed 12 bytes; new fields go in the record
  **body** as `Option<T>` + `skip_serializing_if`. **Every event field in S1 is
  body-only.**
- **C4** — the `primary`-serving event-log tier runs on
  `ehdb-reference::LocalReferenceEventLogDriver`, not `ehdb-l0`; it has no seal,
  no parts, no replication. **Bounded-staleness reads are inert on the tier until
  M0.5.**
- **C5** — `global_sequence` is per-engine, not a global order. The SLM fold is
  scoped to one `execution_id` on one engine and must not assume more.

⛔ **Forbidden instruments.** The cross-store parity comparator and
`/api/ehdb/projection-fold/diff/{id}` are forbidden as proof instruments while
stage-1 `digest_mismatch` is open. No spec here may use them; each names its own.

## Acceptance Criteria

- **AC1** — with every flag at its default, an existing noetl execution emits a
  byte-identical event stream to today. Proven by S0's mutation battery.
- **AC2** — S1's six event types are additive: a reader built before them parses
  a log containing them without error.
- **AC3** — the fold is deterministic: the same event prefix yields the same
  `WorkingContext` across processes and runs.
- **AC4** — no proposed step reaches a worker without a `slm.step.admitted`
  event, and every rejection is counted.
- **AC5** — replay of an AI run issues **zero** model calls, proven by a counter
  that is non-zero on the re-derive path.
- **AC6** — the generate→execute loop terminates under all three bounds, each
  proven by a planted defect that makes it not terminate.
- **AC7** — swapping `gemma3:4b` for a Gemma 4 variant is a config change with no
  code diff.

## Verification Plan

Each phase carries its own instrument and a **RED→GREEN control with a planted
defect**. A phase is not done because its check passed; it is done when the check
has been *made to fail* on purpose and then passes. The recurring defect class in
this program is a mechanism that exists and cannot fire, and existence is what a
naive grep measures.

Every phase validates on **kind** before any prod consideration, per
`agents/rules/deployment-validation.md`. No phase in this umbrella proposes a
prod change.

## Open Questions

Tracked as F1–F8 in the plan's §14, each with a recommended default. None is
blocking for S0–S2; **F2 and F4 must be settled before S3 implements**, because
they determine what a generated step may be and may do.

## Linked Issues

None yet — this umbrella is design-only and unmerged. A future session opening
tracked issues should follow `agents/rules/issue-tracking.md` and cite this spec
path in each issue's `## Pointers`.
