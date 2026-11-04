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

## ehdb v0.15.0 (bloom scheme 2): rollout plan, staged, not run

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
