# Self-sufficiency — no external database, not no dependencies

A guiding principle for the EHDB program and anything downstream of it.

## The rule

**"Self-sufficient" means NoETL owns its own state. EHDB is the database; there
is no external datastore, no external coordination service, nothing to deploy,
operate, quorum or upgrade alongside NoETL.**

**It does not mean no dependencies.** Proven libraries are welcome and preferred.

## Why the distinction is load-bearing

The two get conflated, and conflating them produces the worst of both: a system
that still has operational dependencies *and* has re-derived subtle algorithms
badly.

- **An external service** is a thing with a lifecycle you do not control: a
  Consul cluster, an etcd quorum, a NATS deployment. It has to be sized,
  upgraded, monitored, secured and recovered — and when it is down, you are down
  for reasons your own code cannot explain. NoETL deleted NATS for exactly this
  reason.
- **A library** is a crate. It compiles into the binary, ships with it, versions
  with it, and has no runtime lifecycle of its own. `serde`, `tokio` and `sqlx`
  are not violations of self-sufficiency; they are how the binary is built.

## The corollary: do not reinvent the wheel

Where a well-tested library exists for a subtle problem, **use it**. The bar for
writing our own is not "we could" — it is that no maintained implementation fits,
and that we are prepared to own the failure modes.

The failure modes are the point. Some categories fail *loudly* when written
badly (a parser rejects input; a serializer errors). Others fail **silently**, and
those are where hand-rolling is most expensive:

- failure detectors and membership protocols — a detector that is 95% right
  produces false evictions under load, not an error;
- consensus and leader election;
- cryptography;
- clock/ordering primitives.

⚠ NoETL's own history is the argument. The recurring defect in this codebase is
not a missing feature — it is **a mechanism that exists and does not fire**: an
inert gate, a metric on the wrong registry, a guard with no runner, a test
without `#[test]`. Hand-rolled subtle algorithms are that same shape with a
larger blast radius, because their silent-wrong state looks exactly like their
working state.

## How to apply it

When a design needs a capability, ask in this order:

1. **Does this need to be a separate running service?** If yes, push back hard —
   that is the thing self-sufficiency forbids.
2. **Is there a maintained library?** Prefer it. Evaluate on maintenance
   activity, license, dependency weight, and whether its failure modes are
   observable — not on whether the README is pretty.
3. **Only if neither fits**, write it — and scope it as its own project with a
   test harness that reproduces the conditions it fails under (partition, load,
   clock skew), because unit tests do not.

## Worked example — gossip membership

Decided 2026-09-08. NoETL's topology lives in EHDB as an event-sourced
projection (D8 `RuntimeDataset`): **state is ours, no external discovery
service**. But health must physically travel between instances, and a node
cannot learn a peer died by reading its own log — so a **wire protocol** is
required.

The resolution follows the rule exactly: an **embeddable SWIM gossip library**
carries transport and failure detection; every membership transition it reports
is appended to D8; all state, history, recovery and query stay in EHDB.

Hand-rolling SWIM was considered and rejected on the "fails silently" criterion:
suspicion timing, incarnation numbers, anti-entropy and piggyback budgets are
each a paper, and each fails quietly rather than loudly.

## Related

- [`execution-model.md`](execution-model.md) — the shape this serves.
- [`representation-drift.md`](representation-drift.md) — the "exists but does not
  fire" failure class this rule's silent-failure argument draws on.
- [`docs/rfc/ehdb-topology-membership.md`](../../docs/rfc/ehdb-topology-membership.md)
  — the worked example in full.

## History

Codified 2026-09-08 from a standing instruction: *"self-sufficient means no
external database — it does not mean no dependencies; proven libraries are
welcome, avoid reinventing the wheel."*
