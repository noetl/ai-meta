# #343 forensics — prod execution stall, captured 2026-09-15T06:47Z

Captured **before** any mutation, at the owner's instruction, so a restart cannot
destroy the evidence. Session: adiona flights/hotels deploy (ops#308, travel#121,
frontend#23 merged and registered).

## Symptom

`POST /api/execute` returns `{"status":"started","commands_generated":1}` and the
execution then **does not exist**: no server log line, no event, absent from
`GET /api/executions`. Last execution recorded anywhere: **2026-09-13T18:36Z**,
~36 h before capture.

Proved with a control: `test/simple_loop` (an untouched playbook that ran fine on
2026-09-11) behaves identically to the new `muno/playbooks/flights-details`.
Execution ids that vanished: `358131101895495680` (flights-details),
`358132027863601152`, `358140838536024064` (control).

Dispatching `358140838536024064` while tailing the server produced **37 log lines
in the window, none of them for that execution** — all six
`handlers::execute` lines belonged to the two stranded executions. **New
executions die before the publish path.** That is the new fact this capture adds
to #343.

## ⚠ Two FALSE ZEROS corrected (both mine, both in this area)

This loop's doc warns that false zeros are the recurring failure here. Two more:

1. **"The EHDB tier workload is missing."** WRONG. `kubectl get deploy,sts,svc -A
   | grep -i ehdb` returns nothing **because the workload is named
   `noetl-cmdbus-writer`**. The tier service is hosted by that StatefulSet:
   `NOETL_EHDB_TIER_SERVICE_BIND=0.0.0.0:9110`,
   `NOETL_EHDB_TIER_SERVICE_DIR=/data/eventbus/ehdb-tier`. Running 2 d, 0 restarts.
   Acting on this would have meant a **second writer against `/data/eventbus`** —
   the one-PVC corruption risk. Not done.

2. **"Nothing is listening on 9110."** WRONG. The listener bound cleanly at boot:
   `EHDB tier service listener up addr=0.0.0.0:9110 shard=0 protocol=1`. It is a
   **raw framed protocol, not HTTP** — an HTTP probe is read as a frame header and
   the connection is reset. Proof: the last two lines of `writer-current.log` are
   this session's own curls, `frame of 1195725856 bytes`, and `1195725856` is
   `"GET "` as a big-endian u32.

**Probing 9110 with curl is not a liveness test. Use the framed client.**

## Confirmed state

| Fact | Value |
|---|---|
| Writer pod | `noetl-cmdbus-writer-0`, Running, 2 d, **0 restarts**, no previous container |
| Writer process | alive — `/metrics` on 9090 → HTTP 200 |
| Writer log | **silent 2026-09-13T16:56 → 2026-09-15T06:41** (~38 h), incl. no heartbeat warnings |
| Worker pools | `cmdbus-writer`, `worker-rust-pool`, `worker-system-pool` — all heartbeat **seconds old**, `ready` |
| Frame cap | **confirmed**, 282 occurrences: `frame of 1251646 bytes exceeds the 1048576-byte cap` |
| Hot loop | 298 `Published command notification` in 20 min, only for the stranded pair |
| Stranded pair | `357600729965273088`, `357600395863793664` — also **absent** from `/api/executions` |

## Integrity baseline (verify after any restart)

/data/cmdbus, /data/eventbus, /data/eventkv are **separate ext4 PVCs** — a pod
restart preserves them.

```
/data/eventbus/ehdb-tier/eventlog.jsonl    bytes=215120526  lines=19141
/data/eventbus/ehdb-tier/catalog.jsonl     bytes=1365692    lines=20
/data/eventbus/ehdb-tier/projection.jsonl  bytes=2479294    lines=641
cmdbus_files=16204  eventbus_parts=1093
```

`eventlog.jsonl` was modified 2026-09-15T06:21 — **the tier is still being written
to**, consistent with iteration 7's "the retries DO eventually succeed".

## Reconciliation with iteration 7 (2026-09-12)

Iteration 7 left prod "healthy, sweep armed" and ruled out transport. This capture
is consistent with it and adds: the stall is **not** the tier being down, and the
frame cap (blocker 2, still unfixed) does **not** explain new executions dying —
the cap concerns mirroring one large *old* execution, whereas a brand-new
execution produces no event at all.

## Not done, deliberately

- No second writer against `/data/eventbus`.
- No frame-cap code change / image release — it is a code default (no env var),
  so it needs a release, and the root cause is still unproven.
- No PVC delete/recreate, no event-data wipe.

## Files

`writer-current.log` (313 lines, full), `writer-describe.txt`, `data-dir-before.txt`,
`integrity-before.txt`, `pvc-before.txt`, `server-recent-head400.log`.
