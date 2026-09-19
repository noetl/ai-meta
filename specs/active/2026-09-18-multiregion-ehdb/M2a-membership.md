---
spec: 2026-09-18-multiregion-ehdb-M2a
status: draft
created: 2026-09-18T19:20:00Z
owner: claude-opus-5 (ai-meta session 2026-09-18)
---

# M2a — D8 / gossip adoption: make membership *reached*, not merely present

Phase of [`spec.md`](spec.md). **Planning only.**
Runs in parallel with M0.5/M1. **Prerequisite for M2 and M6.**

## Scope

Give D8 `RuntimeDataset` a real consumer and real tests, and bind
`ehdb-gossip` to a socket **in kind only**. This is an **adoption** plan, not a
construction plan — both components are already written.

## Why this is a phase and not a footnote

**VERIFIED:**

- `ehdb-l0/src/runtime.rs` (742 lines) ships D8 with register / heartbeat /
  deregister / `get` / `list_live` / `list_live_since(min_heartbeat)` / `open` /
  `cold_load` / `flush_and_wait`, and liveness as a **wall-clock-free
  predicate** over a monotone per-worker counter.
- `docs/rfc/ehdb-topology-membership.md` §0 measured **0 consumers** across
  server + worker + gateway (control: `D1EventLog` 15) and **0 tests**.
- `ehdb-gossip` (599 LOC, 4 files) adopts **foca v2** and declares itself
  **INERT**: *"no socket, no runtime and no bring-up"*, with `GossipOrigin`
  deliberately unconstructible without a verifier.

M2's fail-closed clock-offset halt needs a **peer set**. M6's routing needs a
**membership view**. Neither exists as a reachable thing today. ⚠ *"Does it
exist" and "does it work" are independent questions* — three components in this
program were found implemented and never wired.

## Flags

| Flag | Env var | Values | Default |
| :-- | :-- | :-- | :-- |
| membership | `NOETL_EHDB_MEMBERSHIP` | `off` \| `d8` \| `gossip` | `off` |

`d8` = write/read D8 only (no network). `gossip` = additionally bind foca.
**`gossip` is kind-only in this phase**; promotion to prod is owner-gated and
out of scope.

## Touch-points

| File | Change |
| :-- | :-- |
| `ehdb-l0/src/runtime.rs` | unchanged — it is the thing being adopted |
| `ehdb-gossip/src/sink.rs MembershipSink` | the notification→D8 mapping; wire it |
| `ehdb-gossip/src/origin.rs GossipOrigin`, `MembershipVerifier` | supply a real verifier. ⚠ It is unconstructible without one **by design** — do not weaken that to get a bring-up working |
| `ehdb-gossip/src/identity.rs ShardIdentity` | carry `Locality` from M1 if M1 has landed; otherwise leave the field absent |
| worker bring-up (`event_bus.rs` / `command_bus.rs` region) | register + heartbeat on the existing tick |

## Interfaces / data shapes

No schema change. `RuntimeOp.contract` is already a free-form descriptor
(**VERIFIED**, `runtime.rs:53`) and carries the pool / arch / capacity string
today; locality rides there.

## Entry criteria

None beyond a green tree. May run concurrently with M0.5/M1.

## Exit criteria

- [ ] E1 — D8 has **≥ 1 real consumer** and **≥ 1 test per surface**
      (register, heartbeat, deregister, `list_live_since`). Publish the surface
      count covered against the surface count that exists.
- [ ] E2 — `list_live_since` evicts a stale node in a test that **fails when the
      watermark advance is removed**.
- [ ] E3 — foca bound in kind; a killed pod is observed as a membership
      transition **and** that transition lands in D8.
- [ ] E4 — Prod remains `off`. Verified by the manifest carrying no
      `NOETL_EHDB_MEMBERSHIP`.
- [ ] E5 — `ehdb_membership_transitions_total{kind}` pinned at 0 for **every**
      value of `kind` (join, leave, suspect, down), unconditionally — not inside
      the `gossip` branch.

## Proof / verification

| # | Planted defect | Must go RED in |
| :-- | :-- | :-- |
| 1 | `heartbeat` does not increment the monotone counter | E2 |
| 2 | `list_live_since` ignores its watermark argument | E2 |
| 3 | the sink drops a `Down` notification instead of appending it | E3 |
| 4 | metric family registered but never touched for `suspect` | E5 — ⚠ `Registry::gather` **prunes families with no children**, so a labelled metric is *absent*, not zero, until it fires. The prod gateway once served a 200 with **zero bytes** for this reason |
| 5 | **Positive control** — a test asserting a node is live *after* it was deregistered | must go RED first run |

⚠ A test with a doc comment between `#[test]` and the fn **silently never
runs** — the attribute rebinds to the next item. Two such tests were found in
this program. Assert the battery's own denominator: `tests_run=N`.

⛔ Forbidden instruments: cross-store parity comparator;
`/api/ehdb/projection-fold/diff/{id}`.

## Blast radius

`off` is today. `d8` adds appends to a dataset nothing reads. `gossip` opens a
socket — **kind only** in this phase.

## Rollback

Flag → `off`. D8 records already written are inert.
