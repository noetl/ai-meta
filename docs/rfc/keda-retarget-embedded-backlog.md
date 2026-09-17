# KEDA retarget: replacing the writer-shaped autoscaler trigger

**Status:** design only. No code, no manifest applied. 2026-09-09.
**Refs:** [ai-meta#332](https://github.com/noetl/ai-meta/issues/332), #318.

## The dependency being removed

The user-pool autoscaler scales on a metric served by the **cmdbus writer**:

```yaml
type: metrics-api
url: http://noetl-cmdbus-writer-0.noetl.svc.cluster.local:9102/metrics
valueLocation: ehdb_feed_subject_lag{subject="commands.shared.shard.0"}
targetValue: 2
activationTargetValue: 1
```

Under embedded per-shard state the writer is exactly what disappears — the
engine moves in-process. So this trigger loses its source, and the autoscaler
that keeps the user pool sized would silently stop scaling.

⚠ "Silently" is the operative word, and it is the same failure this program
keeps producing. KEDA's `metrics-api` scaler reading an **absent** series does
not fail loudly; it degrades. The metric that replaces this one has to be
present *before* the writer goes away, not after.

## What the server must expose

The values already exist in `ehdb-feed`: `SubjectConsumerGroup::subject_lags()`
and `lag()` are what the writer's `:9102` endpoint renders. The server, once it
embeds the command-bus feed (D2), can compute the identical numbers in-process.

| series | type | labels | meaning |
| :-- | :-- | :-- | :-- |
| `noetl_cmdbus_subject_lag` | gauge | `subject` | uncommitted records for that subject — the direct replacement for `ehdb_feed_subject_lag` |
| `noetl_cmdbus_committed_offset` | gauge | `shard` | consumer group's committed cursor |
| `noetl_cmdbus_head_offset` | gauge | `shard` | feed head; `head - committed` must equal the lag, and publishing both makes the lag falsifiable rather than merely reported |

### ⚠ The pinning requirement is load-bearing, not hygiene

`Registry::gather` **prunes metric families with no children**, so a labelled
gauge is *absent* from `/metrics` until something sets it. For an alert that
reads as a missing datapoint; for **KEDA it reads as no signal at all**, and the
pool stops scaling with nothing anywhere saying why.

So `noetl_cmdbus_subject_lag` must be **pinned at 0 for every configured subject
at startup, unconditionally** — not inside a config branch. server#315 made
exactly that mistake with the publish-skip reasons: it pinned them inside
`if event_bus_mode.publishes_ehdb()`, leaving them absent on precisely the
configuration whose value someone would be reading.

The subject label set here is **closed** (`commands.<pool>.shard.<n>` for the
configured pools and shard count), so pinning is possible. That is what makes
this metric different from the open-label cases where pinning cannot work.

## The KEDA change, when the series exists

```diff
-  url: http://noetl-cmdbus-writer-0.noetl.svc.cluster.local:9102/metrics
-  valueLocation: ehdb_feed_subject_lag{subject="commands.shared.shard.0"}
+  url: http://noetl-server-rust.noetl.svc.cluster.local:8082/metrics
+  valueLocation: noetl_cmdbus_subject_lag{subject="commands.shared.shard.0"}
```

`targetValue` and `activationTargetValue` carry over unchanged **only if the two
series are the same quantity**. Before flipping, run both endpoints side by side
and compare — a retarget onto a differently-scaled number silently re-tunes the
autoscaler, and the symptom is a capacity problem weeks later, not an error.

## ⚠ Why no code ships with this document

The obvious next step is to add the metric definitions, the pinning, and a
`record_cmdbus_lag()` recorder now, so the wiring is "ready".

**That would ship a recorder nothing calls** — the single most common defect in
this codebase. The 2026-08-05 reachability sweep found *four* dead recorders
across 136 metrics, every one of which passed a "does a recorder exist" check,
and three materializer alerts sat permanently inert behind them. A pinned-at-0
series with no producer is worse than nothing here: it reads as a healthy zero
backlog, which is exactly the value that tells KEDA not to scale.

So the series lands **in the same change set as the embedded command bus that
produces it**, and not before. The design is settled here so that change is
small; the implementation waits for a caller to exist.

## Ordering constraint

1. Server embeds the command-bus feed (D2) — not yet done.
2. Series added **with** its producer, pinned unconditionally.
3. Both endpoints observed side by side; confirm same quantity, same scale.
4. KEDA `valueLocation` + `url` retargeted.
5. Only then can the writer be retired.

Steps 3 and 4 are separate on purpose: the comparison is the evidence, and doing
it after the retarget means measuring the thing you already committed to.
