# ai-meta#265 — projection tier (tier 2) serve-readiness gate

Phase A of [noetl/ai-meta#265](https://github.com/noetl/ai-meta/issues/265).
Design note: [`docs/rfc/ehdb-projection-tier-serve-path.md`](../../docs/rfc/ehdb-projection-tier-serve-path.md).

PRs under test:

| repo | PR | what |
| :-- | :-- | :-- |
| noetl/worker | [#277](https://github.com/noetl/worker/pull/277) | A1 tier-generic store + wire protocol; A2 projection serve decision + `SERVE_WIRED_TIERS` |
| noetl/server | [#350](https://github.com/noetl/server/pull/350) | A3 mirror inside `orch_snapshot::save`; A4 cross-store comparator |

## What this gate is shaped around

Four findings from the survey, each of which is a way a projection-tier gate
could pass while measuring nothing.

**§1.1 — the wrong table is empty.** `noetl.projection` has 0 rows and no Rust
writer. A comparator pointed at it agrees with itself forever. `gate.sh` §3
therefore asserts `authoritative_version > 0` **before** scoring any parity
verdict. A match against nothing is not a pass.

**§1.2 — the real store has one writer**, so the mirror sits inside it and a
bypass would have to be a second `INSERT`. That is guarded in the server's unit
tests by *counting* INSERT sites, not naming them.

**§1.3 — the tier's existing parity check compares EHDB to EHDB.** The worker's
`shadow_project` folds a window and checks it against a second worker-side fold.
This gate deliberately does not read that signal; §3 reads the server's
cross-store verdict against `noetl.projection_snapshot`.

**§1.4 — snapshots outlive events 138:1.** The gate scopes to one freshly-driven
execution and reports `snapshot_age_seconds` so backlog and miss are
distinguishable.

Plus one property that is not about the projection tier at all: **§5 asserts the
event-log tier's verdict does not move.** Tier 1 is primary in prod. If arming,
corrupting or emptying tier 2 moved tier 1, the per-tier separation is fiction
and none of this is safe to ship.

## Arms

Each arm moves exactly one variable. Everything else — images, replica count,
relay URL, writer configuration — is held constant, so a change in the verdict
is attributable.

| arm | variable moved | expected |
| :-- | :-- | :-- |
| `shadow` | `NOETL_EHDB_PROJECTION=shadow` | `match`; `served_primary` **0 but present**; `materialized > 0` |
| `primary` | `NOETL_EHDB_PROJECTION=primary` | `match`; `served_primary > 0` |
| `demoted` | `NOETL_EHDB_TIER_SERVICE_ADDR` → black hole | not `match`; `primary_unavailable > 0` |
| `corrupt` | the newest record's `checksum` in the store | `divergent` with kind **`checksum`**, and NOT `stale_version` |
| `drop` | the projection store emptied | `divergent` with kind `missing_execution`; event log untouched |
| `bypass` | `NOETL_EHDB_PROJECTION_MIRROR_SOURCE=worker` on the server | not `match`; event-log tier still `match` |

The `corrupt` arm carries the assertion that most of this rests on: same
versions, different bytes. A comparator that only counted records would pass it,
and `stale_version` instead of `checksum` would send an operator to the relay
instead of to the store.

## Running it

```bash
cd playbooks/265-projection-tier

# images: built --network none against a host-side `cargo vendor`, runtime layer
# FROM the images already in the node, so each differs in exactly one file.
./deploy.sh load
./deploy.sh writer

./deploy.sh arm shadow 3 && ./gate.sh shadow
./deploy.sh arm primary 3 && ./gate.sh primary

# mutations re-read the SAME execution — driving a fresh one would refill the
# store the mutation just emptied.
EXEC_ID=<from the primary arm> ./deploy.sh corrupt && EXEC_ID=… ./gate.sh corrupt
EXEC_ID=… ./deploy.sh drop    && EXEC_ID=… ./gate.sh drop
./deploy.sh point 10.255.255.1:9110 && ./gate.sh demoted
./deploy.sh bypass && ./gate.sh bypass      # fresh execution, no EXEC_ID

./deploy.sh restore
```

## Traps this harness already accounts for

- **`kubectl scale` is reverted by a paused KEDA ScaledObject**, and a 0-replica
  Deployment reports "successfully rolled out". `deploy.sh` pins replicas via
  `autoscaling.keda.sh/paused-replicas`.
- **`jq -e` exits non-zero when the last output is `false`** — which is exactly
  `holds` on a divergent verdict. `field()` uses plain `jq -r` and reports
  `__ABSENT__` distinctly from a legitimate `false`/`0`.
- **Metric absence is the default.** §4 asserts the pinned series is *present*
  before reading its value; absent and "this build has no serve path" are
  otherwise the same bytes.
- **`kind load` has reported success for an image the node did not get.**
  `deploy.sh load` counts the tags in `crictl images` afterwards.
- **The relay picks a replica.** §4 sums the metric across every worker pod; a
  single-pod read would report 0 whenever the relay chose another and that zero
  reads exactly like "the serve decision never ran".
- **`noetl.execution.status` is frozen** (ai-meta#235). §2 settles on the
  authoritative snapshot `version` instead.

## Gate images

Built `--network none` per [the offline recipe][off]: host-side `cargo vendor`,
no `apk add` (the cargo-chef alpine base already carries the toolchain), runtime
layer `FROM` the image already present in the node.

⚠ `.dockerignore`'s `**/target` is dropped for these builds — it is unanchored
and excludes `vendor/cc/src/target/`, which breaks `cargo chef cook` with a
checksum error on `apple.rs`. The fresh clones have no real nested build
targets, so nothing else changes.

⚠ `--features duckdb-integration` is not available offline. **The gate worker is
not DuckDB-capable.** Nothing on the projection mirror path touches DuckDB, so
that is sound here and would not be for a gate exercising a `duckdb` tool step.

[off]: https://github.com/noetl/ai-meta
