# #318 — EHDB-native coordination for the system worker pool

**Design only. Nothing built, no prod change.**

## Starting position: the Postgres recommendation was wrong

`playbooks/324-cutover-prep/election-mechanism-options.md` recommended a
Postgres lease row. The owner rejected it on strategy, correctly: #241's stated
end-state is that NoETL's **internal platform transactions run on EHDB, not on
external infra**. Pinning coordination — the thing every scaling decision routes
through — to Postgres fights that endgame and anchors it to the store we are
trying to move off, which also happens to be the one that does not scale.

That paper also carried a second error, and it is the load-bearing one.

## 1. The circularity objection was wrong, and here is the dependency trace

The earlier paper rejected EHDB's own KV tier with: *"the KV tier lives in the
writer, and the thing being elected is the writer — the election would depend on
the component it elects."*

That is true **for electing the writer**. It is **false for coordinating the
system worker pool**, and I collapsed two different problems into one sentence.

What the writer process actually serves (read off the running pod's startup log,
`noetl-cmdbus-writer-0`):

| engine | port | store |
| :-- | :-- | :-- |
| command-bus L0 | 9100 ingest / 9101 claim / 9102 metrics | `/data/cmdbus` |
| events-feed L0 | 9103 ingest / 9105 SSE / 9106 metrics / 9108 WAL fan-out | `/data/eventbus` |
| **KV engine** | **9107** | **`/data/eventkv`** |
| tier service | 9110 | `/data/eventbus/ehdb-tier` |

And the topology:

```
noetl-cmdbus-writer-0        StatefulSet, replicas: 1   <- serves KV on :9107
noetl-worker-system-pool     Deployment,  replicas: 1   } the pool to be
noetl-worker-system-pool-shard1  Deployment, replicas: 1 } coordinated
```

**The KV engine is served by the writer, which is a different workload from the
system pool.** So a coordination primitive in KV sits *strictly below* the
system pool in the dependency graph. A system-pool pod acquiring a lease from
`:9107` depends on the writer — not on the system pool, and not on itself.

**Not circular.** The objection stands only where the thing being coordinated
*is* the writer.

## 2. The EHDB-native options

### (a) `LeaseStore` backed by the EHDB KV engine — **not circular**

The KV engine already has most of what a lease needs:

```
KvCoordinator / KvClient:  get, put(ttl_ms), delete, scan, sweep_expired
```

TTL and expiry sweep are **native**, which is exactly a lease's expiry semantics.

⚠ **What is missing is compare-and-swap.** `put` overwrites unconditionally, so
two candidates can both "win". The existing trait needs exactly one new
operation:

```rust
pub trait LeaseStore {
    fn read(&self, name) -> Option<LeaseRecord>;
    fn create(&self, name, record) -> bool;              // put-if-absent
    fn compare_and_swap(&self, name, expected_version, record) -> bool;  // ← the gap
}
```

- **Cost:** one new KV verb (`cas`/`put_if_version`) in `ehdb-feed/src/kv.rs`,
  its wire encoding, and a `KvLeaseStore` implementing the trait. The engine is
  already single-writer per shard, so CAS is a local compare under the existing
  engine lock — no consensus needed.
- **Interaction:** drops straight into `ShardElection`, which is written,
  tested (30 tests) and uncalled. The fencing epoch becomes the lease's version.
- **Circular?** No.

### (b) Coordination via the event log's fencing epoch — **blocked today**

`FencingLedger` already offers `highest_epoch(shard)` and
`check_and_advance(shard, epoch)` — a durable monotonic compare-and-advance,
which is most of a fencing token.

⚠ But it is **not reachable across processes**. It is constructed as
`FencingLedger::new(paths.shared_root.join(".fencing"))` — a directory on the
writer's own filesystem — and **it is served on no port**. Only a process that
can see that filesystem can use it, and the PVCs are `ReadWriteOnce`.

- **Cost:** a new network face for the ledger, i.e. re-inventing (a) with more
  steps, or an `ReadWriteMany` volume, which contradicts ehdb#332's whole
  direction.
- **Circular?** No, but currently unreachable. **Reject** in favour of (a),
  which reaches the same place through an engine that is already served.

### (c) Ride the command-bus claim coordinator — **cheapest, and it may be enough**

Worth stating because it is easy to miss: the command bus **already has an
exclusive-assignment primitive**. `ClaimCoordinator` (`:9101`) hands each record
to exactly one consumer via `claim_next` / `ack` / `nack`, with `ack_wait`
redelivery. That is a distributed mutex with a lease timeout, already in
production, already serving the system pool.

If work were assigned **per command** rather than **per static shard**, the pool
would scale by adding replicas that all claim from the same subject — no shard
index, no ownership, no election. Competing consumers is the natural shape for a
claim-based bus.

⚠ The blocker is not the bus, it is **state-shard ownership**:
`NOETL_STATE_SHARD_WRITE=true` with `ShardOwnership::new(shard_index, count)`.
Commands can be claimed freely; the *state writes* are what assume one owner per
shard. So (c) is sufficient only if state-shard ownership is decoupled from
worker identity — otherwise it still needs (a) underneath.

- **Circular?** No. **Cost:** zero new primitives, but a real change to how state
  ownership is derived.

## 3. How scaling then works

With (a) in place:

1. Provision shards generously once — say `SHARD_COUNT = 16` — as *logical*
   shards, decoupled from pod count.
2. Each system-pool pod runs `ShardElection` against `KvLeaseStore` and acquires
   leases for **as many shards as it can hold**, renewing on a timer.
3. A pod that dies stops renewing; its leases expire via the KV TTL and another
   pod takes them, **with a higher epoch**. Fencing rejects the dead pod's late
   writes.
4. Replica count becomes a free variable: 1 pod holds 16 shards, 8 pods hold 2
   each. KEDA can then scale the Deployment on `ehdb_feed_subject_lag` exactly
   as it already does for `noetl-worker-rust`.

**Two owners of one shard becomes impossible by construction**, because
ownership is a lease with CAS, not an env var. That is precisely what today's
`NOETL_SHARD_INDEX` cannot promise — it is an assertion, not a claim.

## 4. Does one primitive solve #318, C5 and the election? **No — and the split matters**

| problem | what coordinates what | KV-based lease works? |
| :-- | :-- | :-- |
| **#318** system-pool scaling | system pool ← KV (writer) | **Yes.** KV is below it. |
| **election mechanism** (ehdb#321) as applied to the system pool | same as above | **Yes.** Same primitive. |
| **C5** single-writer election *for the writer itself* | writer ← KV (**served by the writer**) | **No. Genuinely circular.** |

So the honest answer is **two of three**. #318 and the system-pool half of the
election are the same problem and (a) solves both. **C5 is a different problem**:
electing the writer cannot depend on a store the writer serves, because during
the failover window there is no writer to serve it.

C5 needs either an external coordinator (which the owner has ruled out for
Kubernetes, and Postgres is now also ruled out), or a peer-to-peer protocol
among writer replicas — i.e. actual consensus. **That should not be smuggled in
under #318.** Flagging it as still open rather than pretending this closes it.

## 5. Recommendation and the honest catches

**Recommend (a): a `KvLeaseStore` on the EHDB KV engine, with CAS added to KV.**

- EHDB-native — moves coordination *onto* the substrate #241 targets, not off it.
- Not circular for the system pool, with the dependency traced above.
- Smallest real addition: one KV verb. TTL, sweep, single-writer ordering and
  the whole `ShardElection` + fencing stack already exist.
- Unblocks KEDA autoscaling of the system pool, which is the actual #318 ask.

Consider (c) alongside it: if state-shard ownership can be decoupled from worker
identity, competing claim-based consumers may remove the need for shard leases
in the system pool at all. That is a smaller system, and worth an hour of
investigation before committing to (a).

### Catches, stated plainly

- ⚠ **Availability coupling.** Every system-pool pod would depend on the writer's
  `:9107` to hold its lease. The writer is `replicas: 1`. If it restarts (~90 s,
  as measured), leases lapse and the pool stalls until it returns. Today the pool
  has no such dependency. The mitigation is lease TTL comfortably longer than a
  writer restart — but it is a **new coupling**, and it should be a deliberate
  choice rather than a side effect.
- ✅ **Not the ehdb#332 disk problem.** `/data/eventkv` is its own PVC
  (`/dev/nvme0n4`, 19.5G), separate from `/data/eventbus` and `/data/cmdbus`. So
  KV-based coordination does **not** inherit the tier/writer shared-volume issue.
- ⚠ **Same node, though.** All three PVCs attach to the one writer pod, so a node
  loss still takes coordination with it. That is C5's territory, and another
  reason not to treat this as closing C5.
- ⚠ **CAS must be genuinely atomic under the engine lock**, and it needs a
  positive-control test proving two concurrent candidates produce exactly one
  winner. A CAS that silently degrades to last-write-wins would look like it
  works right up until a real failover.

## Related

- noetl/ai-meta#318, ehdb#321, ehdb#332, ehdb#241
- `playbooks/324-cutover-prep/election-mechanism-options.md` — superseded on the
  mechanism choice; its **sequencing** warning still stands: enforce-before-election
  is an outage, not a degradation.
