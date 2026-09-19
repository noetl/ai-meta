---
spec: 2026-09-18-omni-multiregion-ehdb-M5
status: draft
created: 2026-09-18T19:20:00Z
owner: claude-opus-5 (ai-meta session 2026-09-18)
---

# M5 — Fencing `Enforce` + a real `LeaseStore` — **the gate**

Phase of [`spec.md`](spec.md). **Planning only.**
This is the existing **stage 2** from
[`FENCING-SUBSTRATE-BUILD-HANDOVER.md`](../../../loops/active/2026-09-11-ehdb-resilient-core-phases/handover/FENCING-SUBSTRATE-BUILD-HANDOVER.md),
unchanged in scope. This spec explains why everything to its right waits, and
does not re-scope it.

## Scope

Make single-writer a **mutual-exclusion primitive** rather than an
orchestration preference, and make the store **refuse** a stale epoch.

## Why this is the gate

**VERIFIED**, `ehdb-reference/src/election.rs` header:

> *"Single-writer per shard rested entirely on `StatefulSet replicas: 1` — an
> **orchestration preference, not a mutual-exclusion primitive**. A partitioned
> node whose kubelet is unreachable shows as `Terminating` while its process
> keeps appending, and Kubernetes may schedule a replacement during that
> window."*
>
> *"⚠⚠ Not prospective: the event-log tier has been `primary` and serving on
> prod since 2026-08-13, so the tier most dependent on single-writer ordering
> is the one already running without enforcement."*

C2 (gaplessness depends on one writer) means **every** multi-region phase is
unsafe until this lands.

## Flags

| Flag | Env var | Values | Default |
| :-- | :-- | :-- | :-- |
| fencing | `NOETL_EHDB_FENCING` | `shadow` \| `enforce` | `shadow` — **already exists** (**VERIFIED**, read by `worker/src/ehdb/metrics_server.rs:165-171` via `FencingSetting::from_env` + `FENCING_METRICS`) |
| election | `NOETL_EHDB_ELECTION` | `off` \| `observe` \| `authoritative` | `off` |

Two flags: the token issuer and the refuser are independent, and
`election.rs` is explicit that *"a Lease elects; it does not fence… Both are
required; neither is sufficient."*

## Touch-points

| File | Current | Change |
| :-- | :-- | :-- |
| `ehdb-reference/src/election.rs` (398) | **VERIFIED** — state machine implemented and proven against a `LeaseStore` with real CAS; `LeaseRecord{holder,transitions,renewed_at_millis,duration_secs,version}`; `DEFAULT_LEASE_DURATION_SECS = 15`, `DEFAULT_RENEW_INTERVAL_SECS = 5` | add the K8s adapter behind the existing `LeaseStore` trait |
| `ehdb-reference/src/fencing.rs` (404) | **VERIFIED** — Invariant F; `FencingMode::{Shadow,Enforce}`; `STALE_EPOCH_PREFIX = "stale_epoch"` | promote `Enforce` |
| ⭐ the **per-shard fencing marker** | **VERIFIED** — the epoch lives in a per-shard marker, **not** the frame header, because `FRAME_HEADER_LEN` is a fixed 12 bytes shared byte-identically with `durable_eventlog.rs` | **no format break, no segment-key migration.** The docs saying otherwise are stale |
| `Cargo.toml` + `crates/*/Cargo.toml` | **VERIFIED** — `grep -l 'kube\|k8s-openapi'` returns **nothing** | add the dependency (owner-approved) |
| RBAC | `docs/spec/lease-election-k8s-binding.md` has an *"RBAC — owner-run"* section | grant on `coordination.k8s.io/leases` — **owner-run, not agent-run** |
| tests | `lease_election.rs`, `fencing_shadow.rs`, `election_drives_fencing.rs` — **VERIFIED** present | extend |

## Interfaces / data shapes

No new type. The K8s mapping is already specified: `metadata.resourceVersion` →
`LeaseRecord::version`, `spec.leaseTransitions` → `LeaseRecord::transitions`,
`spec.holderIdentity` → `holder`. **VERIFIED** from `election.rs`.

⚠ `LeaseRecord::is_expired` compares `now_millis` on **the caller's clock**
(**VERIFIED**, `election.rs`). A paused holder can believe it still holds an
expired lease — which is *why* Invariant F is required and the lease alone is
not sufficient. Do not "fix" this with the M2 HLC: the fencing epoch must not
acquire a clock dependency.

## Entry criteria

- [ ] M0, M0.5, M1, M2, M2a, M3, M4 exit.

## Exit criteria

- [ ] E1 — A Kubernetes `LeaseStore` adapter exists, with RBAC granted.
- [ ] E2 — Election is **authoritative**: exclusion no longer rests on
      `replicas: 1`.
- [ ] E3 — In kind, a deliberately stale-epoch write is **refused**, with
      `stale_epoch` in the logs.
- [ ] E4 — `ehdb_fencing_refused_total{mode}` pinned at 0 for **both** modes,
      unconditionally.
- [ ] E5 — `shadow` remains byte-identical to today's write path.
- [ ] E6 — Epoch monotonicity survives a holder change (`transitions` strictly
      increases), proven by a test that fails when the CAS is bypassed.

## Proof / verification

| # | Planted defect | Must go RED in |
| :-- | :-- | :-- |
| 1 | `Enforce` accepts an equal-epoch write | E3 |
| 2 | `Enforce` accepts a **lower** epoch | E3 |
| 3 | the adapter maps `metadata.generation` instead of `resourceVersion` | the CAS test — a wrong-field CAS succeeds on races it must lose |
| 4 | the writer checks its own epoch and then writes (two calls) | the race test — `fencing.rs` is explicit that *"the store must refuse, not be asked"* |
| 5 | `shadow` refuses | E5 |
| 6 | **Positive control** — two writers, both believing they own the shard | must produce a refusal; if both succeed the enforcement is not on the path |

⛔ Forbidden instruments: cross-store parity comparator;
`/api/ehdb/projection-fold/diff/{id}`.

## Blast radius

⚠⚠ **Highest in the program.** The first thing that can refuse a production
write, on a tier that is already `primary`. Sequence: `shadow` in prod with the
counter observed → kind `enforce` with a planted stale writer → owner-gated
prod promotion.

⚠ Rolling `cmdbus-writer` loses in-flight executions (**VERIFIED**, seen three
times). Drain or quiesce.

## Rollback

`NOETL_EHDB_FENCING` → `shadow` — the store counts and logs, writes succeed.
`NOETL_EHDB_ELECTION` → `observe`. No redeploy needed for the mode itself.
