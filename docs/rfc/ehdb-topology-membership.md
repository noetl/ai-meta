# Topology and membership — where a shard's instance actually is

**Design only. Nothing built, nothing on prod.**

Companion to [`ehdb-embedded-state.md`](ehdb-embedded-state.md) and
[`ehdb-packaging.md`](ehdb-packaging.md). Those settle *which shard owns a key*
and *how the engine is packaged*. This settles **where that shard's instance
is**, and how every instance learns it.

The target model: each component broadcasts itself on startup and sends health
updates; health propagates to nearest nodes by **gossip fan-out, not
broadcast-to-all**; each instance caches the cluster's topology as a DNS-like
table of true instance names and addresses; the table is **bounded to its own
cluster**; cross-cluster is **lazy** — fetch a remote cluster's topology on
demand, cache only the remote instances actively worked with, refresh by health.

Grounded in `server@main`, `ehdb@main`, prod 2026-09-08.

---

## 1. What exists today

### Address resolution is a string template

```rust
// server/src/affinity.rs:134
pub fn owner_base_url(&self, execution_id: i64) -> Option<String> {
    let template = self.peer_url_template.as_ref()?;          // NOETL_PEER_URL_TEMPLATE
    let owner = crate::sharding::shard_for(execution_id, self.shard.shard_count);
    Some(template.replace(SHARD_PLACEHOLDER, &owner.to_string()))
}
```

That is the whole of it. Shard index → substitute into a template → a URL.
Combined with `shard_index_from_hostname` (StatefulSet ordinal), addressing today
is **entirely static**: a shard's address is a pure function of its index and a
config string, resolved by DNS at request time.

**Properties, stated plainly:** no liveness, no capacity, no labels, no
membership events, no notion of an instance *identity* distinct from its index.
A dead shard's URL resolves exactly as a live one's does — the failure surfaces
only as a connection error at use, which is why server#416's fail-closed change
was needed before any of this matters.

### ⚠ But there IS membership, and it is load-bearing

`noetl.runtime` is a registry with precisely the fields this design needs:

```sql
CREATE TABLE noetl.runtime (
    runtime_id BIGINT PRIMARY KEY,
    name TEXT NOT NULL,
    kind TEXT CHECK (kind IN ('worker_pool','server_api','broker')),
    uri  TEXT,          -- the address
    status TEXT NOT NULL,
    labels JSONB, capabilities JSONB, capacity INTEGER,
    heartbeat TIMESTAMPTZ NOT NULL DEFAULT now(), …);
```

fed by `POST /api/worker/pool/{register,deregister,heartbeat}`.

And it is **read for safety decisions**, not just reporting: both
`nonconvergence_sweep.rs:266` and `orphan_sweep.rs:124` do
`SELECT name FROM noetl.runtime` to decide which workers are alive — the
`skipped_live` disposition that stops the sweep terminating work a live worker
still holds.

> **So the gap is not "no membership". It is that membership is centralised in
> Postgres — the store this whole program is moving away from — and is not used
> for routing.**

That reframes the work: not *build membership*, but *decide whether a
DB-backed registry or gossip carries it*, and *connect it to routing at all*.

### The quantified gap

| capability | today |
| :-- | :-- |
| shard → address | static template + DNS |
| instance identity | none (index only) |
| liveness | `noetl.runtime.heartbeat`, centralised, **not consulted by routing** |
| capacity / labels | columns exist, unused for placement |
| membership events | none |
| cross-cluster anything | none |
| failure detection | connection error at point of use |

---

## 2. The model

### Recommendation: SWIM-style gossip, an existing crate, LAN/WAN split

**Intra-cluster: full membership by gossip.** Every instance knows every other
instance in its own cluster. At NoETL's scale — tens of shards, not thousands —
full membership is cheap, and it is what makes the topology table a complete
local answer rather than a cache with misses.

**SWIM** (Scalable Weakly-consistent Infection-style Membership) is the right
family, and specifically **not** a consensus protocol:

- **Failure detection is delegated.** A node suspecting a peer asks *k* other
  nodes to probe it indirectly before declaring it dead. This is the single
  most valuable property: it distinguishes *"I cannot reach X"* from *"X is
  down"*, which a heartbeat table structurally cannot.
- **Suspicion, not immediate eviction.** A suspected node gets a window to
  refute. This is the knob that trades false-positive evictions against
  detection latency (§5).
- **Dissemination is piggybacked and fan-out bounded** — gossip to a few peers
  per round, not broadcast-to-all, exactly the model asked for.

**Inter-cluster: on-demand fetch + per-relationship cache.** This is Consul's
LAN-pool / WAN-pool split, and the split exists for a real reason: gossip
tolerances that work on a LAN (sub-millisecond, reliable) produce constant false
positives across regions (tens of ms, lossy). **The two pools must have separate
failure-detector tuning, or the WAN's characteristics will destabilise LAN
membership.**

So: a full gossip pool per cluster; between clusters, an explicit
`GET /topology` fetch, and each instance caches only the remote instances it is
actively routing to, refreshed by their health.

### ⚠ This is eventually consistent, and that must be said out loud

Gossip converges; it does not agree. At any instant two instances may hold
different views of who is alive and where. **That is acceptable only because of
§3** — the topology table is never the authority on ownership, only a hint about
address. A design that let gossip decide *ownership* would be using an
eventually-consistent protocol for a decision that must be exact, which is how
split-brain gets built on purpose.

### Build vs adopt

**Adopt.** Rust has `memberlist`/`foca`-class SWIM implementations. Hand-rolling
a failure detector means re-deriving suspicion timing, incarnation numbers,
anti-entropy and message compaction — each of which is a paper, and each of
which fails subtly rather than loudly. ⚠ The honest caveat: this is a *new
production dependency on the routing path*, and it should be evaluated for
maintenance status and audited transport before adoption, not chosen from a
README.

---

## 3. Integration — the table is a hint, never an authority

This is the load-bearing section.

```
     partition table          topology table
  (AUTHORITY on WHO)         (HINT on WHERE)
          │                         │
  execution_id                      │
      → partition_for(id)           │
      → shard_for_partition(p, N)   │
              = shard 3 ────────────┴──→ address of shard 3's instance
                                              │
                            stale? ──→ fail-closed 503 (server#416)
                                              │
                                    gossip converges, self-heals
```

**The separation, stated as an invariant:**

> **The partition table decides *which shard owns a key*. The topology table
> only decides *where to send the request*. A wrong topology entry costs a
> failed request; a wrong partition entry costs a forked log.**

Concretely:

- `partition_for` / `shard_for_partition` (server#417) are **deterministic pure
  functions of the key**. They consult nothing, cannot be stale, and are
  identical on every instance.
- The topology table is consulted **only** to turn an already-decided shard index
  into an address.
- **A stale hint degrades into the path already built.** server#416 made a failed
  forward return `AppError::OwnerUnavailable` → 503 rather than a local write.
  That is exactly the right behaviour for a stale address: the request fails
  safely, the caller retries, and gossip has meanwhile converged. **The
  fail-closed change was the prerequisite for making routing dynamic at all** —
  with degrade-to-local still in place, a stale hint would silently fork the log.
- **Self-healing** is then automatic: a 503 plus a converged view means the retry
  lands correctly. No reconciliation logic, no cache invalidation protocol — the
  authority was never in the cache.
- ⚠ **An owner-redirect is an optional refinement, not a substitute.** If the
  receiving instance knows it does not own the partition it may reply with the
  owner's address, which converges faster. But it must not be *required*, or a
  wrong hint becomes a two-hop wrong answer. The loop guard
  (`AFFINITY_FORWARDED_HEADER`, "one hop, never a loop") already bounds this.

**What must never happen:** the topology table gaining a `shard_count` or an
ownership map. The moment membership carries ownership, an eventually-consistent
protocol is deciding a fact that must be exact, and two instances can both
believe they own a partition. `shard_count` stays a config value that changes by
a deliberate, fenced rebalance (§4 of the main RFC) — never by gossip.

---

## 4. Security — first-class, and currently absent

⚠ **Design only. This touches no secrets, IAM or credentials.**

Two distinct surfaces, with different threat models:

### Gossip membership messages

An unauthenticated gossip pool means **a node that can reach the port can inject
membership**. The attack is not subtle: announce yourself as the instance for
shard 3, and every peer's topology table now routes shard 3's writes to you.
That is a **routing poisoning** attack that yields the platform's event stream.

Requirements:
- **Authenticated membership** — messages signed by a cluster key, or mTLS
  between members. An unsigned pool is not deployable outside a trusted network.
- **Encryption** where the network is shared — membership messages carry
  instance names and addresses, which is reconnaissance.
- **Join authorisation** — a new member must present a credential, not merely
  know the seed address.

### Cross-cluster topology requests

`GET /topology` from another cluster must be **authenticated and authorised**:
which clusters may ask, and what they may see. Cross-region makes this sharper —
the request traverses networks NoETL does not control, and the response is a map
of internal addresses.

⚠ Note the existing precedent: credential residency already region-locks
keychain entries with a `Residency violation: … region-locked to X; this server
is in Z` error. **Topology should not become a way to learn about a region whose
data you are not permitted to touch.**

### The specific thing to avoid

Do **not** put a cluster's gossip key in a worker or gateway env var. Per
`execution-model.md`, business-logic secrets live in the keychain; a cluster
membership key is platform/runtime and may live at the platform layer — but it
is a *cluster-wide* key whose compromise is total, so it deserves rotation
design, which is owner-gated and not attempted here.

---

## 5. The hard parts, honestly

### Failure-detector tuning — the dominant risk

The trade is symmetric and unavoidable:

- **Aggressive** → false-positive evictions. An instance evicted while healthy
  has its partitions considered unowned. If that ever fed a rebalance, a GC pass
  loses data.
- **Conservative** → slow detection. Requests route to a dead instance for the
  detection window, each failing closed with a 503.

**The asymmetry that resolves it:** with §3's design, slow detection costs
*failed requests*, and false eviction costs *ownership confusion*. Those are not
comparable. **Tune conservative and let the 503 absorb it.** SWIM's indirect
probing is what makes conservative tuning affordable — it removes most false
positives without lengthening the window.

⚠ And a hard constraint: **failure detection must never trigger a rebalance
automatically.** Handoff is fenced and deliberate (main RFC §4). Gossip says
"unreachable"; a human or a controller with a fencing token says "reassign".

### Partition and split-brain

A network partition splits the gossip pool; each side sees the other as dead.
Both sides continue serving the partitions they own — **and that is correct**,
because ownership comes from the partition table, which is identical on both
sides and did not change. Writes for a partition whose owner is across the split
fail closed. **No split-brain in the data**, because gossip never had authority
over ownership. Recovery is convergence.

⚠ The residual risk is the *rebalance* case: if ownership were reassigned during
a partition, both sides could believe they own a partition. Hence the fencing
token — `ehdb-reference/src/fencing.rs` already has the machinery — and hence
rebalance being deliberate rather than automatic.

### The cross-cluster cache bound

"Cache only the remote instances actively worked with" needs a real eviction
policy, or it grows to full remote membership and the LAN/WAN split is lost.
Recommend: **TTL from last use, plus a hard cap per remote cluster**, with a
metric on entries and evictions. ⚠ An unbounded cache with no metric is how the
cmdbus manifest reached 100% of its PVC — a cost that is a product of two
growing quantities and invisible until the volume is gone.

### Migrating off `noetl.runtime`

The registry is **load-bearing for the sweeps' `skipped_live` guard**. It cannot
simply be replaced: the sweep terminates executions, and a wrong liveness answer
there is the unsafe direction (already the shape of #326). Sequence: gossip runs
**alongside** the table, the sweep reads the table until gossip's liveness is
independently validated against it, and only then does the table stop being
consulted. ⚠ That is a dual-oracle period, with the same disagreement hazard as
#325/#326 — worth planning as a comparison, not a cutover.

### Where this does *not* help

Membership solves *where an instance is*, not *whether it should be there*.
Capacity-aware placement, partition-to-shard assignment, and rebalance
scheduling are separate problems that a topology table informs but does not
decide.
