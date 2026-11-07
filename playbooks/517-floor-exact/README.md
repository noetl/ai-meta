# 517 — arm `NOETL_EHDB_FLOOR_EXACT` on prod

Tracks [noetl/ai-meta#517](https://github.com/noetl/ai-meta/issues/517). Staged, **not run**.

## Why

The EHDB prune floor comes from part blooms, and a bloom false positive on an old
part pins it there. Confirmed twice on prod (2026-11-03 and 2026-11-04; see #517).
The cause is in the bloom itself: the legacy probe sequence collapses for about 1 key
in 2^j, and the 2026-11-04 holder's nine probes all landed on one bit (noetl/ehdb#438
fixes the scheme for new parts). `NOETL_EHDB_FLOOR_EXACT` (noetl/server#550, in the
image since v3.149.0) replaces the floor holder's bloom extent with its exact read
extent, at most 32 reads per pass, until the lowest holder is exact. A bloom has no
false negatives, so this can only RAISE the floor, and only to where hot data really
starts.

⚠ With `NOETL_EHDB_PRUNE_ENABLED=true` (prod), the next pass drops every engine part
below the corrected floor. Those parts' executions are archived to GCS and verified;
`noetl.event` (Postgres, the authoritative log) is never touched.

## Gates, in order

1. **#516 rollout done** — it owns prod server/worker/writer rolls. Do not start
   until #516 says so. One session touches the prod server at a time.
2. **The server image carries ehdb#431** (v3.151.1 / ehdb v0.14.10 or later):
   `reclaim_orphans` runs inside `apply_retention` and, before #431, could delete a
   sealed-but-not-uploaded part after a restart. Floor-exact makes the prune act far
   more often. Read `noetl_server_build_info` off the pod.
3. **Nothing else is rolling**: STS `currentRevision == updateRevision`, no foreign
   statefulset/deployment patch or pod exec in the last 10 min (audit log).
4. **The prediction is SAFE**: `./predict_floor.py OUT` exits 0. It reads every
   part's bytes and finds the parts that really hold a hot execution. The
   corrected floor lies between the lowest such part's `min_sequence` (L) and
   their lowest `max_sequence` (U); the engine drops a part when its
   `max_sequence` is below the floor, so every part with `max < U` and no hot
   member is **at risk**. Every real member of every at-risk part must be
   archived or out of coverage.
   - Exit 2 = an unarchived execution would be dropped: **stop**.
   - Exit 3 = an at-risk part overlaps a part that stays
     ([#520](https://github.com/noetl/ai-meta/issues/520)): **stop** and decide
     #520 first.
   - A part pruned between the manifest read and the part read is tolerated only
     if it is gone from the current manifest too.
   - Kind or another pod: `POD=<pod> NS=<ns> ./predict_floor.py OUT --context kind-noetl`.

## Roll

```bash
./predict_floor.py OUT                 # must print SAFE; note droppable parts / MB
./verify_floor.py before OUT           # part ids + Postgres event counts of a sample
python3 ../516-ehdb-426-rollout/smoke.py   # e2e smoke + travel + ranch: must PASS
# image unchanged, one env var; the full-object server dry-run diff must show ONLY it:
kubectl --context noetl-prod -n noetl patch sts noetl-server-rust-embedded --type=strategic \
  -p '{"spec":{"template":{"spec":{"containers":[{"name":"noetl-server","env":[{"name":"NOETL_EHDB_FLOOR_EXACT","value":"true"}]}]}}}}' \
  --dry-run=server -o json   # diff against live, then re-run without --dry-run
kubectl --context noetl-prod -n noetl rollout status sts/noetl-server-rust-embedded
python3 ../516-ehdb-426-rollout/smoke.py   # must PASS
```

With `NOETL_EHDB_ARCHIVE_KNOWN_PERSIST=on` the first archive + prune pass follows
about 3–5 minutes after the restart. Then:

```bash
./verify_floor.py after OUT            # must print RESULT PASS
```

It checks: the floor advanced, and not past the predicted floor; every dropped part
was predicted-droppable; `noetl_ehdb_floor_refinement_total{outcome="refined"}` > 0;
sampled executions' Postgres event counts unchanged. The floor may take more than one
pass to reach the prediction (32 refinements per pass) — re-run `after` on the next
pass before calling a shortfall a failure.

⚠ If the prediction finds **0 parts at risk**, the floor is not pinned by a false
positive today, and arming will drop nothing on the first passes. `verify_floor.py
after` then fails "floor advanced" and "certain parts dropped" by construction: read
the other checks (refinement ran, no part outside the prediction dropped, Postgres
unchanged) and re-run `after` once a holder goes cold.

## Measuring false positives

`./bloom_fp_check.py` tests every part's `execution_bloom` against what the part's
bytes actually hold, for both bloom schemes (0 legacy, 2 mixed), and fails on any
false negative (the positive control). The port is checked against blooms built by
the Rust code: all inserted keys present, 1.045% false positives for a full mixed
filter (design 1%).

## Rollback

- Disable: remove `NOETL_EHDB_FLOOR_EXACT` (`{"name":"NOETL_EHDB_FLOOR_EXACT","$patch":"delete"}`),
  then smoke. The floor returns to the bloom computation; nothing already dropped
  comes back, and nothing needs to: the archive holds it and Postgres holds every event.
- On any smoke regression (travel OR ranch): disable first, then investigate.

## Afterwards

- Watch `prune pass verdict changed` lines: the floor should now follow the oldest
  hot execution, within one retention window (24 h) of it going cold — #517's goal.
- `/data` inodes and bytes should step down on the first passes.
- ⚠ Read the floor from the log line, not `noetl_ehdb_retention_floor_sequence`: the
  gauge is an f64 and drops the last digits.

## Executed 2026-11-04

**Kind, forced stall.** Fresh embedded store (`NOETL_EHDB_EMBEDDED_DIR=/data/ehdb-k517a`), archive to fake-gcs, retention 1 h, server v3.151.2.
- I ran 528 short executions and mapped their ids against every part bloom offline. Id `376400035643920384` false-hits parts 9, 10 and 18; its real records are later.
- **Flag off:** the floor stuck on part 9 (`376393609257160704`) for 6 passes. `predict_floor.py` showed part 9's members cold and the real floor at part 12.
- **Flag on:** 7, then 2 parts dropped on the first passes, and the floor then followed the real holder. `refined` went to 103 with `unreadable=0`.
- Two further `verify_floor.py` cycles passed, with 40 Postgres counts unchanged.

**Prod**, 17:24:51Z. Env-only patch, image `server-rust@sha256:166a8536…` unchanged.
- The full-object dry-run showed one hunk (env 81 → 82).
- Smoke before and after: e2e 7/7, travel PASS (17.0 s / 20.1 s), ranch PASS (6.8 s / 7.0 s).
- `verify_floor.py after`: PASS. The floor moved `376057198024859648` → `376068026316890112`, 1 archived part dropped, `refined=6`, `unreadable=0`.
- Prod had no stall at roll time. The Nov 3 false positive released at 07:47Z when its holder went cold (235 parts dropped), so on prod arming *prevents* the next stall.

⚠ **What the kind run changed in these scripts**
- `verify_floor.py` first compared against the prediction's hot set and **failed a correct roll**: executions go cold every minute, so more parts become droppable after the prediction. It now checks the invariant: every dropped part held only executions archived *now*, and none hot. `predict_floor.py` records every part's members for that check.
- With nothing at risk, the Postgres sample was empty and passed vacuously. It now samples the oldest parts too.
- `unreadable` counts one per pass while the flag is OFF. After the roll, which restarts the pod and resets the counter, any `unreadable` is a real failed read, so the check is `== 0`.
- fake-gcs crash-loops when its Service injects `FAKE_GCS_PORT=tcp://…`. Set `enableServiceLinks: false`.

## ehdb v0.15.0 (bloom scheme 2): rollout plan

> **Executed.** Release A on 2026-11-06 and Release B on 2026-11-07; see the two *executed* sections below. The plan is kept as written.

Consumers: `noetl/server` (embedded `d1_event_log`) and `noetl/worker`, which runs the user and system pools and `sts/noetl-cmdbus-writer` (both buses). Both pin ehdb v0.14.12 today.

**Release A: readers learn the format; nothing writes it.**
1. Merge noetl/server#555 (`fix:`; it is kind-validated, see its comment). Roll the server alone, with smoke before and after; rollback = the v3.151.2 digest above.
2. Bump the worker's five ehdb pins to v0.15.0 (`fix:`). Kind, then roll one deployment at a time: user pool, `noetl-worker-system-pool`, `-shard1`, then the writer, which is owner-gated. #516's order and lessons apply: patch named containers only, and wait out the system-pool `WAL chain incomplete` window.
3. Soak for at least one retention window (24 h). Until B starts, every rollback below v0.15.0 is still safe, because nothing writes scheme 2.

**Release B: writers flip, one store at a time.** Set `EHDB_BLOOM_SCHEME=2` on the process that writes the store.
1. The server's embedded store first. It is shadow and Postgres holds every event, so it carries the least risk. Check: new parts are scheme 2 (manifest), `/api/ehdb/embedded/verify` agrees, `bloom_fp_check.py` shows no false negatives.
2. Bus engines later, after B1 has soaked, by owner decision.
- **Rollback for B = unset the env** on the writer. New parts go back to legacy, and readers stay at v0.15.0 or later.

⚠⚠ **After B, no reader of that store may run below v0.15.0** while any scheme-2 part exists in it. An old reader does **not** refuse. On kind, v0.14.12 failed to decode LATEST, fell back without logging to the newest versioned manifest it could decode, re-adopted the scheme-2 parts it found on local disk with legacy blooms, and republished LATEST as a *different* v105. That was correct only because the parts were local. A substrate-only part would have left the manifest silently. [noetl/ehdb#439](https://github.com/noetl/ehdb/issues/439) tracks making that a loud refusal; **fix it before B**.

Kind v0.15.0 results: in noetl/server#555.
- Release A on a legacy store: parity 30/30, writes stay scheme 0.
- B: scheme-2 parts sized by distinct key (1,024 records → 640 bits).
- Reads spanning both formats: 3/3 and 60/60 agreed, and again after a restart.
- False positives: scheme 2 measured 3 / 1,168 (0.26%) with no false negatives. A full filter runs at about 1% by design.

## ehdb v0.15.0 Release A: executed 2026-11-06

Readers on v0.15.0 everywhere; **nothing writes scheme 2** (`EHDB_BLOOM_SCHEME` unset). Each roll was a by-digest patch of the named container only, after a server-side dry-run that showed exactly one hunk (the image).

| order | workload | image | rollback | smoke before → after (e2e / travel / ranch) |
| :-- | :-- | :-- | :-- | :-- |
| 1, 04:28Z | `sts/noetl-server-rust-embedded` | v3.151.3 AR `1a4ce455` | v3.151.2 `166a8536` | 7/7 · 18.2 → 19.3 s · 6.6 → 6.9 s |
| 2, 06:34Z | `noetl-worker-rust` | v6.11.8 `70c36c12` | v6.11.7 `3f81edaf` | 7/7 · 18.7 → 19.9 s · 6.4 → 6.1 s |
| 3, 06:50Z | `noetl-worker-system-pool` | same | same | 7/7 · 23.0 → 24.5 s · 6.2 → 6.8 s |
| 4, 07:08Z | `noetl-worker-system-pool-shard1` | same | same | 7/7 · 19.3 → 23.8 s · 6.3 → 8.1 s, back to 6.2–6.7 s by 07:24Z |
| 5, 07:34Z | `sts/noetl-cmdbus-writer` | same | same | 7/7 · 22.3 → 22.2 s · 7.0 → **FAIL**, then 4.4 / 5.9 / 5.9 s |

- **The system-pool catch-up** was light this time: 2–3 INFO `WAL chain incomplete` no-ops per pool and no stall. ⚠ That line is INFO, not WARN, and a 60 s window misses it.
- **The step-4 ranch blip** was spread across many step transitions, including in-worker execution on the user pool, and it cleared on its own. The system pools ran only 11 `__orchestrate__` commands in 30 min, so they are not on the ranch path.
- **The step-5 ranch FAIL is a writer-restart artefact (#523).** The gateway keeps execution ownership in the writer's KV (`:9107`). Its first write after the restart got `early eof`, so that one turn could never be polled. The turn COMPLETED on the server. The same thing happened on the #516 writer roll.
- **The writer took the lease** at 07:35:00Z (transitions 29 → 30). Every cursor resumed from persisted state.
- **Every writer still writes legacy blooms:** server `d1_event_log` (12 new parts), cmdbus and eventbus all show 0 `scheme`.

⚠ **Kind's writer `/data` is an `emptyDir`.** A writer roll on kind wipes the bus store and proves nothing about reopening one. Validate a writer image on a PVC: v0.14.12 → v0.15.0 → v0.14.12 → v0.15.0 on one persisted store resumed every cursor from persisted state each time (noetl/worker#395).

**Release B** can start once every reader has soaked on v0.15.0 for 24 h (from 07:34:52Z on 2026-11-06), and only after noetl/ehdb#439 is fixed. B2 also needs the owner's decision.

## Release B (`EHDB_BLOOM_SCHEME=2`): executed 2026-11-07

**Scheme 2 is live on prod.** The server's embedded stores and both buses now seal scheme-2 blooms.

### Gates, as found at 12:40Z

| gate | result |
| :-- | :-- |
| 24 h soak on v0.15.0 | ✅ about 29 h. The server and writer pods were recreated at 19:20Z on 2026-11-06 by a GKE Autopilot node drain, on the same image. |
| ehdb#439 fix in every running reader | ❌ noetl/ehdb#440 was open and unmerged, and in no build |
| rollback target safe for scheme 2 | ❌ the pinned v3.151.2 / v6.11.7 run v0.14.12, which silently mis-opens a scheme-2 manifest |

The first run stopped there. The unblock path, with authorisation:

1. **Review and merge ehdb#440 → ehdb v0.15.1** (`42374796`). `load_durable_manifest` is the only manifest decode site. The 4 new tests all FAIL with `refuse_if_newer_format` stubbed to `Ok(())`.
2. **Pre-flight against the stricter open.** Copy every prod `LATEST` and decode it with v0.15.1; all must decode, or the new reader would refuse today's store. A planted `scheme: 3` copy must FAIL, as the negative control.

   | store | version | parts |
   | :-- | :-- | :-- |
   | cmdbus `d1_event_log` | v202604 | 101,300 |
   | eventbus `d1_event_log` | v81740 | 40,868 |
   | eventkv `d4_kv` | v58 | 29 |
   | server `d1_event_log` | v4369 | 58 |
   | server `d8_runtime` | v568 | 284 |

   All five decoded; the planted copy failed.
3. **Bump and release.** worker#396 → **v6.11.9**: 954 tests. server#558 → **v3.151.4**: 1,821 tests, clippy clean. The server was rebased onto the concurrent ehgraph pin bump #557, and its lock still holds a single `ehdb-l0`. ⚠ v3.151.4 also ships the #556/#557 ehgraph embed, which is OFF.
4. **Kind**, with the CI images and the writer on a **temporary PVC**: the v0.15.1 stack, then a full B rehearsal, every step e2e 7/7.
   - Arm the server, then restart it.
   - Arm the writer, then (a) restart it, (b) un-arm it, (c) roll the image back to v0.15.0 over the scheme-2 store. In (c) the manifest advanced v124 → v142 and kept all 19 scheme-2 parts, so there was no fallback.
5. **Roll every reader to v0.15.1**, one at a time (below).
6. **Re-pin the rollback** to server v3.151.4 `6cbf2fb2` and worker v6.11.9 `f866f614`.
7. **Arm** the server, then the writer.

**Scope.** `EHDB_BLOOM_SCHEME` matters only in a process that seals parts. The worker pools have no `/data` and no PVC, so they are **not armed**.

### Rolls and arms

Each change went through `roll2.sh`: a server-side dry-run, a whole-object diff against live, and a refusal unless the diff is exactly the intended hunk (`image`, or `env: len N -> N+1`). Smoke columns are before → after.

| # | time (Z) | workload | change | e2e | travel | ranch |
| :-- | :-- | :-- | :-- | :-- | :-- | :-- |
| 1 | 15:11 | `noetl-worker-rust` | v6.11.9 `f866f614` | 7/7 | 21.5 → 21.2 s | 6.2 → 6.1 s |
| 2 | 15:20 | `noetl-worker-system-pool` | same | 7/7 | 21.2 → 20.1 s | 6.1 → 6.2 s |
| 3 | 15:31 | `noetl-worker-system-pool-shard1` | same | 7/7 | 20.1 → 20.4 s | 6.2 → 6.1 s |
| 4 | 15:43 | `sts/noetl-server-rust-embedded` | v3.151.4 `6cbf2fb2` | 7/7 | 20.4 → 21.0 s | 6.1 → 6.2 s |
| 5 | 15:51 | `sts/noetl-cmdbus-writer` | v6.11.9 | 7/7 | 21.0 → 21.8 s | **FAIL (#523)**, resamples 7.8 / 5.9 / 5.9 s |
| B1 | 16:09 | server | `EHDB_BLOOM_SCHEME=2` | 7/7 | 21.1 → 22.3 s | 6.5 → 6.0 s |
| B2 | 16:34 | writer | `EHDB_BLOOM_SCHEME=2` | 7/7 | 20.2 → 21.7 s | **FAIL (#523)**, resamples 7.7 / 7.6 / 7.5, then 8.0 / 6.2 / 6.0 / 5.7 s |

Rollback targets during the image rolls (1–5) were v6.11.8 `70c36c12` and v3.151.3 `1a4ce455`. During the arms (B1–B2) the rollback is to remove the env var on the same image.

- **System-pool catch-up was heavier than on 2026-11-06.** Pool A logged 27 `WAL chain incomplete` INFO lines over 15:21–15:28, and pool B 22 over 15:32–15:39. Both then went quiet, with 0 ERROR lines, and the e2e that straddled them completed. Pool B started only after pool A was quiet.
- **Both ranch FAILs are #523.** The gateway logged `failed to record execution owner … early eof`, and both executions are COMPLETED server-side.
- **Writer restarts:**

  | | lease transitions | fence refusals during takeover | cursors resumed (`origin=persisted`) |
  | :-- | :-- | :-- | :-- |
  | image roll (step 5) | 31 → 32 | 10 | cmdbus 409835 |
  | arm (B2) | 32 → 33 | 12 | cmdbus 410390; feed groups 588914 |

  Neither restart logged a #439 refusal.
- An audit-log scan showed two `statefulsets.patch` calls on the server at 13:41Z. They were this session's own `--dry-run=server` calls, and the revision was unchanged.

### Scheme 2 confirmed on new parts

`scheme_census.sh` reads `LATEST` off each PVC:

| store | LATEST | parts | scheme 2 | newest 5 |
| :-- | :-- | :-- | :-- | :-- |
| server `d1_event_log` | v4402 (16:25Z) | 61 | 1 | newest is scheme 2 |
| cmdbus `d1_event_log` | v203338 (16:44Z) | 101,667 | 24 | all scheme 2 |
| eventbus `d1_event_log` | v82458 (16:44Z) | 41,227 | 28 | all scheme 2 |
| server `d8_runtime`, eventkv `d4_kv` | n/a | n/a | 0 | not sealed since the arm |

The server uses `SEAL_MAX_AGE_SECS=900`, so its first scheme-2 part arrives up to 15 minutes after the arm.

`bloom_fp_check.py` compares part bytes against the bloom; the bus variant reads `/data/<bus>` and checks the scheme-2 parts plus the newest 200 legacy parts:

| store | scheme | parts | false negatives | false positives |
| :-- | :-- | :-- | :-- | :-- |
| server d1 | all | 61 | 0 | 0 |
| cmdbus | 2 | 29 | 0 | 0 / 2,460 |
| cmdbus | legacy | 200 | 0 | 63 / 16,973 = **0.37%** |
| eventbus | 2 | 33 | 0 | 0 / 2,798 |
| eventbus | legacy | 200 | 0 | 34 / 16,971 = **0.20%** |

### State after B

- server v3.151.4, armed;
- writer v6.11.9, armed;
- all worker pools v6.11.9, not armed;
- floor-exact still armed;
- every pod at 0 restarts and 0 ERROR lines; writer 132m CPU / 719Mi.

⚠⚠ **Rollback = unset `EHDB_BLOOM_SCHEME`.** Never take a reader of these stores below v0.15.0. The pinned images are v0.15.1 builds, which refuse a newer format loudly. Legacy parts age out by retention; nothing rewrites them.

The rule this rollout followed is recorded as ehdb `docs/spec/manifest-format-compat.md` (noetl/ehdb#441).
