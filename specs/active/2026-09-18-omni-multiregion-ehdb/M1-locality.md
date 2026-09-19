---
spec: 2026-09-18-omni-multiregion-ehdb-M1
status: draft
created: 2026-09-18T19:20:00Z
owner: claude-opus-5 (ai-meta session 2026-09-18)
---

# M1 — Locality metadata, recorded and enforced nowhere

Phase of [`spec.md`](spec.md). **Planning only.**

## Scope

Give a replica a **typed** locality (region, zone), record it on
`ReplicaTarget` and in the manifest's `ReplicaLocation`, and enforce nothing
with it. M1 makes placement *observable*; M4 makes it *refusable*.

⚠ **Do not route on the existing `region=` key segment.** **VERIFIED:**
`region` already appears inside KV / object logical keys
(`noetl/env=…/region=us-central1/cell=…/shard=s0042/tenant=…` —
`ehdb-reference/src/object.rs:11,1209,1491`; `kv.rs:1770`; `vector.rs:1643`).
It is a **naming convention inside an opaque key** that nothing parses — the
key is addressed through a SHA-256 subject digest (`object.rs:40-56`). Treating
it as existing multi-region support is the exact error this program keeps
making. Those key strings stay untouched.

## Flags

| Flag | Env var | Values | Default |
| :-- | :-- | :-- | :-- |
| locality | `NOETL_EHDB_LOCALITY` | `region=<r>,zone=<z>` | unset |

Unset ⇒ `Locality { region: None, zone: None }`, which resolves to
`FailureDomain::Undeclared` semantics: **fails closed**. **VERIFIED** —
`ehdb-l0/src/failure_domain.rs` treats `Undeclared` as *"its own unique domain
per call, so an undeclared substrate is never silently assumed to be
independent"*.

## Touch-points

| File | Current | Change |
| :-- | :-- | :-- |
| `ehdb-l0/src/engine.rs:230 ReplicaTarget` | `{ id, substrate }` — **VERIFIED** | add `locality: Locality` |
| `ehdb-l0/src/catalog.rs ReplicaLocation` | records where a copy lives — **VERIFIED** | add optional locality |
| `ehdb-l0/src/failure_domain.rs` | `FailureDomain::{LocalDevice{device_id,root},Remote{provider,bucket},Ephemeral,Undeclared}` + `validate_replica_domains` — **VERIFIED** | **read** locality; behaviour unchanged in M1 |
| `ehdb-l0/src/engine.rs:111 require_distinct_domains: bool` | **VERIFIED** | untouched in M1 (M4 widens it) |
| D8 `ehdb-l0/src/runtime.rs:53 RuntimeOp.contract` | free-form descriptor string — **VERIFIED** | carry the node's locality here. **No schema change needed** |
| `ehdb-reference/src/election.rs LeaseRecord.holder` | identity string — **VERIFIED** | carry the holder's region. **No schema change needed** |

## Interfaces / data shapes

```rust
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Locality {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub region: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub zone: Option<String>,
}
```

`Option` + `skip_serializing_if` is mandatory, not stylistic: a replica with no
locality must serialise **byte-identically to today** so a rollback binary reads
every manifest written while the flag is unset. **VERIFIED precedent** —
`ehdb-l0/src/dataset.rs:190-198` says exactly this about `event_id`.

## The `deny_unknown_fields` audit — with its denominator

⛔ **Gate: this audit must complete before any field is added.**

**VERIFIED:** `grep -rc 'deny_unknown_fields' crates --include='*.rs'` sums to
**151 occurrences** across `ehdb/crates`. Two have already been removed
deliberately, each recorded as *"a migration step in its own right"*:
`EventRecord` (`dataset.rs:154`) and `EventLogAppendOutcome`
(`ehdb-reference/src/eventlog.rs:142`).

The audit is **per struct, not per workspace** — do not generalise from those
two. Deliverable: a table of every struct on the serialisation path of a
manifest or a `ReplicaLocation`, with its `deny_unknown_fields` status, and the
count of structs examined. A finding of "0 problems" is only believable
alongside "examined N structs".

**The expand-first sequence is mandatory and ordered:**

1. Release A — tolerate the unknown field. **Deploy everywhere.**
2. Release B — write the field.

⚠ *Merged is not deployed.* A rollback across a B-without-A boundary makes the
older binary **error** on a manifest it must read, on a tier serving `primary`.

## Entry criteria

- [ ] M0 exit.
- [ ] **M0.5 exit** — otherwise M1 is inert on the tier (C4).

## Exit criteria

- [ ] E1 — `Locality` present on `ReplicaTarget` and in `ReplicaLocation`.
- [ ] E2 — Unset flag ⇒ manifests serialise **byte-identically** to today, over
      a fixed population. Publish the population.
- [ ] E3 — A manifest written with a locality is read **without error** by a
      binary built from the previous release (the expand-first check, run
      explicitly — not inferred from the `Option` type).
- [ ] E4 — `validate_replica_domains` behaviour is **bit-identical**: same
      accept/refuse verdict on the same inputs, with and without locality.
- [ ] E5 — `ehdb_replica_locality_info{replica,region,zone}` gauge, always 1.
      Emitted for **every** replica including localityless ones (label value
      `""`), so absence means "no such replica", never "no locality".

## Proof / verification

| # | Planted defect | Must go RED in |
| :-- | :-- | :-- |
| 1 | `Locality` serialises `null` instead of being skipped when empty | E2 byte-identity |
| 2 | `validate_replica_domains` starts consulting locality | E4 bit-identity |
| 3 | an unset `NOETL_EHDB_LOCALITY` yields `region: Some("")` rather than `None` | E2 + the Undeclared-fails-closed test |
| 4 | the metric is emitted only when a locality is set | E5 (this is the absent-is-not-zero class) |
| 5 | **Positive control** — old binary reads a manifest with a genuinely unknown field | must go RED if `deny_unknown_fields` is still on that struct; that is the audit working |

⛔ Forbidden instruments: cross-store parity comparator;
`/api/ehdb/projection-fold/diff/{id}`.

## Blast radius

Manifest bytes grow by a small optional field. Nothing reads it. The real risk
is the expand-first ordering (above), not the field.

## Rollback

Unset the flag. New manifests serialise byte-identically again; manifests
already carrying a locality remain readable because tolerance shipped first.
