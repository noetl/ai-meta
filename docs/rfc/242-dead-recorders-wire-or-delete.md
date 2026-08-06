# RFC — the metric recorders with no caller: wire or delete

**Decision needed from:** the user (small — one metric)
**Related:** [ai-meta#242](https://github.com/noetl/ai-meta/issues/242)
**Status:** open, but **much smaller than the issue says**.

---

## 1. The issue is largely stale — 3 of its 4 are already resolved

#242 lists four recorders that exist but are never called. Re-checked against
`origin/main` on 2026-08-06:

| # | recorder | issue says | **actual state now** |
| :-- | :-- | :-- | :-- |
| 1 | `record_nats_consumer_lag` (worker) | dead | **already deleted** — `nats_consumer_pending` has **0 hits** in the crate |
| 2 | `record_event_stream_published` (server) | dead | **already deleted** — only a doc comment referencing #242 remains |
| 3 | `record_event_stream_skipped` (server) | dead | **already deleted** — same |
| 4 | `record_affinity_decision` (worker) | dead, "more likely wire" | **still present**, still uncalled |

So the decision is **one metric**, not four. The rest of this brief is about
that one.

## 2. `noetl_worker_affinity_decisions_total` — the evidence

Still fully wired *as a metric*: field declared (`metrics.rs:77`), constructed
and registered (`:563`–`:573`), recorder present (`:1773`). It has no caller.

#242 guessed **wire**, on the reasoning that execution affinity is live in prod
(#172 Phases 1–4), so a dead counter means a shipped feature is unobserved.

**That reasoning does not survive checking.** The counter measures a *routing
decision* — its labels are `owned` / `redirected` / `forced_local`, produced by
`AffinityDecision::metric_label`. The thing that made those decisions was the
steering block, and every remaining reference to `AffinityConfig::from_env` in
the worker is a **doc comment**:

```
src/ehdb/eventlog_backend.rs:97   /// Matches [`crate::sharding::AffinityConfig::from_env`] so the durable
src/ehdb/eventlog_backend.rs:102  /// [`crate::sharding::AffinityConfig::from_env`].
src/ehdb/eventlog_backend.rs:119  /// [`crate::sharding::AffinityConfig::from_env`]. An out-of-range index degrades
```

Comments counting as callers is a documented false-positive mode in this repo,
and this is a clean instance of it. The steering block was deleted at T5
(`14a3f1f`), which is also why `NOETL_STATE_AFFINITY_ROUTE=true` is set in prod
and does nothing — the one inert flag of 77.

What *did* survive is the **shard derivation**, reimplemented in
`eventlog_backend.rs` ("Matches `AffinityConfig::from_env`"). Deriving a shard
is not the same act as deciding to redirect a command, and only the latter is
what this counter counts.

## 3. Recommendation: **delete**

The decision the counter measures no longer happens. Keeping the metric costs
nothing at runtime but is actively misleading: it is a registered, documented
counter for a behaviour the system does not exhibit, and the next person to ask
"is affinity routing redirecting anything?" will read a permanent absence as
"no redirects", which is the right answer for the wrong reason.

**Delete** `affinity_decisions_total`, its recorder, and
`AffinityDecision::metric_label` if it has no other user.

**Do not** delete the shard-derivation code — it is live and load-bearing for
the durable event-log backend.

### If affinity routing is ever restored

The counter comes back with it, in the same commit. That is the correct
coupling: a metric for a decision should be introduced by the code that makes
the decision, not left behind as a placeholder. A placeholder metric is
indistinguishable from a broken one.

### The alternative, if you would rather not delete

Wire it to the shard-derivation site with **relabelled** outcomes that describe
what actually happens there (a derivation, not a redirect). This is more work
than deleting and produces a differently-named metric, so it is only worth it if
shard derivation is a thing you want observed — which is a separate question
from #242, and probably better answered by a derivation-specific counter.

## 4. Why this was filed rather than swept

Deleting a metric is a public-surface change: dashboards, recording rules, and
alerts may reference it. Before deleting, confirm nothing does —
`ops/ci/manifests` and any GMP `Rules` objects. The related sweep in ops#252
already repointed the materializer-lag rules off the dead NATS gauges, so the
precedent and the search path both exist.

## 5. Repeatable check

`./playbooks/drift-audit.sh dead-recorders` — read-only, no build.

Two properties it had to get right, worth restating because both produced
confident wrong answers first:

1. **Ask reachability, not existence.** An earlier sweep asked "does a recorder
   exist for each metric" and reported **zero** orphans across 136 metrics.
   Every one of these four has a recorder; none had a caller.
2. **Only count functions that mutate.** Treating every `pub fn` in `metrics.rs`
   as a recorder reported **51 of the server's 66** as orphaned, because the
   lazy accessors are called only from the `record_*` wrappers beside them.
