# Blocker C5 — single-writer election / fencing: mechanism options

**Decision needed, nothing built.** Kubernetes Leases are **off the table** per
the owner, so ehdb#321's proposed short-term answer does not apply. This paper
picks the mechanism; implementation is gated on that choice.

## What has to be true

`ShardElection` and `FencingLedger` already exist, are tested (30 tests), and
have **no call sites**. The missing piece is not the algorithm — it is a
`LeaseStore` implementation that works **across processes**. The only one
shipped is `InMemoryLeaseStore`, which is per-process and would let two writers
each believe they own the shard.

The trait is already the right shape and maps onto a compare-and-swap:

```rust
pub trait LeaseStore: Send + Sync {
    fn read(&self, name: &str) -> Result<Option<LeaseRecord>>;
    fn create(&self, name: &str, record: &LeaseRecord) -> Result<bool>;
    fn compare_and_swap(&self, name, expected_version, record) -> Result<bool>;
}
```

## Options

### A — Postgres **advisory locks** (`pg_try_advisory_lock`)

Obvious first thought, and **wrong for this deployment.**

⚠ Every client reaches Postgres through **pgbouncer in `POOL_MODE=transaction`**
(verified: both the pgbouncer and cloud-sql-proxy sidecars). A session-scoped
advisory lock is held on a *server* connection that pgbouncer hands to a
different client the moment the transaction ends. The lock outlives the holder's
intent and is invisible to it. Transaction-scoped locks
(`pg_advisory_xact_lock`) release at commit, which is far too short to hold a
writer lease.

Making this work would mean bypassing pgbouncer for the election connection —
a second connection path, with its own credentials and its own failure mode,
to save a table. **Reject.**

### B — a **lease row** in Postgres — *recommended*

A single table; CAS is an ordinary conditional `UPDATE`:

```sql
CREATE TABLE noetl.shard_lease (
  name        text PRIMARY KEY,      -- 'shard-0'
  holder      text NOT NULL,
  epoch       bigint NOT NULL,       -- the fencing token, monotonic
  expires_at  timestamptz NOT NULL,
  version     bigint NOT NULL        -- CAS guard
);

UPDATE noetl.shard_lease
   SET holder=$1, epoch=epoch+1, expires_at=now()+$2, version=version+1
 WHERE name=$3 AND version=$4;       -- rowcount 1 = won, 0 = lost
```

- **Maps 1:1 onto the existing trait.** `read` → SELECT, `create` → INSERT ...
  ON CONFLICT DO NOTHING, `compare_and_swap` → the UPDATE above. No new
  abstraction.
- **Works through pgbouncer transaction pooling**, because each operation is a
  single self-contained statement. This is the property option A lacks.
- **No new infrastructure.** Postgres is already a hard dependency.
- **The fencing epoch already has a home:** `epoch` is exactly the token
  `FencingLedger` checks.
- **Costs:** one small query per renewal interval, and the writer's liveness
  becomes coupled to Postgres availability. That coupling is real but not new —
  a writer that cannot reach Postgres cannot do useful work anyway.
- ⚠ Clock: `expires_at` must be evaluated with **`now()` on the server**, not on
  the candidate. Two pods with skewed clocks comparing their own wall time is
  how this goes wrong.

### C — EHDB's own KV tier

Self-hosting is the long-term shape, but it has a bootstrap problem: the KV tier
lives in the writer, and the thing being elected *is* the writer. The election
would depend on the component it elects. **Reject for now**; revisit only once
KV runs somewhere independent of the writer.

### D — standalone etcd / Consul

Purpose-built and correct, and it contradicts the #241 goal of "no external
infra dependency for platform functionality" by adding exactly one. **Reject**
unless B proves inadequate under load.

## Recommendation

**Option B, a lease row in Postgres.** It is the only option that works through
the existing connection path, needs no new infrastructure, and fits the trait
that is already written and tested. Implementation is then small: one
`PostgresLeaseStore`, wired where `render_election()` currently hard-codes 0.

## Sequencing note, if B is chosen

⚠ **Do not enable fencing `enforce` before the election is actually issuing
tokens.** The worker's own docs record why: with no election every writer's
epoch is `0`, so the first writer to advance the fencing marker fences *every
other one* — enforce-before-election is an **outage**, not a degradation. Order
is: implement the store → run the election in shadow → confirm
`ehdb_election_active 1` and a non-zero epoch → only then enforce.

The guard test in `worker/src/ehdb/eventlog_backend.rs` fires the moment
`ShardElection` gains a call site, which is the intended prompt to revisit
`render_election()` so it publishes real state instead of a hard-coded 0.
