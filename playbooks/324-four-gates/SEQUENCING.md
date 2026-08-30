# Gate sequencing — the authoritative document

**Supersedes** the scattered notes in `README.md`, the per-issue comments, and
the handoff sections. Where they disagree, this is current.

**As of 2026-08-30.** Every state below was read from the running cluster, not
from manifests.

> ## ⛔ Nothing here is flipped. Every node is an owner decision.
> The event-log tier is **already `primary` and serving prod**, so these are not
> promotions — they are changes to a tier that is already load-bearing.

## Verified current state

| surface | where | value |
| :-- | :-- | :-- |
| event-log tier mode | worker pools (**not** server/writer) | **`primary`** |
| `NOETL_EHDB_EVENTLOG_BACKEND` | all four workloads | **unset** ⇒ `LocalReference` |
| `NOETL_EHDB_FENCING` | all four workloads | unset ⇒ not wrapped |
| `NOETL_EHDB_SEAL_MAX_AGE_MS` | writer | unset ⇒ no age trigger |
| `NOETL_EHDB_RECOVERY_SOURCE` | server | **`verify`** (folds + compares, serves nothing) |
| `NOETL_EHDB_TIER_QUERY_SOURCE` | server | unset |
| `NOETL_CATALOG_READ_SOURCE` | server | unset ⇒ ladder compares nothing |
| `NOETL_CATALOG_LOG` / `_SNAPSHOT` | server | `shadow` / `digest` — **already live** |
| `ehdb_replica_domains_observed` | writer scrape | **0** — the durable stack is never opened |

## The dependency DAG

```
 G0  observability                                        ✅ DONE, live
     ├── F4 durability window on :9102 and :9106
     └── D-3 alert policies declared (ops), NOT applied
          │
          │ (D-3 alerts are unusable until G1b — see edge ①)
          ▼
 G1a writer timer driving seal_aged_parts()   🔴 touches the live writer loop
     └─► G1b  NOETL_EHDB_SEAL_MAX_AGE_MS=5000
              └─► D-3 alerts become enable-able

 G-pre  NOETL_EHDB_EVENTLOG_BACKEND=durable_segment       🔴 STORAGE SWITCH
     │   (newly identified 2026-08-30 — the original plan did not name it)
     ├─────────────────────────────┐
     ▼                             ▼
 G3  election authoritative    G4  replica-set validation at open
     │  ⛔ blocked on the           ⛔ would FAIL at open on prod today
     │     kube dependency
     ▼
 G2  fencing shadow → enforce
     ⛔ enforce-before-G3 = OUTAGE (edge ②)

 Independent of the above:
 C1  catalog read-cutover   NOETL_CATALOG_READ_SOURCE=verify → tier
 R1  #307 tier-serve        NOETL_EHDB_RECOVERY_SOURCE=verify → tier
```

## ⛔ Do-not-cross edges

**① D-3 alerts before G1b = a pager that fires for an accepted condition.**
Without the age trigger a quiet shard's window is unbounded *by design*. The soak
measured the quiet and trickle arms at the **full 20 s run length, still
climbing** — they did not plateau. Three of the four declared policies would page
continuously; a silenced alert is worse than no alert. Only
`the durability window could not be sampled` is safe before G1b.

**② G2 `enforce` before G3 = outage, not degradation.** With no election every
writer's epoch is `0`. That is self-consistent and writes succeed — until one
node is elected and advances the marker, at which point **every un-elected writer
is refused**. Asserted in `ehdb/tests/election_drives_fencing.rs::
enforcing_before_any_election_fences_every_writer`, not merely documented.

**③ G4 before the layout is fixed = startup outage by construction.** Prod's
shared root is *inside* the writer's data dir on one PVC. Validation at open
would refuse to start. Order is forced: second substrate → repoint → validate.

**④ G-pre is itself a primary-tier storage change**, not an enablement step for
the two gates behind it. It changes which store serves an already-`primary`
event log.

## Per-node detail

### G-pre — `NOETL_EHDB_EVENTLOG_BACKEND=durable_segment` 🔴 NEW

| | |
| :-- | :-- |
| **changes** | which store backs the event-log tier: `LocalReference` → the durable-segment stack (affinity routing + shared-tier publish) |
| **why needed** | `build_durable_stack` is the *only* caller of the fencing decorator and the replica-domain observation. Unset, **G2 and G4 have no reachable code at all** |
| **verify-before** | `ehdb_replica_domains_observed 0` today confirms the stack is never opened. Kind-validate the durable path end-to-end first |
| **enable** | `kubectl -n noetl set env … NOETL_EHDB_EVENTLOG_BACKEND=durable_segment` |
| **verify-after** | `ehdb_replica_domains_observed 1`; append rate unchanged; `ehdb_l0_unreplicated_age_seconds` flat |
| **rollback** | `kubectl -n noetl set env … NOETL_EHDB_EVENTLOG_BACKEND-` |
| **blast radius** | 🔴 **high** — a storage-path switch on the tier that serves prod |

### G1a — the seal-age timer 🔴 live writer loop

| | |
| :-- | :-- |
| **changes** | adds a periodic `seal_aged_parts()` call to the writer loop; a **no-op while `seal_max_age` is unset** |
| **why needed** | `should_seal()` is consulted only on append, so the flag alone does nothing for an idle shard — the shard it exists to protect |
| **verify-before** | `ehdb_l0_unreplicated_age_seconds` present on `:9106` (it is) |
| **verify-after** | `seals` rate unchanged while the flag is unset |
| **rollback** | revert the image |
| **blast radius** | medium — touches the write loop, but inert until G1b |

### G1b — `NOETL_EHDB_SEAL_MAX_AGE_MS=5000`

| | |
| :-- | :-- |
| **changes** | parts seal on age; idle shards start reaching the substrate |
| **verify-before** | max unreplicated age over a soak **including an idle shard** |
| **verify-after** | max age ≤ ~2× the trigger; part count rise measured (soak: 4 → 10 seals) |
| **rollback** | `kubectl -n noetl set env … NOETL_EHDB_SEAL_MAX_AGE_MS-` |
| **blast radius** | low-medium — more, smaller parts; L0.3 compaction absorbs it |

### G3 — authoritative election ⛔ blocked

| | |
| :-- | :-- |
| **changes** | the writer refuses to append without a lease token |
| **blocked on** | the **HTTP/`kube` dependency decision** — no adapter exists |
| **verify-before** | a forced pod delete advances `leaseTransitions` by exactly 1 |
| **rollback** | revert to not requiring a token |
| **blast radius** | 🔴 **high** — makes API-server availability a dependency of the write path |

### G2 — fencing `shadow` → `enforce`

| | |
| :-- | :-- |
| **changes** | the store refuses writes from an epoch below the shard's highest |
| **verify-before** | ⚠ **two numbers**: `stale_observed_total == 0` **and** `writes_checked_total` climbing. A zero beside a flat checked-counter means unreached, not healthy |
| **rollback** | `kubectl -n noetl set env … NOETL_EHDB_FENCING-` |
| **blast radius** | 🔴 **high if sequenced wrong** (edge ②); low after G3 |

### G4 — replica-set validation at open

| | |
| :-- | :-- |
| **changes** | a replica set that does not spread failure domains makes the writer **fail to start** |
| **verify-before** | `ehdb_replica_domain_violations{kind}` all 0 — **requires G-pre to be evaluable at all** |
| **rollback** | revert the image |
| **blast radius** | 🔴 **startup outage today** (edge ③) |

### C1 — catalog read-cutover *(independent)*

`NOETL_CATALOG_READ_SOURCE`: unset → `verify` (compare, serve incumbent) →
`tier` (serve the fold). ⚠ While unset the ladder **compares nothing**, so there
is no accumulated evidence yet. `verify` is low-risk; `tier` changes what serves
catalog reads.

### R1 — #307 tier-serve *(independent)*

`NOETL_EHDB_RECOVERY_SOURCE`: `verify` (**current**) → `tier`. ⚠⚠ The in-path
verdict **cannot see tier-vs-Postgres divergence** — it materialises then refolds
from the same source and agrees with itself. Only the cross-store parity
comparator and the equivalence sweep can catch it, which is why this stays
parked.

## Recommended order

```
1. G1a → G1b → D-3 alerts        (independent; the cheapest real durability win)
2. C1 verify                      (independent; starts accumulating evidence)
3. kube dependency decision → G3  (unblocks G2)
4. G-pre  ⚠ storage switch, kind-validated first
5. G2 enforce
6. second substrate → repoint → G4
7. R1 tier-serve                  (needs the equivalence sweep, separate)
```

**Rationale.** Step 1 is independent of everything and closes the unbounded
window. Step 3 before step 5 is edge ②. Step 4 before steps 5–6 because nothing
in G2 or G4 is even *reachable* without it. Step 6 last because it is the only
one requiring new infrastructure.

⚠ Steps 4 and 5 could be swapped only by enabling fencing **shadow** at the same
time as G-pre, so the shadow period runs from the moment the code is reachable.
That is the recommended combination when G-pre is taken.

## What is NOT gated

Everything shipped so far: the F4 window (live), the fencing/election/domain code
(merged, default-off), the reachability guard, the soak harness, the alert
declarations (not applied). None changes a byte of behaviour at rest.
