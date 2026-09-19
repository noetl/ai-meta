---
spec: 2026-09-18-omni-multiregion-ehdb-M0
status: draft
created: 2026-09-18T19:20:00Z
owner: claude-opus-5 (ai-meta session 2026-09-18)
---

# M0 — The three pure resolvers, proven to be identity functions

Phase of [`spec.md`](spec.md). **Planning only.**

## Scope

Introduce `PlacementResolver`, `RouteResolver` and `VisibilityResolver` as pure
functions from (config, request descriptor) to plain data plans, and prove that
under today's configuration they emit exactly today's hard-coded behaviour.

**In scope:** the three resolvers, their plan types, their call sites, and the
mutation battery that proves the identity.
**Out of scope:** any non-default axis value. M0 ships the machinery with only
its degenerate arm reachable.

## Flags

**None.** M0 deliberately introduces no flag. A flag with only one legal value
is a representation that drifts; the resolvers simply have no non-default input
until M0.5/M1/M2 supply one.

## Touch-points

| File | Current state | Change |
| :-- | :-- | :-- |
| `ehdb/crates/ehdb-l0/src/engine.rs:296 open()`, `:316 open_replicated()` | **VERIFIED** — `open()` constructs `vec![ReplicaTarget::new("replica-0", substrate)]` | takes a `PlacementPlan`; the existing constructors become thin wrappers producing the degenerate plan |
| `ehdb/crates/ehdb-reference/src/affinity.rs` | **VERIFIED** — ownership fn; non-owner write refused with no side effect, non-owner read cold-loads read-only | supplies `RoutePlan::target` |
| `worker/src/ehdb/tier_query_source.rs:141 resolve()` | **VERIFIED** — returns `Resolution::{Local,Service,…}` (4 values) | becomes one input to `RouteResolver`; **its own semantics do not change in M0** |
| `worker/src/ehdb/tier_store.rs` read entry points | **VERIFIED** — `tier_service.rs` routes append(381)/append_batch(388)/read_execution(426)/scan(430) through `tier_store` | accept a `VisibilityPlan`; ignore it when degenerate |
| new — `ehdb-core` or a new `ehdb-placement` module | — | the three resolvers + plan types. **ASSUMED:** `ehdb-core` is the right home; it is the shared dep of both `ehdb-l0` and `ehdb-reference` (**VERIFIED** from both `Cargo.toml`s), which matters because C4 means both stacks need the types |

## Interfaces / data shapes

```rust
pub struct Locality { pub region: Option<String>, pub zone: Option<String> }

pub enum SurvivalGoal { Zone, Region }

pub struct PlacementPlan {              // resolved once, at engine OPEN
    pub replicas: Vec<ReplicaSpec>,     // ReplicaSpec = ReplicaTarget + Locality
    pub survive: SurvivalGoal,
}

pub enum RouteTarget { Owner, Replica(String) }

pub struct RoutePlan {                  // resolved per REQUEST
    pub target: RouteTarget,
    pub may_follower_read: bool,
}

pub struct VisibilityPlan {             // resolved per READ
    pub floor_hlc: Option<u64>,
    pub require_closed_ts: Option<u64>,
}
```

⛔ **The invariant this phase establishes, and every later phase inherits:**
*no axis may introduce a branch inside a tier driver.* Drivers consume plans;
they never read an axis, an env var or a locality.

## Entry criteria

None. M0 is first.

## Exit criteria

- [ ] E1 — All three resolvers exist and are constructed on every path that
      previously hard-coded the value.
- [ ] E2 — Under default config the plans are **equal to today's hard-coded
      values**: `replicas == [replica-0]`, `survive == Zone`,
      `target == Owner`, `may_follower_read == false`,
      `floor_hlc == None`, `require_closed_ts == None`.
- [ ] E3 — **Zero on-disk byte changes.** Proven by a differential over a fixed
      population: N appends before and after, files compared byte-for-byte.
      Publish N.
- [ ] E4 — Mutation battery green-baseline + planted defect (below).
- [ ] E5 — No new metric (M0 changes no behaviour, so there is nothing to
      observe; adding one would be a metric that can only read 0).

## Proof / verification

**Green baseline first.** Confirm the target test suite passes *before* planting
anything; a red baseline makes every mutant read CAUGHT.

| # | Planted defect | Must go RED in |
| :-- | :-- | :-- |
| 1 | `PlacementResolver` default arm returns `survive: Region` | the placement identity test |
| 2 | `PlacementResolver` default arm returns an empty `replicas` vec | engine-open test (`engine.rs:329` already refuses empty — so this mutant proves the test reaches the refusal, not just the resolver) |
| 3 | `RouteResolver` default arm returns `may_follower_read: true` | the route identity test |
| 4 | `VisibilityResolver` default arm returns `require_closed_ts: Some(0)` | the visibility identity test |
| 5 | **Positive control** — a resolver returns today's value via a *different* code path | must stay GREEN; if it goes red the battery is testing implementation, not behaviour |

Report as `mutants_planted=5 caught=N`. ⚠ Do **not** grep `'^error'` to
classify a mutant run: cargo prints `error: test failed` for a *caught* mutant,
which a naive grep counts as a compile error. This program misreported 6
catches that way. Classify on the test harness's own exit status.

⛔ Forbidden instruments: cross-store parity comparator;
`/api/ehdb/projection-fold/diff/{id}`. Neither is on this path and both carry
open asymmetries.

## Blast radius

Compile-time only. No behaviour, no bytes, no config. The largest real risk is
an **incomplete conversion** — a call site that still hard-codes a value and so
silently ignores its plan. E1 must be checked by enumerating call sites and
publishing the count, not by grepping for the type name.

## Rollback

Revert the commit. Nothing persisted, nothing flagged.

## Notes

**VERIFIED** unless marked. The one **ASSUMED** item is the home crate for the
resolver types (`ehdb-core`); resolve it by reading both dependency graphs
before starting, since C4 means the types must be visible to `ehdb-l0` *and*
`ehdb-reference`.
