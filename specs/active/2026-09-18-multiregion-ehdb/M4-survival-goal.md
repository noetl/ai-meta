---
spec: 2026-09-18-multiregion-ehdb-M4
status: draft
created: 2026-09-18T19:20:00Z
owner: claude-opus-5 (ai-meta session 2026-09-18)
---

# M4 — Survival-goal placement (ZONE / REGION)

Phase of [`spec.md`](spec.md). **Planning only.**

## Scope

Widen `require_distinct_domains: bool` into a survival goal, and make a replica
set that cannot meet the goal **refusable**. M1 recorded locality; M4 enforces
on it.

## Flags

| Flag | Env var | Values | Default |
| :-- | :-- | :-- | :-- |
| survival goal | `NOETL_EHDB_SURVIVAL_GOAL` | `zone` \| `region` | `zone` |
| enforcement | `NOETL_EHDB_PLACEMENT_ENFORCE` | `shadow` \| `enforce` | `shadow` |

Two flags deliberately. `shadow` reports violations and refuses nothing —
mirroring the `FencingMode::Shadow` precedent (**VERIFIED**,
`ehdb-reference/src/fencing.rs`: *"a stale epoch is counted and logged, and the
write still succeeds"*). ⚠ M4 is the first phase that can **fail an engine
open**, so it must be observed before it is armed.

## Touch-points

| File | Current | Change |
| :-- | :-- | :-- |
| `ehdb-l0/src/engine.rs:111 require_distinct_domains: bool` | **VERIFIED** | → `survive: SurvivalGoal`. `true` maps exactly to `Zone` |
| `ehdb-l0/src/failure_domain.rs validate_replica_domains` | **VERIFIED** — *"refuses a replica set whose members share one"*; ⚠ *"Only consulted for a set of **two or more** replicas"* (`engine.rs:108`) | consult `Locality.region` under `Region` |
| `ehdb-l0/src/engine.rs:338-342` format-version check | **VERIFIED** — checked on **every** replica, not just the first | pattern to copy for the placement check |
| `PlacementResolver` (M0) | degenerate | first non-default arm |
| `ehdb-l0/src/substrate.rs DurableSubstrate::failure_domain()` | **VERIFIED** — defaults to `Undeclared` so existing impls keep compiling | needs ≥1 impl returning `Remote{provider,bucket}` |

## Interfaces / data shapes

```rust
pub enum SurvivalGoal { Zone, Region }

pub struct PlacementViolation {
    pub goal: SurvivalGoal,
    pub replicas: Vec<String>,          // ids
    pub shared: FailureDomain,          // or shared region
}
```

## The finding this phase exists to surface

⭐ **VERIFIED**, `ehdb-l0/src/failure_domain.rs` module doc — in production:

```
NOETL_EVENT_BUS_WRITER_DIR   = /data/eventbus
NOETL_EHDB_TIER_SERVICE_DIR  = /data/eventbus/ehdb-tier
```

*"`/data/eventbus` is one PVC. The substrate copy lives in a subdirectory of the
same volume as the part it is a copy of… An RF of N over one domain is an RF of
1 wearing a larger number."* And `FailureDomain::for_path` compares **device
id, not path** — *"a path comparison would have called it independent."*

M4 makes that observable. It must run in `shadow` first for exactly this
reason: arming it against the current layout would refuse the open.

## Entry criteria

- [ ] M0.5 exit (C4 — otherwise inert on the tier).
- [ ] M1 exit.
- [ ] ≥ 1 `DurableSubstrate` impl declaring `FailureDomain::Remote`.

## Exit criteria

- [ ] E1 — `zone` + `shadow` is behaviourally identical to today's
      `require_distinct_domains: true`.
- [ ] E2 — Under `region` + `enforce`, `validate_replica_domains` **refuses** a
      replica set sharing a region — proven by a test that **fails when the
      check is removed**.
- [ ] E3 — A sealed part remains readable after one domain is made unreachable
      (kind: unmount or deny the path), **with a negative control** showing the
      test can detect the absence of the surviving copy.
- [ ] E4 — `ehdb_replica_placement_violations_total{goal}` pinned at 0 for both
      label values, **unconditionally** — not inside the `enforce` branch.
      (Precedent: server#315 pinned publish-skip reasons *inside*
      `if event_bus_mode.publishes_ehdb()`, leaving them absent on exactly the
      configuration whose reason someone would be reading.)
- [ ] E5 — A single-replica set is unaffected under both goals, matching
      `engine.rs:108`.

## Proof / verification

| # | Planted defect | Must go RED in |
| :-- | :-- | :-- |
| 1 | `validate_replica_domains` compares **paths** instead of device ids | E2 — this is the exact prod case |
| 2 | the region check is consulted only for the first replica | E2 (copy the `:338-342` every-replica pattern) |
| 3 | `enforce` behaves as `shadow` | E2 |
| 4 | `shadow` refuses (i.e. it is not actually shadow) | E1 |
| 5 | the violation metric is emitted only on violation | E4 — absent-is-not-zero |
| 6 | **Positive control** — the E3 domain-unreachable test run with **both** copies removed | must go RED; otherwise E3 is not reading the surviving copy |

⛔ Forbidden instruments: cross-store parity comparator;
`/api/ehdb/projection-fold/diff/{id}`.

## Blast radius

⚠ **Engine open can now refuse to start.** Deliberately placed after the
read-side phases and before anything that touches writes. `shadow` first,
always; promotion to `enforce` is owner-gated.

## Rollback

`NOETL_EHDB_PLACEMENT_ENFORCE` → `shadow`, then `NOETL_EHDB_SURVIVAL_GOAL` →
`zone`. Two levers, in that order — the enforcement flag is the faster one.
