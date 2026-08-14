# ai-meta#265 phase A — kind gate results

**Date:** 2026-08-14 · **Cluster:** kind-noetl, 3 worker replicas ·
**Images:** `localhost/noetl-worker:265proj`, `localhost/noetl-server:265proj`,
built `--network none` from [worker#277](https://github.com/noetl/worker/pull/277)
and [server#350](https://github.com/noetl/server/pull/350).

**Prod was not touched.** Verified read-only on exit: no `NOETL_EHDB_PROJECTION*`
variable exists on any prod workload, and the server image is unchanged at
`sha256:02b6ff2b…` (v3.81.1). The event-log tier stays `primary` and serving.

## Result

| gate | arm | result |
| :-- | :-- | --: |
| substrate (A1+A2) | `shadow` | **20 / 20** |
| substrate (A1+A2) | `primary` | **19 / 19** |
| substrate (A1+A2) | `demoted` | **12 / 12** |
| end-to-end (A3+A4) | `shadow` | **25 / 25** |
| end-to-end (A3+A4) | `primary` | **24 / 24** |
| end-to-end (A3+A4) | `corrupt` | **20 / 20** |
| end-to-end (A3+A4) | `drop` | **19 / 19** |
| end-to-end (A3+A4) | `bypass` | **19 / 19** |

Comparator controls: `controls_ok=true`, `unexpected=0`, `expected=9` before and
after every arm — so the zeros above are readable rather than merely absent.

## What each arm established

**Tier addressing is real and closed.** A projection append lands in
`projection.jsonl`; a full 390-record scan of the event-log store contains none
of it; appends to `kv` and `vector` are refused **400**. The isolation assertion
is not satisfied by emptiness — both stores were non-empty throughout.

**It is ONE store.** All 3 replicas returned the same record for the same
execution. That is the property the pod-local path this replaces does not have.

**`primary` reaches a serve decision** —
`noetl_ehdb_projection_ops_total{operation="mirror",outcome="served_primary"}`
moved 0 → 4 across the arms, with the shadow arm pinned at **0 and present**.
Two-sided: the only variable that moved between the shadow and primary arms was
`NOETL_EHDB_PROJECTION`, and `materialized=2` became `served_primary=1`. That
answers the [#259](https://github.com/noetl/ai-meta/issues/259) question for
tier 2.

**Demotion is loud.** With the tier-service address pointed at a black hole the
append answers **502**, records `outcome="unavailable"` (degraded) 5 times, and
`served_primary` stays 0 — it does not claim to have served.

**Cross-store parity holds against the real incumbent.** `match`, tier `version`
== authoritative `version` (a snowflake), `tier_source=service`.

**The comparator discriminates.**

| mutation | verdict | why it matters |
| :-- | :-- | :-- |
| incumbent checksum rewritten | `divergent` / **`checksum`**, and *not* `stale_version` | same version, different content — a count-based check passes this |
| projection store emptied | `divergent` / `missing_execution`, `tier_records=0` | the event log still held its 480 records, verified by the mutation itself |
| server projection mirror disarmed | `divergent` / `missing_execution` on a **fresh** execution | separates "the comparator measures the mirror" from "it measures whether anything is running" |

**Tier 1 never moved.** Every arm ended with the event-log comparator at
`match`, `auth=13 ehdb=13`. Tier 1 is `primary` in prod; if arming, corrupting or
emptying tier 2 had moved it, none of this would be safe to ship.

## Findings the gate produced

Four of these are about the platform and three are about the harness. Both kinds
are recorded, because a harness bug reported as a platform finding is the worst
way to be wrong.

### Platform

1. **A 13-event execution completes and `noetl.projection_snapshot` gets no
   row.** The orchestrator's self-write is gated on
   `total == Some(cache.applied_count)` — a throttled consistency COUNT having
   run in the same pass — and on a short execution the two never coincide. The
   3,344 rows in kind came from the background reconcile poller revisiting
   long-lived executions.

   **Consequence for the tier, and it is not small: the projection tier can only
   hold what the incumbent writes, and the incumbent writes sparsely.** A prod
   shadow soak has to measure coverage, not just divergence — "0 divergences"
   over a population the mirror was never offered is the vacuous pass this whole
   design was shaped to avoid. The gate drives
   `POST /api/internal/projection/advance` (the `system/projector` playbook's own
   endpoint, and a real call site of the same chokepoint) rather than waiting on
   the poller.

2. **`SNAPSHOT_INTERVAL_EVENTS >= 500` compares snowflake event ids, not
   counts.** Pre-existing and benign — the upsert is idempotent — but it means
   the constant's name is off by orders of magnitude as a capacity input.

3. **The tier can legitimately be AHEAD of the incumbent mid-flight.** Read
   during an execution the event-log comparator showed `auth=11 ehdb=12`: the
   mirror is faster than the settle. Not a divergence; a reason every comparison
   must settle first.

4. **The two comparators answer in different envelopes** — the event-log one
   flat (`.outcome`, `.report`), the projection one nested under `.result`.
   Worth knowing before writing an alert against either.

### Harness — each of these would have produced a green or red lie

5. **A mutation that compiled and did nothing.** The first `corrupt` ran `sed`
   over the tier store looking for `"checksum":"…"`. The store writes payloads as
   a JSON **byte array** (`"payload":[123,34,97,…]`), so nothing matched, `sed`
   exited 0, and the gate reported `match` against an unmutated store. Only
   dumping the store showed it. `corrupt` now mutates the incumbent's column and
   **verifies the value changed**, failing loudly if it did not.

6. **A positive control that checked the wrong field.** The isolation control
   read `.outcome` from an event-log body that has no such field on success. It
   now asserts a **scan** returns records, so "the event log does not contain the
   projection record" is a fact about isolation rather than about an empty store.

7. **A single sample of a distributed read.** The first end-to-end verdict came
   back `tier_unavailable` on an execution that reads `match` three seconds
   later — the relay had landed on a replica mid-rollout. The gate now retries to
   a terminal verdict and reports the attempt count.

Also: a settle floor of 10 against a 13-event probe let the loop finish early
(the [#257](https://github.com/noetl/ai-meta/issues/257) gate recorded the same
trap at 6-vs-14). The floor is now the probe's own count.

## Reproducing

```bash
cd playbooks/265-projection-tier
./deploy.sh load && ./deploy.sh writer
./deploy.sh arm shadow 3   && ./gate-substrate.sh shadow  && ./gate.sh shadow
./deploy.sh arm primary 3  && ./gate-substrate.sh primary && ./gate.sh primary
./deploy.sh point 10.255.255.1:9110 && ./gate-substrate.sh demoted
./deploy.sh point noetl-cmdbus-writer-0.noetl.svc.cluster.local:9110
./deploy.sh arm primary 3
EXEC_ID=<from primary> ./deploy.sh corrupt   && EXEC_ID=… ./gate.sh corrupt
EXEC_ID=…              ./deploy.sh uncorrupt
EXEC_ID=…              ./deploy.sh drop      && EXEC_ID=… ./gate.sh drop
./deploy.sh bypass && ./gate.sh bypass
./deploy.sh restore
```

## What is NOT proven here

- **No reader resolves projections from EHDB.** `orch_snapshot::load_latest`
  answers from Postgres in every arm. `primary` here means the *write* path
  claims authority and says so verifiably. Read-serve is phase B1.
- **Coverage in prod.** Finding 1 says the incumbent writes sparsely; what
  fraction of prod executions ever get a snapshot is unmeasured.
- **DuckDB.** The gate worker is built without `duckdb-integration` (it cannot
  be built offline). Nothing on this path touches DuckDB.
