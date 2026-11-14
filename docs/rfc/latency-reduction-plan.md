# Build plan: cutting per-step orchestration latency from ~0.95 s toward < 10 ms

Companion to [`bot-fleets-vs-shared-account-vm.md`](bot-fleets-vs-shared-account-vm.md) §7.0, the analysis (ai-meta
PR #556). §7.0 attributes the overhead from measured data; this page turns its ranked fixes into PR-able stages.
Written 2026-11-13 against `main` of server `983e36e`, worker `d1c9584`, tools `c2e75ee`.

**Rules for every stage**
- One feature per branch and PR.
- Flag-gated, OFF by default. With the flag off, behaviour is byte-identical.
- Kind first.
- Accepted only on a **before/after measurement** from the Stage 0b harness (n ≥ 10 per arm, p50 and p95, both
  reps reported). #319 is why: twice, a number from one sample or from a constant in the source was published and
  then refuted.
- **No stage enables anything in prod while the owner is away.** The single exception is Stage 0, which changes no
  behaviour and waits on the owner's own `GRANT`.

**Validation matrix for every stage.** Every stage that touches the dispatch path must pass, flag on, against all of
these:
- the 10-hop probe;
- `shastaranch/concierge/turn`;
- a travel planner turn;
- **the auth/login multi-hop path, which has a hard 15 s gateway budget.**

The 2026-06-29 login outage (#156) came from a dispatch-path change validated only against the planner.

## The stages

| Stage | Issue | What | Repos | Flags (default off) | Effort | Depends on | Expected orchestration per step | Expected per awaited hop |
|---|---|---|---|---|---|---|---|---|
| **today** | — | — | — | — | — | — | **~0.95 s** (MEASURED prod 2026-11-02, n=4) | ~3–5 s predicted; 9–15 s MEASURED 2026-08 |
| **0** | [#283](https://github.com/noetl/ai-meta/issues/283) | apply the `noetl.command (event_id)` index on prod | prod DB (script in `noetl/noetl`) | none | S | the owner's `GRANT` | ~0.9 s: tens of ms per claim on prod (not kind's 500 ms; see below), and the cost stops growing with the table | same |
| **0b** | [#557](https://github.com/noetl/ai-meta/issues/557) | commit the benchmark harness | ai-meta | none | S | — | measures; changes nothing | measures |
| **1** | [#558](https://github.com/noetl/ai-meta/issues/558) | worker drives its own next step | worker, server (orchestrate-core) | `NOETL_WORKER_LOCAL_DRIVE`, `NOETL_SERVER_ADVANCE_API` | L | 0b | **~0.15–0.3 s** | child steps × that + ~0.15 s submit + U(0, 2) s poll |
| **2** | [#559](https://github.com/noetl/ai-meta/issues/559) | push completion; free the slot while waiting | server, tools, worker | `NOETL_EXECUTION_WAIT`, `NOETL_PLAYBOOK_AWAIT_PARK`, `NOETL_CATALOG_REMOTE_PUSH` | M (2a) + L (2b) | 0b; 2b with coroutines stage 1 (#554) | unchanged | **no poll term** (−1 s mean, −2 s max); slot returned |
| **3** | [#560](https://github.com/noetl/ai-meta/issues/560) | EHDB as the state substrate (PR #355) | ehdb, server, worker | #355's `NOETL_EHDB_EXEC_SEQ` / `_EXEC_INDEX`, `NOETL_CHAIN_WALK_BUILDER`, `NOETL_RECONCILE_ON_READ_FAIL`; new `NOETL_EHDB_AUTHORITATIVE_EVENTS` | L, multi-PR | #355 accepted; 0b | **~0.1–0.25 s**; the 7–10 min post-roll stall and the reconcile tail gone | same, minus stalls |
| **4** | [#561](https://github.com/noetl/ai-meta/issues/561) | fuse deterministic step chains into one compiled WASM run | server, worker, catalog | `NOETL_FUSED_SEGMENTS`, `NOETL_INLINE_PURE_PLAYBOOKS`, `NOETL_WASM_POOL`, `NOETL_CATALOG_WASM_ARTIFACTS` | L | 0b; composes with 1 | **< 10 ms per fused step**; one boundary (Stage 1 cost) per segment; 0 at the edge | a pure child hop → a function call |
| **5** | [#562](https://github.com/noetl/ai-meta/issues/562) | warm floors on latency-sensitive pools; scale-to-zero only on cost pools | ops | none (manifests) | S–M | 0b | unchanged per step; removes the 60–90 s node wait on the first step of a burst | — |

**The budget progression, cumulative, orchestration per step.** All figures except "today" are TARGET arithmetic from
§7.0 and are re-measured at each stage.

```
today     ~0.95 s   (MEASURED, prod 2026-11-02)
Stage 0   ~0.9  s   claim query ~54 ms → ~1 ms on prod; growth with table size removed
Stage 1   ~0.15–0.3 s   one hand-off per step instead of two
Stage 3   ~0.1–0.25 s   per-emit Postgres INSERT off the hot path; scoped chain reads
Stage 4   < 0.01 s per fused step inside a segment; 0 for steps run at the edge
Stage 2   (hops)  no 0–2 s poll per awaited/delegated hop; parent slot freed
Stage 5   (bursts) no pod/node start on interactive pools
```

**Worked example: `concierge/turn`** (7 steps, 1.84 s of tools, p50 8.69 s today).

| After | Turn | Reply ready |
|---|---|---|
| today | 8.69 s | ~4.3 s |
| Stage 1 | **~3.6 s** | — |
| + Stage 4 (the three post-reply logging steps fused) | ~3.1 s | **~2.1 s** |

After Stage 4, the 1.2 s model call is the largest term.

**Order.** 0 and 0b now. Then 1 and 2a in parallel; they touch different code paths. Then 4, which reuses Stage 1's
continuation at segment boundaries. 3 runs as its own track, on #355's phase order. 2b follows coroutines stage 1.
5 can land in kind at any time.

---

## Stage 0: apply the claim index on prod (needs the owner)

**What it fixes.**
- `POST /api/commands/{event_id}/claim` resolves the command by `event_id` alone. It does so three times in the
  handler, `server/src/handlers/events.rs:893, 966, 990` (REAL at `983e36e`).
- `noetl.command` is HASH-partitioned on `execution_id`, and every index leads with that column. So the lookup is a
  parallel seq scan of all 16 partitions.
- The index (`noetl/noetl#696`, merged 2026-08-18) has never been applied to prod.

**Expected impact. Honest, and smaller than kind.**
- In kind, the index took the 10-hop probe from 20.7 s to 4.3 s, and issue → claim from 559 ms to 60 ms, with
  buffers per claim going from 88,199 to 31.
- **On prod the same query measured ~54 ms, not ~295 ms**, because the heap is fully cached (#283, 2026-08-20).
  **Do not expect the 559 → 60 ms shape on prod.**
- Expect:
  - the claim query going from ~54 ms to ~1 ms;
  - issue → claimed p50 dropping by tens of milliseconds;
  - the claim cost no longer growing with the table.
- That is a correctness-of-plan and scaling fix, worth roughly 1–5 % of a turn today. It is still the cheapest fix
  on this page.

**Privilege state** (verified 2026-08-20, #283):
- `noetl.command` is owned by `postgres`, and `noetl` is not a member.
- `CREATE INDEX` as `noetl` fails with `must be owner of table`.
- pgbouncer runs in transaction mode and cannot carry `CONCURRENTLY`. The session-mode path is the cloud-sql-proxy
  sidecar in the `pgbouncer` pod (`127.0.0.1:6432`).

### Option A (recommended): run it as the owner, with no privilege change

Connect as `postgres`, the table owner, in a session that autocommits each statement, and run
`scripts/db/add_command_event_id_index.sql` from `noetl/noetl`.
- This leaves no standing privilege behind.
- ⚠ If Cloud SQL Studio wraps statements in a transaction, `CONCURRENTLY` fails with
  `cannot run inside a transaction block`. In that case use `psql` as `postgres` through the proxy, or Option B.

### Option B: the exact grant from #283, then revoke it

1. **Grant.** Cloud SQL Studio, as a superuser-capable admin:

   ```sql
   GRANT postgres TO noetl;
   ```

   This grants `noetl` everything `postgres` has. Revoke it in step 6. #283's narrower alternative is
   `ALTER TABLE noetl.command OWNER TO noetl;`.
2. **Pre-checks**, read-only, through the session-mode path:

   ```bash
   kubectl -n postgres exec -it deploy/pgbouncer -c pgbouncer -- psql -h 127.0.0.1 -p 6432 -U noetl -d noetl
   ```

   ```sql
   SELECT count(*) FROM pg_inherits WHERE inhparent = 'noetl.command'::regclass;   -- expect 16
   SELECT to_regclass('noetl.idx_command_event_id');                               -- expect NULL (absent)
   ```

3. **Baseline**, before.
   - The query plan:

     ```sql
     EXPLAIN (ANALYZE, BUFFERS)
       SELECT execution_id FROM noetl.command
        WHERE event_id = (SELECT max(event_id) FROM noetl.command_p00);
     -- expect: Parallel Seq Scan over the partitions, ~54 ms, tens of thousands of buffers
     ```

   - Record the worker's `noetl_worker_command_pickup_phase_seconds{phase="outcome"}` (the claim round trip).
   - Run the Stage 0b harness's issue → claimed p50/p95 over ≥ 10 executions. If #557 hasn't landed yet, use the
     concierge driver.
4. **Apply** online. The script builds each partition's index `CONCURRENTLY`, creates the parent `ON ONLY` and
   attaches all 16. Run it autocommit; never wrap it in `BEGIN`/`COMMIT`:

   ```bash
   kubectl -n postgres exec -i deploy/pgbouncer -c pgbouncer -- \
     psql -h 127.0.0.1 -p 6432 -U noetl -d noetl -v ON_ERROR_STOP=1 -f - \
     < scripts/db/add_command_event_id_index.sql
   ```

   It uses the credentials the container already has. Never paste a password into chat or a command line.
5. **Verify**:

   ```sql
   SELECT c.relname, i.indisvalid
     FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
    WHERE c.relname = 'idx_command_event_id' OR c.relname LIKE 'command_p%\_event_id_idx'
    ORDER BY 1;                                   -- expect 17 rows, all indisvalid = t
   ```

   Then re-run step 3's `EXPLAIN`. Expect an `Index Scan using command_pNN_event_id_idx`, ~1 ms and tens of buffers.
   Repeat the pickup-phase metric and the harness, and record before and after on #283.
6. **Revoke**:

   ```sql
   REVOKE postgres FROM noetl;
   ```

### Rollback

```sql
DROP INDEX noetl.idx_command_event_id;   -- cascades to the 16 attached partition indexes
```

- ⚠ The script's header says `DROP INDEX CONCURRENTLY` reverses it. **That is wrong for this index.** PostgreSQL
  cannot drop an index on a partitioned table `CONCURRENTLY`.
- The plain `DROP` takes a brief `ACCESS EXCLUSIVE` lock on `noetl.command` and its partitions. It is a catalog
  change plus file unlinks, so it is quick, but it blocks command writes for that moment. Do it in a quiet window.
- The index changes plans only, never results, so a rollback has no data effect.
- The script's comment should be corrected in `noetl/noetl` (tracked on #283).

---

## Stage 0b: benchmark harness ([#557](https://github.com/noetl/ai-meta/issues/557))

| | |
|---|---|
| Repo | ai-meta, `playbooks/latency-bench/` |
| What | the 10-hop probe (trivial python steps); an N-step noop/rhai chain; a parent → child await hop; a cross-instance delegate hop; drivers for concierge, auth/login and planner; `report.py` (per-transition p50/p95 from `GET /api/executions/{id}` events: issued→claimed, completed→step.enter, started→call.done, wall clock); metric scrapes of `noetl_event_ingest_phase_seconds`, `noetl_worker_command_pickup_phase_seconds` and `noetl_worker_state_builder_build_duration_seconds` |
| Effort | S |
| Verify | runs on kind and read-only on prod; reproduces today's ~0.95 s per step at n ≥ 10, and splits the ~0.46 s and ~0.33 s segments by phase **before** Stage 1 is designed in detail |

## Stage 1: worker drives its own next step ([#558](https://github.com/noetl/ai-meta/issues/558))

| | |
|---|---|
| Repos | worker (`executor/command.rs`, `state_builder.rs`); server (`orchestrate-core`, `handlers/events.rs`) |
| Today (REAL) | step N completes → the server triggers a drive → `__orchestrate__` is dispatched as a command to the system pool → claimed → state served from the in-memory WAL index → WASM drive → the server issues step N+1 → a user-pool worker claims it. **Two hand-offs per step** (#155: 79 % of a probe turn). |
| Change | (1) Each command carries the execution's drive-state snapshot, or a result-store reference when it is above `NOETL_COMMAND_CONTEXT_MAX_BYTES`. (2) The completing worker applies its own tail and runs the orchestrate WASM in-process. (3) It calls a new `POST /api/executions/{id}/advance`, which compare-and-sets the execution head (one driver per execution, generalising the single-drive guard), persists the events, issues the next commands, and returns any same-pool command **already claimed** for this worker when it has a free slot. (4) A head mismatch, oversized state or any error falls back to today's path. |
| Flags | `NOETL_WORKER_LOCAL_DRIVE` (worker), `NOETL_SERVER_ADVANCE_API` (server) |
| Effort | L |
| Risks | two drivers racing (prevented by the head compare-and-set); state-snapshot size; **the #156 lesson**: tail-attach was output-equivalent on the planner and broke auth. The validation matrix above is mandatory. |
| Expected | the ~0.46 s + ~0.33 s hand-off segments → ~0.1–0.2 s; **~0.15–0.3 s per step** |
| Verify | the 10-hop probe and concierge before and after (n ≥ 10, p50 and p95); identical event sequences and terminal values with the flag on and off; auth/login well under 15 s; a fallback counter, so the fast path is proven to be taken and is not a silent no-op |

## Stage 2: push completion, free the slot ([#559](https://github.com/noetl/ai-meta/issues/559))

| | |
|---|---|
| Repos | server, tools (`src/tools/playbook.rs`), worker |
| Today (REAL) | the `kind: playbook` await polls every 2 s (`playbook.rs:463`, configurable, minimum 1) **holding the parent's slot**; the cross-instance delegate polls B through A every 2 s (RFC §12) |
| 2a (M) | `GET /api/executions/{id}/wait?timeout=s` long-poll, woken by an in-memory broadcast on the terminal event; tools uses it when the server advertises it. B pushes a signed `catalog.completion` to A's call row instead of A polling. |
| 2b (L) | the parent step emits `command.parked` and releases its slot. The child's terminal event makes the server issue a continuation command for the parent step, carrying the child's result (the `kind: container` callback shape). The same mechanism lets a hosted agent loop park between model calls, which makes it resumable. |
| Flags | `NOETL_EXECUTION_WAIT`, `NOETL_PLAYBOOK_AWAIT_PARK`, `NOETL_CATALOG_REMOTE_PUSH` |
| Expected | −1 s mean / −2 s max per awaited or delegated hop; one signed request per delegated call instead of one every 2 s; the awaiting parent's slot is returned (the resource model's same-pool `deadlock_note` goes away) |
| Verify | hop benchmarks (child completion → parent `call.done`); N awaiting parents on a 4-slot pool complete without deadlock; the delegate kind e2e (`ops/ci/kind/e2e_catalog_remote_exec.sh`) still 50/50 with push on |

## Stage 3: EHDB as the state substrate ([#560](https://github.com/noetl/ai-meta/issues/560))

| | |
|---|---|
| Repos | ehdb (`ehdb-l0` chain store), server, worker |
| Design | PR #355 `ehdb-execution-partitioned-event-store.md` §8, phases E0 → E7, in its order: **E0 instrument first**, then E2 `exec_seq`, E3 point index, E4 chain-following builder, E5/E6 retire re-drive and the cap. Then a single-write phase, beyond #355: the execution partition becomes authoritative and the Postgres `noetl.event` INSERT goes off the hot path (`postgres-to-ehdb-internal-data.md`). |
| Flags | #355's `NOETL_EHDB_EXEC_SEQ`, `NOETL_EHDB_EXEC_INDEX`, `NOETL_CHAIN_WALK_BUILDER`, `NOETL_RECONCILE_ON_READ_FAIL`; new `NOETL_EHDB_AUTHORITATIVE_EVENTS` |
| Effort | L, multi-PR |
| Does not fix | the hand-offs (Stage 1), polling (Stage 2), cold starts (Stage 5), or the ~4 ms per-append `fsync` (group commit is the owner's durability decision, ehdb#322) |
| Expected | −0.05–0.1 s per step from the removed INSERT (~15–20 ms × ~3 emits); the 7–10 min post-roll stall and the reconcile tail gone |
| Verify | E0's scanned/returned ratio before and after; chain read flat as N grows 10× (#355 P1/P2, with its positive control); time from a system-pod restart to its first served drive; the 10-hop probe |

## Stage 4: fused deterministic segments, in the worker and at the edge ([#561](https://github.com/noetl/ai-meta/issues/561))

| | |
|---|---|
| Repos | server (orchestrate-core segment analysis; `plugins/playbook-wasm`), worker (segment executor; WASM instance pool), catalog (compiled modules by digest) |
| Change | (1) orchestrate-core marks maximal deterministic segments: pure steps plus routing, one pool, no side-effecting tools. (2) One command per segment. (3) The worker runs the compiled segment in-process and emits the per-step events as one batch, so the event log keeps per-step granularity. (4) A pure `kind: playbook` child is inlined as a module call. (5) A wasmtime pooling-allocator instance pool replaces the per-process `Mutex<WasmDispatcher>` (`command.rs:163`). (6) The catalog serves compiled modules by digest for edge hosts (the kuksin.us pattern). |
| Flags | `NOETL_FUSED_SEGMENTS`, `NOETL_INLINE_PURE_PLAYBOOKS`, `NOETL_WASM_POOL`, `NOETL_CATALOG_WASM_ARTIFACTS` |
| Effort | L |
| Expected | **< 10 ms orchestration per fused step**; one Stage 1 boundary per segment; a pure child hop becomes a function call; 0 cluster overhead at the edge |
| Verify | the N-step chain: wall clock flat in N inside a segment; event-log equivalence with the flag on and off; kuksin.us parity (`wasm/cases.py`, `wasm/parity.mjs`); concurrent WASM steps on one pod run in parallel (they serialise today) |

## Stage 5: warm floors where latency matters ([#562](https://github.com/noetl/ai-meta/issues/562))

| | |
|---|---|
| Repo | ops (`ci/manifests`, KEDA ScaledObjects) |
| Today (DEPLOYED) | user pool KEDA 2–20; system pool fixed 1 + 1 (its 3–10 ScaledObject not applied); a node takes ~60–90 s |
| Change | an interactive pool (concierge, auth, chat) with a warm floor ≥ 2 and WASM pre-compiled behind `/readyz`; batch and agent pools scale to zero; the system-pool ScaledObject applied; interactive playbooks routed to that pool's subject |
| Effort | S–M; no flags, manifests only |
| Expected | interactive first-step latency stays at the ~138 ms unsaturated issue → claim; no pod or node start in front of a user's turn |
| Verify | `playbooks/load-test/run-load-curve.sh` with a settle interval between levels (the #319 rig defect fixed first); time-to-first-claim after 30 min idle, per pool; KEDA ramp and scale-down times (currently `not_yet_measured`) |
| Prod | kind first; no prod manifest change while the owner is away |

## Decisions that need the owner

1. **Stage 0:** Option A (run the script as `postgres`) or Option B (`GRANT postgres TO noetl;`, apply, `REVOKE`).
2. **Stage 3:** accept PR #355 as the design.
3. **ehdb#322:** group commit is a durability trade. It is outside this plan's latency budget, but it caps throughput.
4. **Any prod enablement** of Stages 1–5. None happens without an explicit go-ahead.
