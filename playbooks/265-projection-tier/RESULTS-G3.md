# ai-meta#265 G3 — async projection mirror + lag window: kind gate results

**Date:** 2026-08-25 · **Cluster:** kind-noetl, 3 worker replicas + writer StatefulSet ·
**Images:** `localhost/noetl-server:265g3` (server [#356](https://github.com/noetl/server/pull/356)),
`localhost/noetl-worker:265b1` (worker **v5.121.0**).

**Prod was not touched.** Verified read-only on exit — §5.

## Result — 6 arms, 75 assertions, 0 failures

| # | arm | what it proves | result |
| :-- | :-- | :-- | --: |
| 1 | `refusal` | async ON + window **0** ⇒ the queue **refuses to arm** and stays inline | **13 / 13** |
| 2 | `armed` | async ON + a real window ⇒ arms. Only the window moved between 1 and 2 | **13 / 13** |
| 3 | `delivery` | 32 concurrent submits: `enqueued == drained`, pending → 0, tier gains exactly 32 | **13 / 13** |
| 4 | `window-in` | a behind tier, age **32 s** vs window **3600 s** ⇒ `pending_mirror`, **no divergence evidence** | **13 / 13** |
| 5 | `window-out` | the **same** behind tier, age **86432 s** vs window **30 s** ⇒ `divergent`, evidence published | **12 / 12** |
| 6 | `ahead-in-window` | a tier **ahead** of the event log, window **3600 s** ⇒ still `divergent` | **11 / 11** |

Controls `controls_ok=true`, `unexpected=0` before **and** after every arm.
Reproduce: `./run-async-gate.sh <settled_execution_id>`.

## What each claim rests on

**The pair is enforced, not documented.** Arms 1 and 2 differ in exactly one
variable — the tolerance window — and the outcome flips from
`async_enabled=0` + a logged `REFUSING to arm…` to `async_enabled=1` + a logged
`…queue ARMED`. Arm 1 also asserts the refusal did not break anything: the queue
outcome series are **present at 0**, not absent.

This is #155's "set both or neither" turned into a startup condition. Refusing
leaves the process on the inline path — correct, merely slower. Erroring out
would make a tuning mistake an outage; arming anyway would make the comparator
judge a healthy tier on its own liveness and page for it.

**Never a drop.** 32 concurrent `advance` calls → `enqueued +32`, `drained +32`,
`pending_snapshots` back to **0**, and the tier gained **exactly 32** records.
The settle is on the pending gauge, not a fixed sleep: a sleep too short reports
a drop that is really a race, which is the most expensive way this arm can be
wrong. `shutdown_abandoned` 0, `queue_full_inline` 0.

**The window forgives lateness only, and its cost is published.** Arms 4 and 5
are the *same* mutation — one revision behind, on a reset tier, with a digest
that describes its body so the checksum rule cannot fire — scored on both sides
of the window. Inside: `pending_mirror`, `crossstore_divergence_total` **did not
move**, `crossstore_pending_total{tier="projection"}` did. Outside: `divergent`,
evidence published.

That an untaken comparison publishes **no** divergence evidence is the assertion
with teeth. server#354 is the record of the same mistake on tier 1 — a probe of
an in-flight execution left `{kind="count"} 1` behind, which is ai-meta#264:
investigating with the endpoint inflates the counter its own alert reads.

**No window size forgives the dangerous case.** Arm 6 puts the tier above the
event-log tip with a 3600 s window and a *fresh* incumbent — the widest possible
opening — and the verdict is still `divergent`, with the read demoting
`version_ahead`. A mirror that has not caught up cannot produce a record
claiming an event that does not exist.

**The read path agrees with the comparator, both ways.** Inside the window the
read demotes `stale_within_window` (**non-fault**) and not `stale_version`;
outside, the reverse. `served_tier` never moves in either — a behind tier is
never served, only classified differently for alerting. That distinction is what
keeps "abort if any fault-class counter moves" usable once the async mirror is
armed.

## Harness findings (kept separate from platform findings)

Three more, each of which produced a confident wrong answer first.

1. **A metric helper that matches `# HELP` lines returns prose as a value.** The
   first `refusal` run reported `async_enabled` as **`G3).`** — the last word of
   the help text. The B1 gate never hit this because every needle there carried a
   `{outcome="..."}` that cannot appear in a HELP line; G3's gauges are
   unlabelled, so the bare name matches. Fixed with `grep -v '^#'` first.
2. **Prometheus renders labels alphabetically, not in declaration order.**
   `{tier="projection",kind="stale_version"}` matched nothing while
   `{kind="stale_version",tier="projection"}` matched a series pinned at 0 — and
   the miss read as `__ABSENT__`, i.e. as *"no divergence evidence published"*,
   which is exactly the answer the arm was asking for. **It would have passed for
   the wrong reason.**
3. **Two arms consume their own precondition.** `window-in`/`window-out` drive
   `advance` to observe the read path, and that re-mirrors the incumbent — so the
   behind-tier is gone by the arm's end. A second standalone run scored `match`
   and `served_tier +1`, correct behaviour against a tier no longer behind, which
   would have read as the window failing. `run-async-gate.sh` re-establishes each
   precondition; standalone arm runs are not valid evidence.

Plus one carried from the B1 session and hit again: `podman images -q` exits **0
with empty output** for a missing image, so `podman images -q X && echo READY`
always says READY. A build still compiling was reported as done.

## What this gate does NOT establish

- **Nothing about two servers racing.** kind runs **one** server replica, so the
  queue, its ordering guarantee and the 32-way concurrency are all *in-process*.
  Across replicas each has its own queue and two replicas mirroring one execution
  were already ordered only by their POST timing — unchanged by G3, and
  unmeasured here.
- **No latency claim.** The #155 figure quoted in the design (78.6 ms → 0.1 ms)
  is the **event log's**, measured on prod. This gate did not measure the
  projection mirror's saving, and the kind cluster — carrying a ~672k-command
  backlog — is the wrong place to try.
- **Rung 3 never fired.** `queue_full_inline` stayed 0 throughout, so the
  out-of-order path the alert is meant to catch is **untested here**. A check
  that has never fired is indistinguishable from one that cannot; it is covered
  by unit tests of the ladder, not by this gate.
- **G4's coverage counter still never fires end-to-end** (unchanged from
  RESULTS-B1.md).

## §5 — prod verification on exit

- `NOETL_EHDB_PROJECTION_MIRROR_ASYNC`, `..._PARITY_LAG_TOLERANCE_SECS`,
  `..._MIRROR_SOURCE`, `..._PARITY_ENABLED`, `..._READ_SOURCE` — **0 occurrences**
  on any prod workload.
- `NOETL_EHDB_EVENTLOG=primary` unchanged on all three worker deployments.
- Prod's own event-log async mirror (`NOETL_EHDB_EVENTLOG_MIRROR_ASYNC=true`,
  window 30 s) untouched.
