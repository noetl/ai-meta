# Topology and membership — an EHDB projection, not an external service

**Design only. Nothing built, nothing on prod.**

Companion to [`ehdb-embedded-state.md`](ehdb-embedded-state.md) and
[`ehdb-packaging.md`](ehdb-packaging.md). Those settle *which shard owns a key*
and *how the engine is packaged*. This settles **where that shard's instance
is**, and how every instance learns it.

**Owner constraint (2026-09-08): the topology of NoETL resources lives in EHDB.
EHDB is self-sufficient — no external discovery service.** Consistent with the
no-external-coordination arc that deleted NATS.

**Decisions locked (owner, 2026-09-08):**

1. **Gossip transport is a LIBRARY, not hand-rolled.** Option B below is closed.
2. **Guiding principle — "self-sufficient" means no external DATABASE, not no
   dependencies.** Proven libraries are welcome and preferred; do not reinvent
   the wheel. Codified as [`agents/rules/self-sufficiency.md`](../../agents/rules/self-sufficiency.md).

Grounded in `ehdb@main`, `server@main`, prod 2026-09-08.

---

## 0. ⭐⭐ The headline: this design is already implemented, and unused

`ehdb-l0` has **D8 — `RuntimeDataset`** (`crates/ehdb-l0/src/runtime.rs`). Its
own module doc describes exactly the model the constraint asks for:

> *"Worker lifecycle with **register**, **heartbeat**, **deregister**, and
> **list-live** — over immutable parts. Modeled as an **append-only log** of
> `RuntimeOp`; a worker's current state is its latest op (**a fold** …). A
> monotonic per-worker `heartbeat` rides each op, so liveness is a
> **wall-clock-free predicate**"*

```rust
pub enum RuntimeEvent { Register, Heartbeat, Deregister }   // node-up, health-tick, node-down
```

Sort key `op_seq`; partition **and** index dimension `worker_id`, so a per-node
read touches exactly one node's history. Full surface already present:
`register` · `heartbeat` · `deregister` · `get` · `list_live` ·
`list_live_since(min_heartbeat)` · `open` · `cold_load` · `flush_and_wait`.

**Consumers across server + worker + gateway: 0** (control: `D1EventLog` 15).
**Tests: 0.**

> This is the third time in this program that the component the design needs was
> already written and never wired: the `ehdb-l0` projection engine (step 2), and
> now D8. The pattern is worth naming — **EHDB was built ahead of its
> consumers**, so "does it exist" and "does it work" are independent questions,
> and only the second one has ever been answered by shipping.

**Consequence for this design: it is an adoption plan, not a construction plan.**
And, exactly as with step 2, D8 must be *exercised before being trusted* — zero
consumers and zero tests means no evidence of either kind.

---

## 1. What exists today

### Address resolution is a string template

```rust
// server/src/affinity.rs:134
pub fn owner_base_url(&self, execution_id: i64) -> Option<String> {
    let template = self.peer_url_template.as_ref()?;      // NOETL_PEER_URL_TEMPLATE
    let owner = crate::sharding::shard_for(execution_id, self.shard.shard_count);
    Some(template.replace(SHARD_PLACEHOLDER, &owner.to_string()))
}
```

Shard index → substitute into a config string → DNS. **No liveness, no instance
identity beyond the index, no membership events.** A dead shard's URL resolves
exactly as a live one's; the failure surfaces only as a connection error at use —
which is why server#416's fail-closed change had to come first.

### ⚠ Membership exists, in Postgres, and is load-bearing

`noetl.runtime` carries `runtime_id / name / kind / uri / status / labels /
capabilities / capacity / heartbeat`, fed by
`POST /api/worker/pool/{register,deregister,heartbeat}` — and it is **read for
safety decisions**: both `nonconvergence_sweep.rs:266` and `orphan_sweep.rs:124`
do `SELECT name FROM noetl.runtime` for the `skipped_live` guard that stops a
sweep terminating work a live worker still holds.

> So the gap is not *"no membership"*. It is that membership lives in **the store
> this program is leaving**, and **routing never consults it**.

D8 is the EHDB-native twin of that table, already modelled as events.

### The quantified gap

| capability | today | after |
| :-- | :-- | :-- |
| shard → address | static template + DNS | D8 fold → instance address |
| instance identity | none (index only) | `worker_id` / instance name |
| liveness | `noetl.runtime.heartbeat`, centralised, not consulted by routing | `list_live_since(watermark)`, local, consulted |
| membership history | none | free — the log *is* the history |
| cross-cluster | none | remote D8 read, cached per relationship |

---

## 2. Topology as a native event-sourced projection

### It reuses the step-3 machinery *because it is the same engine*

D8 is `L0Engine<RuntimeDataset>`. `L0Engine<D: Dataset>` is generic — **10
datasets implement `Dataset` today**. So everything built in steps 2–3 applies
without adaptation:

| mechanism | shared with every other projection |
| :-- | :-- |
| **snapshot** | the manifest + immutable parts; `flush_and_wait`, `run_pending_merges` |
| **restore** | `cold_load` / `cold_load_replicated` — proven in step 2 to recover another instance's durable state |
| **cursor** | `cursor::load(substrate, shard)` / `advance(..)` from step 3, and `read_partition_after(shard, after_seq)` for the tail |
| **format gate** | `FORMAT_VERSION` refuses a mismatched layout at `open` |

**Recovery of the topology table is therefore the same three lines as recovery
of any projection:** load the cursor, read past it, fold. No bespoke membership
persistence, no separate snapshot format, no second recovery path to test.

And the audit trail is free: *"which node was alive at 03:14, and when did it
join"* is a range read over an append-only log that already exists, rather than a
question the current heartbeat column structurally cannot answer — it stores only
the latest timestamp.

### ⚠ One property to preserve deliberately

D8's liveness is **wall-clock-free**: `list_live_since(min_heartbeat)` takes a
watermark the caller advances on its own tick. That is a better primitive than
comparing `now()` to a stored timestamp, because it does not assume clock
agreement between the writer and the reader — and across regions that assumption
is exactly the one that breaks. Keep it; do not "simplify" it into a timestamp
comparison.

### Multi-cluster falls out of the keying

A cluster's topology is **its own D8 projection**. Then:

- **Local read** — fold your own cluster's D8. Complete, local, no network.
- **Remote read** — request the remote cluster's D8 *by key*: `list_live` for a
  bootstrap, or `get(instance_id)` for one relationship. It is an ordinary
  projection read over a key, not a new protocol.
- **Cache** — keep only the remote instances actually being routed to, refreshed
  by their health.

This is the LAN-pool / WAN-pool split (Consul's shape) expressed as *two
projections* rather than two membership protocols — which is why the constraint
"topology lives in EHDB" makes multi-cluster simpler rather than harder.

---

## 3. Self-sufficient means no external *service* — a wire protocol is still required

**The distinction that matters, stated plainly:**

> **"EHDB is self-sufficient" = no external discovery *service* — nothing to
> deploy, operate, quorum, or upgrade alongside NoETL. It does *not* mean no
> wire protocol.** Health has to physically travel from the node that observes it
> to the nodes that need it. EHDB is where that information *lives*; it is not
> how it *moves*.

Storage cannot substitute for transport. A node cannot learn that a peer died by
reading its own local log — someone must tell it.

### The two options, both self-sufficient by the definition above

**A — embeddable gossip library, feeding events into EHDB (recommended).**

A linked crate (`memberlist` / `foca` class, SWIM), in-process, peer-to-peer
among NoETL instances. It carries only *transport and failure detection*; every
membership transition it reports is appended to D8 as a `RuntimeOp`, and all
*state, history, recovery and query* stay in EHDB.

- **A library is not an external dependency in the operational sense** — it is a
  crate like `serde` or `tokio`, not a cluster to run. No Consul, no etcd, no
  extra pod, no quorum to maintain.
- **What it buys** is the part that is genuinely hard: SWIM's **indirect
  probing** — before declaring a peer dead, ask *k* other peers to probe it.
  That single mechanism distinguishes *"I cannot reach X"* from *"X is down"*,
  which a heartbeat table structurally cannot, and it is what makes conservative
  tuning affordable (§5).
- ⚠ **Honest cost:** a third-party crate on the routing path. It must be
  evaluated for maintenance status, transport auditability and dependency weight
  before adoption — chosen deliberately, not from a README.

**B — hand-roll SWIM inside EHDB.**

Fully self-contained, zero third-party gossip, the whole stack ours.

- ⚠ **The risk, stated without hedging:** a failure detector is a subtle,
  well-studied artefact. Suspicion timing, incarnation numbers to defeat stale
  refutations, anti-entropy, message compaction, piggyback budgets — each is a
  paper, and each **fails silently rather than loudly**. A hand-rolled detector
  that is 95% right produces false evictions under load, which is the failure
  mode with the worst blast radius here (§5).
- It is also the piece least aligned with this program's evidence: every
  component EHDB already built ahead of its consumers (the projection engine,
  D8) turned out to work — *but only once tested*. A hand-rolled failure
  detector's bugs appear under partition and load, which unit tests do not
  reproduce.

**DECIDED (owner, 2026-09-08): A — library for transport, EHDB for state.**
B is closed.

The decision follows [`self-sufficiency.md`](../../agents/rules/self-sufficiency.md)
exactly: the constraint forbids an external *service*, not a crate. A gossip
library compiles into the binary, versions with it, and has no runtime lifecycle
of its own — it is not the thing self-sufficiency exists to prevent. And a
failure detector is squarely in the "fails silently" category where that rule
says use the maintained implementation.

The specific crate recommendation is in §7.

### The split, drawn

```
   gossip library (in-process, peer-to-peer, fan-out to k peers — never broadcast)
        │  observes: node joined / suspected / confirmed dead
        ▼
   RuntimeOp appended to D8            ← the ONLY durable membership state
        │
        ├── fold → local topology table (a DNS-like map: instance → address)
        ├── snapshot / cold_load / cursor  ← step 2 + step 3 machinery, unchanged
        └── remote clusters read this projection by key, lazily, and cache
```

---

## 7. The crate recommendation — **foca**

Surveyed 2026-09-08 against crates.io and docs.rs, not recall.

| | **foca 2.0.0** | chitchat 0.13.0 | memberlist 0.8.5 | swim-rs 0.1.1 |
| :-- | :-- | :-- | :-- | :-- |
| last release | **2026-08-02** | 2026-08-06 | 2026-06-23 | 2024-10-07 |
| downloads | 210,509 | 201,441 | 39,133 | 2,323 |
| licence | MPL-2.0 | **MIT** | MPL-2.0 | Apache-2.0 |
| protocol | **SWIM + Inf. + Susp.** | Scuttlebutt + phi-accrual | SWIM (memberlist port) | SWIM |
| required deps | **2** (`bytes`, `rand`) | 11 (incl. `tokio`, `zstd`, `anyhow`) | 5 (+ its own sub-crates) | — |
| does its own I/O | **no** | yes (tokio) | yes (runtime-agnostic) | yes |
| `no_std` | **yes** (+ optional `std`) | no | no | no |

### Why foca

1. **It implements the property that decides this: SWIM with suspicion and
   indirect probing.** §6 argues the whole failure-detector trade resolves on
   being able to distinguish *"I cannot reach X"* from *"X is down"*. chitchat
   does **not** do this — it is Scuttlebutt state dissemination with a
   phi-accrual detector, which is a different (heartbeat-derived) family. That is
   the single disqualifying difference, not a preference.

2. **It does no I/O — "bring your own everything".** The caller owns the socket,
   the codec and the identity type. That is exactly the shape needed here: foca
   observes membership transitions and hands them back, and *we* append them to
   D8. A library that owns its own socket and runtime would have to be adapted
   into that flow; foca is already built for it.

3. **Its `Identity` is pluggable and can carry payload.** Its own docs give the
   example *"Want to attach extra crucial information (shard id, deployment
   version, etc)? Easy."* — which is literally this design: the membership
   message names the shard whose address is being announced, so the D8
   `contract` field is populated from the gossip identity directly.

4. **Two required dependencies.** `bytes` and `rand`. chitchat pulls 11
   including `tokio`, `zstd` and `anyhow`; memberlist pulls its own sub-crate
   family. For code on the routing path, that weight difference is a real
   security and audit consideration, not aesthetics.

5. **`no_std` + alloc** means it has no opinion about the server's runtime — it
   cannot contend with the storage/API threading model because it does not have
   one.

### The tradeoffs, honestly

- ⚠ **MPL-2.0**, not MIT. Weak, *file-level* copyleft: modifications to foca's
  own files must be published; linking it into NoETL does not affect NoETL's
  licence. Fine for use as-is; it means a fork carries an obligation. chitchat's
  MIT is genuinely more permissive and is the one point where it wins.
- ⚠ **"No I/O" means we write the transport.** Socket, retries, framing and the
  encryption/signing layer (§5) are ours. That is more code than a batteries-
  included crate — and it is also the only way to get the signed, authenticated
  membership §5 requires, since none of these crates provides it.
- ⚠ **Single-maintainer project.** Active (2.0.0 in Aug 2026, 100% documented,
  210k downloads) but not a foundation-backed effort. The mitigation is real:
  two required deps and no I/O means it is small enough to vendor or fork if it
  goes unmaintained — a property chitchat's 11-dep tokio-coupled surface does not
  have.
- ⚠ **chitchat is not wrong, it is a different tool.** If the requirement were
  "propagate arbitrary per-node key-value metadata cluster-wide", it would be the
  better pick. The requirement here is *failure detection*, and it is worth
  noting that Quickwit chose Scuttlebutt for state dissemination — the same split
  this design makes, with EHDB in the state role.

### What adoption would look like (not yet authorised)

```
foca (in-process, UDP, k-peer fan-out)
   └─ Notification: member up / suspected / down
        └─ RuntimeStore::{register, heartbeat, deregister}   ← D8, already tested
             └─ fold → topology table → address for a shard
```

✅ **Append-time validation has landed** ([ehdb#357](https://github.com/noetl/ehdb/pull/357)).
The structural half is enforced on the append path — bounded and charset-checked
identity, dot-run rejection, bounded contract, field/event agreement — and every
rule is mutation-verified.

**The seam for the network-trust half is `OpOrigin`**, consulted on the append
path and defaulting to `TrustedLocalOrigin` (named for what it *assumes*, not
described as safe). `RuntimeStore::with_origin(..)` is where a
`SignedGossipOrigin` plugs in.

⚠ **That default is exactly what must be replaced when foca is wired.** Feeding
an unauthenticated network protocol into a log that accepts any structurally
valid op is the routing-poisoning path, and persistence makes it durable. The
seam is proven *wired* — a mutation deleting the call from the append path fails
the suite — but it authorises everything until something else is installed.

---

## 4. Integration — the table is a hint, never an authority

This is the load-bearing invariant, and the EHDB-native change does not alter it.

```
     partition table              D8 topology fold
  (AUTHORITY on WHO owns)        (HINT on WHERE it is)
          │                              │
  execution_id → partition_for(id)       │
               → shard_for_partition(p,N)│
                       = shard 3 ────────┴──→ address of shard 3's instance
                                                      │
                                    stale? ──→ fail-closed 503 (server#416)
                                                      │
                                          gossip converges, self-heals
```

> **The partition table decides *which shard owns a key*. The topology fold only
> decides *where to send the request*. A wrong topology entry costs a failed
> request; a wrong partition entry costs a forked log.**

- `partition_for` / `shard_for_partition` (server#417) are **deterministic pure
  functions of the key**. They consult nothing, cannot be stale, and are
  identical on every instance.
- **A stale hint degrades into the path already built.** server#416 made a failed
  forward return `AppError::OwnerUnavailable` → 503 instead of a local write.
  **That change was the prerequisite for dynamic routing at all** — with
  degrade-to-local still in place, a stale address would silently fork the owning
  shard's log.
- **Self-healing needs no protocol.** A 503 plus a converged view means the retry
  lands correctly. No cache-invalidation handshake, because the authority was
  never in the cache.
- ⚠ **Owner-redirect is a refinement, not a substitute.** An instance that knows
  it does not own a partition may reply with the owner's address. It must not be
  *required*, or a wrong hint becomes a two-hop wrong answer; the existing loop
  guard (`AFFINITY_FORWARDED_HEADER`, *"one hop, never a loop"*) bounds it.

**What must never happen:** D8 gaining a `shard_count` or an ownership map. The
moment membership carries ownership, an eventually-consistent fold decides a fact
that must be exact, and two instances can both believe they own a partition.
`shard_count` stays config, changed only by a deliberate, fenced rebalance.

⚠ **This is eventually consistent, and it is only safe because of the above.**
Gossip converges; it does not agree. Two instances may briefly hold different
views of who is alive and where — acceptable precisely because neither view
decides ownership.

---

## 5. Security — first-class, and currently absent

⚠ **Design only. Nothing here touches secrets, IAM or credentials.**

### Gossip membership messages

An unauthenticated pool means **anyone who can reach the port can inject
membership**. Announce yourself as shard 3's instance, and every peer's topology
fold routes shard 3's writes to you. That is **routing poisoning yielding the
platform's event stream** — the highest-value attack in this design.

- **Authenticated membership** — signed by a cluster key, or mTLS between
  members. An unsigned pool is not deployable outside a fully trusted network.
- **Encryption** where the network is shared: membership messages carry instance
  names and addresses, which is reconnaissance.
- **Join authorisation** — a new member presents a credential, not merely
  knowledge of a seed address.

⚠ Note the asymmetry the EHDB-native design introduces: because membership is
*persisted*, a poisoned entry does not vanish when the attacker leaves — it is in
the log, and the fold will keep replaying it. **Validation must happen at
append time**, not at read time.

### Cross-cluster topology requests

Reading a remote cluster's D8 must be **authenticated and authorised** — which
clusters may ask, and what they may see. Cross-region sharpens it: the request
traverses networks NoETL does not control, and the response is a map of internal
addresses.

⚠ Precedent to honour: credential residency already region-locks keychain entries
(`Residency violation: … region-locked to X; this server is in Z`). **Topology
must not become a way to learn about a region whose data you may not touch.**

A cluster gossip key is platform/runtime rather than business-logic, so it may
live at the platform layer per `execution-model.md` — but it is a *cluster-wide*
key whose compromise is total, so rotation is part of its design and is
owner-gated, not attempted here.

---

## 6. The hard parts, honestly

### Failure-detector tuning — the dominant risk

- **Aggressive** → false-positive evictions. An instance evicted while healthy
  has its partitions considered unowned.
- **Conservative** → slow detection; requests route to a dead instance for the
  window, each failing closed with a 503.

**The asymmetry resolves it:** slow detection costs *failed requests*; false
eviction costs *ownership confusion*. Those are not comparable. **Tune
conservative and let the 503 absorb it.** SWIM's indirect probing is what makes
conservative tuning affordable — it removes most false positives without
lengthening the window, and it is the single strongest argument for option A.

⚠ **Hard constraint: failure detection must never trigger a rebalance
automatically.** Gossip says *"unreachable"*; a fenced, deliberate operation says
*"reassign"*. `ehdb-reference/src/fencing.rs` already has the token machinery.

### Partition and split-brain

A network partition splits the pool; each side sees the other as dead. Both sides
keep serving the partitions they own — **and that is correct**, because ownership
comes from the partition table, which is identical on both sides and did not
change. Writes for a partition whose owner is across the split fail closed.
**No split-brain in the data**, because gossip never had authority over
ownership. Recovery is convergence.

⚠ The residual risk is reassignment *during* a partition — hence fencing, and
hence rebalance being deliberate.

⚠ **New with the EHDB-native design:** both sides of a partition keep *appending*
to their own D8 log. On heal, the two membership histories must reconcile. Since
D8 is partitioned and indexed by `worker_id`, and each node is the authority on
its **own** liveness, the merge is per-node last-op-wins rather than a general
conflict resolution — but that property should be **tested at a partition
boundary**, not assumed.

### The cross-cluster cache bound

"Cache only the remote instances actively worked with" needs a real eviction
policy or it grows to full remote membership and the LAN/WAN split is lost.
**TTL from last use, a hard cap per remote cluster, and a metric on entries and
evictions.** ⚠ An unbounded cache with no metric is how the cmdbus manifest
reached 100% of its PVC — a cost that is the product of two growing quantities,
invisible until the volume is gone.

### Migrating off `noetl.runtime`

The Postgres registry is **load-bearing for the sweeps' `skipped_live` guard**,
and that guard stops a sweep terminating live work. A wrong liveness answer there
is the unsafe direction — the same shape as #326.

Sequence: D8 runs **alongside** the table; the sweep keeps reading the table;
D8's liveness is compared against it until they agree; only then does the table
stop being consulted. ⚠ That is a **dual-oracle period against a guard that
terminates executions** — plan it as a comparison with a divergence metric, not
as a cutover. #325/#326 is the precedent for how two oracles disagree in ways
nobody predicted.

### Before any of this: exercise D8

Zero consumers, zero tests — the same state the projection engine was in at step
2, where the code turned out to work but only testing established it. **D8 needs
the same treatment before it carries routing:** register/heartbeat/deregister
round-trip, `list_live_since` watermark semantics, survival across a reopen,
`cold_load` recovery, and cursor-based tail replay. That is the first
implementation step, and it is cheap.

### Where this does not help

Membership answers *where an instance is*, not *whether it should be there*.
Capacity-aware placement, partition-to-shard assignment and rebalance scheduling
are separate problems that a topology table informs but does not decide.
