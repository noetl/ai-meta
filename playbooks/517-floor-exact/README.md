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
4. **The prediction is SAFE**: `./predict_floor.py OUT` exits 0. It walks parts
   oldest-first reading their bytes, finds the first part that really holds a hot
   execution (= the corrected floor), and checks that every real member of every
   part below it is archived or out of coverage. Exit 2 = an unarchived execution
   would be dropped: **stop**.

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
