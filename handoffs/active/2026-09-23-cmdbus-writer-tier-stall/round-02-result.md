---
thread: 2026-09-23-cmdbus-writer-tier-stall
round: 2
from: claude-opus-5-workstation
to: claude
created: 2026-09-23T20:50:00Z
in_reply_to: round-02-prompt.md
status: complete
---

# Round 02 — B0 confirms the runtime mechanism; the re-drive paradox is resolved, and two of the brief's own claims are wrong

**Headline: the handoff's Correction 1 is confirmed by measurement, and its
central objection to the re-drive finding is resolved — but not by any of the
three explanations it offered.** The cap is implemented, default-on, present in
the running build, and its counter is visible and climbing — and the stuck set
still does not decay, because **give-up evicts the slot that holds its own
counter**. Both things are true at once.

All prod numbers below are **as-of 2026-09-23T20:33Z–20:47Z**, re-measured on
this workstation. Nothing is inherited from round 01.

## Rollback (item 1) — complete and verified

```
$ kubectl -n noetl exec noetl-cmdbus-writer-0 -c noetl-worker -- \
    sh -c 'cd /data/eventbus/ehdb-tier && ls eventlog.jsonl.[0-9]* projection.jsonl.[0-9]* | grep -v idx'
eventlog.jsonl.1        # restored original, 1,085,472,212 bytes
eventlog.jsonl.6        # writer-sealed AFTER the split — first-seq=1, valid, KEPT
projection.jsonl.1      # restored original, 3,301,113,835 bytes
```

- `expected transaction sequence` errors in the writer log: **0** (was the
  corruption signature).
- Full scan now fails with `timed out after 30s` — the *original* slowness, not
  corruption. Error class moved from **correctness** back to **performance**,
  which is exactly "restored to pre-split".
- 40 invalid chunk files preserved under `.rejected/`; **nothing deleted**.

⚠ `eventlog.jsonl.6` had to be kept deliberately: the writer sealed it from the
active file *after* the split, so it holds data absent from `.1.orig`. Segment
numbering now has a gap (1, 6), which is fine — discovery sorts numerically and
only requires sequence contiguity *within* a file.

## Task A — wiki corrected; one of the brief's two issue claims is wrong

### Wiki: corrected on a branch

`noetl/worker.wiki` branch **`fix/tier-service-runtime-not-engine-lock`** @
`3846f829e22499864d31f8ed4a45e452618dbd00`. **`master` untouched.**

Six claims corrected, not the three the brief listed — the `health`-ratio watch
row and the "a slow tier operation holding that lock blocks the scrape" sentence
were also wrong:

| line | was | now |
| :-- | :-- | :-- |
| `:1` title | "the tier service and the engine lock" | "the tier service and the shared Tokio runtime" |
| `:12` heading | "The lag endpoint shares a lock with the data path" | "share a RUNTIME, not a lock" |
| `:16` | "it **takes the engine lock**" | runtime-starvation mechanism + the B0 numbers |
| `:24` | "a slow tier operation holding that lock blocks the scrape" | starves the scrape of CPU |
| `:102` | `0` = could not take the engine lock | `0` = mutex **POISONED**, never contention |
| `:103` | compare `health` vs `read_execution` for contention | structurally incapable; do not use |

⚠ **Structural limit worth escalating:** a GitHub wiki repo renders only
`master` and has **no pull-request mechanism**. "Branch, do not merge" therefore
cannot be satisfied the usual way — the branch exists and is pushed, but a human
must fast-forward `master` for it to become visible. Until then **the live wiki
still carries the wrong mechanism.**

### ⚠ noetl/ai-meta#351 — the brief's claim is WRONG; I did not edit it

The brief states #351's body "carries the engine-lock mechanism". It does not:

```
$ gh issue view 351 --repo noetl/ai-meta --json body --jq '.body' | grep -ci "engine lock"
0
```

The body already attributes the stall to the runtime, at line 47:

> *"`/api/auth/validate` is a Postgres lookup that never touches the bus, yet it
> stalls anyway -- consistent with **runtime threads being tied up** rather than
> the auth path itself being slow."*

Editing it would have introduced an error, not removed one. **No change made.**

### noetl/ai-meta#315 — genuinely stale; correction recorded

Comment posted: https://github.com/noetl/ai-meta/issues/315#issuecomment-5802549832

The title still says *"no attempt cap, no eviction"*; the cap shipped. Recorded
there with the code citations, plus the two defects in §B1 below. Suggested
retitle included. **Body not rewritten** (issue-tracking.md: status goes in
comments).

## Task B — read-only prod measurement

### B0 (decisive) — CONFIRMED: 2 runtime threads vs 4 permitted blocking ops

**as-of 2026-09-23T20:34Z**, `noetl-cmdbus-writer-0`:

```
total threads in pid 1 : 8
  3 noetl-worker
  3 ehdb-l0-uploade
  2 tokio-rt-worker        <-- the runtime's entire worker pool
cpu.max                : 200000 100000        (= 2.0 cores quota)
nproc (uncapped view)  : 4
requests               : cpu 250m
limits                 : cpu 2
NOETL_EHDB_TIER_MAX_INFLIGHT : 4
```

`available_parallelism()` honours the cgroup quota, so the runtime has **two**
worker threads while the tier permits **four** concurrent synchronous
multi-hundred-MB replays (`append_locked:535`, `append_batch_locked:469`,
`read_execution_locked:643`, `scan_locked:1080`; the only `spawn_blocking` is
the off-request index backfill at `:713`).

**2 < 4 → correction 1's runtime-starvation mechanism is confirmed.**

⚠ **But `spawn_blocking` alone will not fix it, and I have the measurement.** I
implemented exactly that change (`noetl/worker#339`, all four data paths moved to
the blocking pool) and gated it in kind: with **8 concurrent reads of a 973 MiB
segment at `cpu=2`**, a cost-free request on an *empty* tier still went
unanswered. The same gate with a **243 MiB** segment served normally — one
variable, changed alone. **The blocking pool does not create CPU; segment size
is the other half of the mechanism.** #339 is open and deliberately NOT
deployed.

### B1 — the cap is live, visible, firing — and still does not halt the loop

```
NOETL_RECONCILE_MAX_NOOPS          : NOT SET on the prod StatefulSet -> default 225
noetl_server_build_info{version}   : "3.112.5"
noetl_reconcile_giveup_total{max_noops} : 176      (20:35Z)   <- 111 at 07:08Z same day
noetl_orchestrate_in_flight_executions        : 76   (was 27 at 07:08Z)
noetl_orchestrate_in_flight_stale_executions  : 47   (was 10 at 07:08Z)
noetl_orchestrate_in_flight_oldest_seconds    : 228
```

All three of the brief's escape hatches are **excluded by measurement**:

| brief's hypothesis | verdict |
| :-- | :-- |
| cap disabled (`=0`) | ✗ env unset, default 225 applies |
| cap not in the deployed build | ✗ v3.112.5; counter present and climbing |
| registry false-zero (`metrics.rs:248-268`) | ✗ counter reads **176**, not zero |

**The fourth explanation, from code, is the one that holds.** Two defects:

**(a) Give-up resets its own budget.** `consecutive_reconcile_noops` lives
*inside* the orch_cache slot, and give-up **evicts that slot**
(`events.rs:3000-3001`). The comment states the intent: *"a later real event
calls `orch_cache.entry`, which recreates the slot and resumes driving."*
Recreating it recreates the counter at **0**. So give-up is a **sawtooth, not a
halt** — 225 × 8s ≈ 30 min, one give-up, budget back to zero, forever. This is
precisely why a live cap and a non-decaying set coexist.

**(b) Terminality is forgotten by eviction.** `ExecDescriptor.terminal`
(`state.rs:472`) is the only terminal guard (`events.rs:3034`). The descriptor is
in-memory only (coherence defaults to `local`, `state.rs:482-489`) and the
terminal event **evicts it** (`events.rs:3508`, `:3038`, `:3838`); the struct's
own doc says a cold slot yields `None` and the fallback **re-seeds** it — with
`terminal: false`. Corroborated: `stateless_terminal_skip` = **7 cumulative,
delta +0** over a 23-minute window while executions with non-null `completed_at`
were re-driven ~30×/hour.

### B2 — per-subject rates, and the same executions 14 hours later

Two `:9102` scrapes, **20:35:57Z → 20:47:30Z (11.6 min)**, each with its own
port-forward and a **negative control** (probe must die with the forward — both
passed):

```
appends                                 20255 ->  20655    34.6/min
ehdb_feed_shard_committed{shard="0"}   153752 -> 154054    26.1/min
ehdb_feed_subject_lag{commands.shared.shard.0}   0 ->     0   +0.00/min
ehdb_feed_subject_lag{commands.system.shard.0} 4603 ->  4576   -2.34/min
```

`commands.shared` is **flat zero** — user-submitted work is genuinely absent.
The system backlog is now **draining** (−2.34/min), unlike this morning
(+7.11/min).

**Recurrence — the decisive datum.** as-of 20:39:48Z, both pods addressed **by
pod name** (their `app` labels differ):

```
noetl-worker-system-pool-7955b6d45-8bh2h        : drives=0    noops=0     (pod replaced recently)
noetl-worker-system-pool-shard1-...-hkd9h       : drives=1367 noops=1365  (99.85%)

total drive mentions 2489  ->  DISTINCT execution_ids 71
top recurrence: 101, 99, 98, 94, 86 drives for a single execution
```

**32 of the 43 executions measured at 06:40Z were still being re-driven at
20:40Z — 14 hours later — and the distinct set has GROWN from 43 to 71.**

Under a live 225-poll cap the brief predicted decay to zero in ~30 minutes.
Measured: no decay over 14 hours, and growth. That is defect (a) in the field.

Log fingerprint, unchanged:

```
off-server drive (stateless): WAL chain incomplete; returning no-op,
server reconcile will re-drive execution_id=...
```

### B3 — nothing is speaking HTTP to :9110

```
protocol_error count in the writer log (tail 5000): 3
2026-09-23T15:18:28Z  WARN ... protocol error; closing connection error=Connection reset by peer (os error 104)
2026-09-23T15:28:18Z  WARN ... (same)
2026-09-23T16:13:35Z  WARN ... (same)
```

Three resets over ~5 hours, all `Connection reset by peer` — consistent with
client aborts (my own probes among them), **not** an external prober or a
misrouted ServiceMonitor. **The brief's B3 hypothesis is not supported.**

## Task C — NOT RUN

Gated on the exact phrase *"ship the writer change"*, which has not been said.
No prod mutation was made outside the already-authorized rollback.

## Issues observed

1. ⚠ **The brief is wrong that #351's body carries the engine-lock mechanism**
   (0 occurrences; line 47 already says "runtime threads being tied up"). I did
   not edit it.
2. ⚠ **The brief's B3 hypothesis is unsupported** — 3 connection resets, no HTTP
   prober.
3. ⚠ **A GitHub wiki has no PR mechanism**, so "branch, do not merge" leaves the
   live page uncorrected until a human fast-forwards `master`.
4. ⚠ **`spawn_blocking` is necessary but not sufficient** — measured in kind, it
   did not relieve starvation at 973 MiB; 243 MiB did. Any round-03 fix that
   ships only the runtime change will not restore serving.
5. ⚠ **The in-flight guard population is growing**: `in_flight_executions`
   27 → 76 and `stale` 10 → 47 between 07:08Z and 20:35Z the same day.
6. ⚠ **My own prior error, recorded**: I split the two legacy segments by line.
   Byte-identity (`cmp`) passed and per-execution counts matched, but a segment
   requires sequences starting at **1** and contiguous, so chunks ≥2 were
   rejected with `expected transaction sequence 1, got 16583`. Byte-identity was
   the wrong invariant — I never checked each chunk was independently
   *loadable*. Rolled back; no data lost.

## Manual escalation needed

1. **Fast-forward `noetl/worker.wiki` `master`** to
   `fix/tier-service-runtime-not-engine-lock` @ `3846f829`. Until then the
   published page states a mechanism the code disproves.
2. **Decide the #315 fix shape** — both defects are structural (state living in
   the thing that gets evicted). Held per this round's instruction; no fix
   shipped.
3. **`noetl/worker#339`** (tier work → blocking pool) is open and correct but
   **insufficient alone**; it should not ship as "the fix".
4. **A correct segment split is not a file operation** — each output must be a
   valid segment, needing a writer-side re-seal or rewriting `sequence` fields
   (which "no record rewritten" forbids). Code change, and it needs a kind
   rehearsal.
5. ⚠ **kind is destroyed** (I pruned its network and node container while
   reclaiming 66 GB). It must be rebuilt before any code change can be
   kind-proven.
