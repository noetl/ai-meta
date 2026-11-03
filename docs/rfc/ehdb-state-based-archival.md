# State-based archival: archive when the work is done, not when a clock expires

**Status: proposal. Design only. Nothing built, nothing changed on prod.**
Tracking: [#506](https://github.com/noetl/ai-meta/issues/506).
Builds on [#459](https://github.com/noetl/ai-meta/issues/459) (the archive tier) and serves the
[#455](https://github.com/noetl/ai-meta/issues/455) north star.

Measurements are from prod on 2026-11-02 and 2026-11-03 (server v3.147.0). Code references are to
that tag.

---

## Summary

**The idea.** EHDB keeps a working copy of every playbook run's events. Today that copy leaves
EHDB mainly because a timer ran out. We propose that it leaves because the run has finished: once a
run is complete and nothing can still touch it, its events go to cheap long-term storage (GCS) and
its local space is freed. Runs that may wake up later, such as those waiting on a callback, are
handled separately.

**Why it matters.**

- **Cleanup follows the work.** A 13-second run should not hold space for 48 hours.
- **One store has no cleanup at all.** The chain store only grows, and it is close to a hard limit
  (section 2).
- **Fewer runs hold back cleanup.** About 484 finished runs are currently kept "hot" only because
  their 48 hours have not passed.

**What this does not do.** `noetl.event` in Postgres stays append-only and is never purged. It
remains the source of truth, so no history is lost and GCS does not become the only copy.

**The main decisions we need** are in section 10. The most urgent is section 2, which does not
wait for this design.

---

## 1. What the survey changed in the original idea

The idea holds up, with five refinements.

| Original framing | What the code and prod show | Consequence |
|---|---|---|
| Retention relies on a TTL | Archival already requires a **terminal status and 48 h of age** (`event_archive.rs`, `archivability()`) | Replace the 48 h clock, not the mechanism. The archive, verification and floor already exist |
| Archive to GCS on finish | Chain store contents are rebuilt from the log (`populate_from_log`) | Chain data is **deleted**, not archived |
| Finished means cleanable | A part mixes many executions, and only the **floor** frees disk | Archiving alone frees nothing; it only allows the floor to move |
| Applies to all EHDB stores | The writer tier has live readers reaching back about 3 h and no view of execution state | The writer tier stays time-based |
| No clock at all | Events can arrive after terminal; the code has a post-terminal straggler path (`events.rs`) | Keep a short **settle window**, measured rather than guessed |

---

## 2. ⚠ Urgent and separate: the chain store is about to run out of inodes

This is the strongest argument for the RFC, but **it cannot wait for the RFC**.

| Measurement | Value |
|---|---|
| `/data` inodes | **599,603 of 655,360 (91%)**, 55,757 free |
| `/data` bytes | 32%, which is why nothing has alerted |
| `/data/ehdb-chain` | 587,625 files, 2.3 GB, about 3,580 executions |
| Files changed in the last 24 h / 48 h / 72 h | 16,428 / 39,331 / 54,687 |
| Long-run growth | 170,118 files on 2026-10-09, so about 17k a day |
| **Projected exhaustion** | **About 3.3 days from 2026-11-03 00:37Z, so around 2026-11-06** |

The 24 h to 72 h counts use modification time, so rewritten files count too. The long-run figure
agrees with them.

**The volume's byte alert cannot see this.** The "persistent volume over 70% full" policy reads
bytes, and no committed alert policy mentions inodes.

**The effect at exhaustion is untested.** The chain store and the embedded engine share this
volume, so both would be unable to create files. Whether that reaches user requests is unknown.
Prod's `NOETL_CHAIN_SOURCE=chain` means chain reads are on the advance path, so this should not be
assumed harmless.

**Options, each needing an owner go:**

1. **Expand the PVC online.** There is precedent (#491 went from 20 to 50 Gi with no restart). ext4
   normally adds inodes when it grows, but this was not measured on that resize, so check on kind
   first. This buys time and is the fastest.
2. **Delete chain directories of long-finished executions** (phase 1 below). This is the real fix,
   but it needs an ehdb or server change, so it is unlikely to land before the limit by itself.
3. **Add an inode alert** in either case.

Recommendation: option 1 now, option 3 with it, and option 2 next. Growing bytes treats the symptom
only, so the trigger for option 2 should not move.

---

## 3. Today's mechanisms

| Store | Location | Role | Cleanup today | Trigger |
|---|---|---|---|---|
| `noetl.event` | Postgres | Source of truth; serves `GET /api/executions/{id}` | None, by rule | n/a |
| Embedded engine | Server `/data/ehdb-embedded`, 860 MB | **Shadow**: read only by its writer, the parity verifier and the archive | Archive to GCS, then prune parts below a floor | Terminal + 48 h |
| Chain store | Server `/data/ehdb-chain`, 2.3 GB | Advance path | **None** ([#503](https://github.com/noetl/ai-meta/issues/503) left this open) | None |
| Writer tier | Writer `/data/eventbus/ehdb-tier`, 5 GB | Parity, repair, recovery, catalog | Delete whole segments, no archive ([#491](https://github.com/noetl/ai-meta/issues/491)) | Segment age 49 h |

**What holds cleanup back.** `noetl_ehdb_archive_scan_examined` was 9,965 and `..._archivable` was
9,481, leaving 484 not archivable. That matches the log's "483 executions must stay hot". Of the
newest 1,500 executions, 496 had completed within 48 h and **none were non-terminal**. So nearly
all of that hot set is finished work waiting on the clock.

**An unexplained floor.** The floor has not moved since 2026-11-01 02:18Z and is about 6 days old,
although the oldest of those 496 started on Oct 31. So the hot set alone does not explain it. A
plausible cause, **not proven**, is `hot_footprint`: it matches executions to parts by bloom filter,
and a false positive lowers the floor by design. The chance of one rises with the number of hot
executions, so a smaller hot set should help either way. Phase 0 tests this.

---

## 4. Design

### 4.1 Definition of finished: the quiescence check

An execution is ready only when **all** of these hold. Any unknown answer means "not ready" and
records a reason.

| # | Condition | Why | Source |
|---|---|---|---|
| Q1 | Event-derived status is terminal, with a `completed_at` | Existing rule. `noetl.execution.status` is frozen and must not be used ([#235](https://github.com/noetl/ai-meta/issues/235)) | `archivability()` |
| Q2 | The settle window has passed since terminal | Stragglers (section 4.2) | New |
| Q3 | No command is still open | A parallel sibling can still be running after a cancel or a failure | `noetl.command` |
| Q4 | Not parked on a callback, and not in a hold class | Section 5 | `pending_callback`, `uses_callback` |
| Q5 | No child execution is still running | A parent can finish before its child | `parent_execution_id` |
| Q6 | Log head has not changed since terminal | The direct check that nothing arrived late | `noetl.event` |

**Terminal status alone is not enough.** A sweep, cancel or `finalize` can assert terminal while
work is in flight. Status is also read from a projection: one listing showed a just-started row as
`RUNNING` with `completed_at` already set. Q3 and Q6 exist for these cases.

### 4.2 The settle window, and #504

The window replaces 48 h. It is not a retention period; it is the time during which a late event is
still plausible, so it must be at least the largest of:

| Input | Today |
|---|---|
| Worker event retry budget | About 3.5 s ([#504](https://github.com/noetl/ai-meta/issues/504)); **the fix is likely to raise this** |
| Server roll duration | About 29 s observed |
| Rebuild straggler margin | 30 s (`REBUILD_STRAGGLER_MARGIN_SECS`) |
| Command redelivery wait (`ack_wait`) | Not checked |

**Contract with #504:** whichever fix #504 chooses must publish its maximum delay, and the settle
window must exceed it. A test should fail if the two drift apart. Until #504 is decided, the window
stays conservative. A sensible path is 24 h (already a supported setting), then 1 h, then a target
of about 20 minutes if phase 0's data supports it.

### 4.3 Archive path: what moves and what stays

```
execution finishes
      │  quiescence check passes
      ▼
copy events to GCS ─► read back and verify ─► record as archived
                                                     │
                                  floor recomputed ──┤
                                                     ▼
                       parts entirely below floor dropped (local + replica)
```

This order already exists and is unchanged: upload, verify, record, and only then prune. A crash at
any point leaves the hot copy in place.

| Data | Action on quiescence |
|---|---|
| Embedded engine events | Archive to GCS; freed when the floor passes their parts |
| Chain store directory | **Delete**, no copy; can be rebuilt from Postgres |
| Projection tier record | No change; only the newest record is read, and it falls back to a Postgres fold |
| Writer tier | No change (section 6) |
| `noetl.event` | **Never touched** |

**Driver.** Keep the existing poll as the guarantee, because it survives restarts. A hook on the
terminal event can later add a fast path, but must never be the only trigger. It also has a second
benefit: today's pass lists the whole execution table every 5 minutes, about 100 pages.

### 4.4 Reads and replay after archival

| Reader | After archival |
|---|---|
| `GET /api/executions/{id}` | No change; served from Postgres |
| `GET /api/archive/executions/{id}` | Serves EHDB-format history from GCS |
| Recovery fold | Tier first, then Postgres |
| Parity verifier | A pruned execution reads as `OutOfCoverage`, deliberately neither a match nor a divergence |
| Chain read of a deleted execution | No watermark, so it answers "cannot answer"; a re-populate from the log should rebuild it. **Must be proven in phase 1** |

### 4.5 GCS as the cold tier

GCS already holds per-execution data, a manifest with digests and a by-date index, written by
idempotent keys. This RFC makes it the **cold copy of the EHDB format**, with Postgres still the
source of truth. Making GCS the only copy would require retiring `noetl.event`, which is out of
scope and conflicts with a standing rule.

---

## 5. The exception: runs that may wake up

There are three different cases, and only the last two are real problems.

| Class | How it looks | Risk | Handling |
|---|---|---|---|
| **Loops** | `RUNNING` until the last iteration | No premature archive, since it is not terminal; can pin the floor for its duration | Quiescence is naturally false. Long ones are the pinning case below |
| **Callback within a run** | Step `pending_callback`; sticky `uses_callback` | Not terminal while parked, so safe; can wait a long time | Q4 |
| **Callback after terminal** | Documented pattern: a callback handler applies a payload to the latest state of an `execution_id` | **The real hazard:** the run looks finished, then gets resumed | Hold class with a time fallback |
| **Parent and child** | `parent_execution_id` | Parent ends first | Q5 |
| **Listeners, subscriptions, schedules** | Long-lived by purpose | Pin the floor indefinitely | Opt out, with a time policy |
| **Stuck runs** | Non-terminal forever ([#315](https://github.com/noetl/ai-meta/issues/315)) | Pin the floor indefinitely | Sweeps end them, then normal rules apply |

**Identification, in order:**

1. **Observed:** the sticky `uses_callback`, or any callback event in the log. This needs no
   playbook author's help. Whether the flag survives snapshots must be checked, because a
   `#[serde(skip)]` field arrives empty on the snapshot path, which is how
   [#335](https://github.com/noetl/ai-meta/issues/335) went unnoticed.
2. **Declared:** an optional playbook setting, for example `retention: hold(30d)`, for patterns the
   engine cannot see.
3. **Detected after the fact:** an event arriving on an already-archived execution (section 7.2)
   adds that playbook to the hold list and raises a counter.

**Fallback.** Held runs use the time rule: terminal plus a longer window, 48 h at first, with a cap
so a hold cannot last forever.

**Pinning stays open.** A long-running execution pins the floor regardless of this RFC, because
parts mix executions. Prod runs `shard_count = 1`. Choices are to accept it, to cap it with a
"floor pinned for N hours" alert, or to rewrite parts, which the current design deliberately avoids.
Recommendation: alert only, for now.

---

## 6. Interaction with current mechanisms

| Mechanism | Effect |
|---|---|
| **Writer prune ([#491](https://github.com/noetl/ai-meta/issues/491))** | **Unchanged.** The parity sampler reaches back up to 1 h and pages on missing events. The repair sweep reaches back 180 minutes and would re-append what it finds missing. The catalog tier reads from sequence 1, so it must never be pruned by this path. The tier is a third copy and works well on a timer |
| **Server 48 h default** | Becomes the backstop for held runs. Normal runs use the settle window |
| **Chain store ([#503](https://github.com/noetl/ai-meta/issues/503))** | Gets its first retention and answers the open question on #503. Each deletion touches about 160 files on average, so it must run off the Tokio runtime in short lock holds, or it recreates the stall #548 removed |
| **Projection tier** | Unchanged. The `wal` read depends on the newest record only |
| **Replication ([#460](https://github.com/noetl/ai-meta/issues/460))** | Separate job and bucket. The replica protects hot data; the archive is cold history. A prune also drops the GCS replica copy, so the hot window shrinks in both. No durability is lost because Postgres and the archive hold the data. **The writer tier's lack of a replica is not improved by this RFC** |
| **Chain certification ([#366](https://github.com/noetl/ai-meta/issues/366))** | Dormant on prod with no consumer (#367). If it is ever enabled, certificates must be written before chain deletion or kept in the manifest |
| **[#335](https://github.com/noetl/ai-meta/issues/335) straggler margin** | Same class of problem. The settle window must exceed that margin |
| **[#472](https://github.com/noetl/ai-meta/issues/472) duplicates** | The archive should keep its current behaviour; the writer tier fix does not affect it |

---

## 7. Correctness and risks

### 7.1 Invariants

1. Nothing is removed unless a verified copy exists elsewhere: GCS for engine events, Postgres for
   chain data.
2. `noetl.event` is never modified.
3. Unknown means keep.
4. Every action is safe to repeat.
5. A refusal always records a reason, and the prune path must keep its existing rule that a refusal
   does not move the reclaimed-bytes counter.

### 7.2 What happens if an archived execution is touched again

| Step | Behaviour |
|---|---|
| Event appended | Postgres takes it as usual, so nothing is lost at the source of truth |
| Engine | The event lands in a new part. Today the archive would treat that execution as "already archived" and **silently miss it**. This must change |
| Archive | Detect the late event, write an additional object (data keys carry the sequence range, so they do not collide) and update the manifest |
| Floor | The execution constrains the floor again until it is re-archived |
| Chain | Repopulated from the log |
| Metric | New counter `archive_late_event_total`. Non-zero means the settle window or a hold class is wrong |

### 7.3 Risks

| Risk | Severity | Mitigation |
|---|---|---|
| Archive taken before a straggler arrives | Low: Postgres has it; the archive is short | Q2, Q3, Q6 and section 7.2 |
| Chain deleted while a reader needs it | Medium | Rebuild path proven in phase 1; delete only after quiescence |
| Chain deletion bringing back the stall | Medium | Off-runtime, rate-limited, and measured with `/health` |
| Newest records not yet on GCS | Low | Archive verifies by read-back, and prune drops sealed parts only. The tail lag seen was 43 to 703 s. Whether `read_execution_after` includes the unsealed tail should be confirmed |
| Restart forgets the archived set | Medium | `known_archived` is in memory; after today's roll the verdict read "2,084 not yet verified". A shorter cycle makes this more visible. See question 5 |
| More read load on the shared engine lock | Low | Same executions, earlier; volume unchanged at about 10 an hour |
| A held class is missed | Medium | Section 5, step 3 |
| GCS cost | Low | Same objects, sooner |
| A green metric that measures nothing | Medium | Each phase below checks reach with a positive control, not only a zero |

---

## 8. Metrics

- Verdict counts by reason: `ready`, `settling`, `open_commands`, `parked`, `live_child`, `hold`.
- Delay between terminal and last event, as a histogram. This sizes the settle window.
- `archive_late_event_total`.
- Chain directories deleted, files removed, and inode use on `/data`.
- Floor age, as a gauge, with an alert. Today's 6-day-old floor is visible only by decoding the
  sequence.

---

## 9. Phased plan

| Phase | Work | Done when | Risk |
|---|---|---|---|
| **P0a, now** | Section 2: inode alert and PVC expansion. Owner go | Inodes under 70%, alert verified live | Low |
| **P0b** | Measure in shadow: verdicts, late-event delay. Explain the 6-day floor. Change nothing | A week of data; floor cause stated | None |
| **P1** | Chain store retention: delete quiescent directories, first on kind with a re-touch test, then on prod in small batches | File count falling; `/health` unchanged; re-touch rebuilds | Medium |
| **P2** | Replace the clock in steps: 48 h, 24 h, 1 h, target, with Q2 to Q6 enforced | No late-event counts at each step for a period | Medium |
| **P3** | Handle re-touch in the archive (section 7.2) | Late event appears in the archive on kind. **Must land before P2 goes under 24 h** | Low |
| **P4** | Hold classes and playbook setting | Callback-after-terminal test on kind holds correctly | Low |
| **P5** | Optional fast path on the terminal event | Delay drops; poll still catches a missed hook | Low |

Prod steps follow the usual rule of kind first, then an owner go. Ordering depends on #504 for
anything below the 24 h step.

---

## 10. Open questions

**For the owner**

1. Approve section 2's stopgap, and when? It has about 3 days of runway.
2. Target settle window: about 20 minutes, or stay at 1 h for simplicity?
3. Which option does #504 take: longer retries, command redelivery or a server-side timeout? This
   sets the settle window.
4. Is a floor-pinned alert enough for long-running executions, or is per-execution part layout worth
   revisiting? (Recommendation: the alert.)

**For design**

5. Should the archived set persist across restarts instead of being rebuilt, given that every roll
   re-verifies a backlog?
6. Is a hold window of 48 h enough for callback-after-terminal, and what is its cap? How long do
   real callbacks take? (Not measured.)
7. Does anything read the chain store after terminal, other than the advance path? (The advance path
   stops polling at terminal; other readers were not exhaustively checked.)
8. Does any playbook on prod use callback-after-terminal today? Without a real example, step 2 in
   section 5 could wait.
9. Should the archive also cover the writer tier's unique data? The #491 finding is that it holds
   none, but the catalog tier deserves its own answer.

---

## 11. Non-goals

- Purging or changing `noetl.event`.
- Changing the writer tier's retention.
- Closing the writer's replica gap ([#460](https://github.com/noetl/ai-meta/issues/460)).
- Making GCS a serving tier. Postgres growth stays a separate question.

## 12. References

- [#455](https://github.com/noetl/ai-meta/issues/455) North star: EHDB as distributed registry and control plane
- [#459](https://github.com/noetl/ai-meta/issues/459) Retention and archive tier, with spec `design/retention-archival-tier.md` on `noetl/ehdb`
- [#460](https://github.com/noetl/ai-meta/issues/460) Distribution frontier and replication
- [#491](https://github.com/noetl/ai-meta/issues/491) Writer tier retention
- [#503](https://github.com/noetl/ai-meta/issues/503) Reconcile stall and the open chain-store retention decision
- [#504](https://github.com/noetl/ai-meta/issues/504) Worker result lost across a server restart
- [#335](https://github.com/noetl/ai-meta/issues/335), [#366](https://github.com/noetl/ai-meta/issues/366), [#367](https://github.com/noetl/ai-meta/issues/367), [#472](https://github.com/noetl/ai-meta/issues/472), [#315](https://github.com/noetl/ai-meta/issues/315), [#235](https://github.com/noetl/ai-meta/issues/235)
- Code at `noetl/server` v3.147.0: `src/services/event_archive.rs`, `src/handlers/chain_populate.rs`, `src/handlers/ehdb_embedded.rs`, `orchestrate-core/src/state.rs`
- Callback pattern: `docs/architecture/ephemeral_blueprints.md` in `noetl/docs`
