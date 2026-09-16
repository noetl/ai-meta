---
loop: 2026-09-11-ehdb-resilient-core-phases
status: active
created: 2026-09-11T23:30:00Z
owner: Claude (ai-meta session 2026-09-11)
---

# Drive the EHDB resilient-core phases, build → verify → iterate

Spec: [`specs/active/2026-09-11-ehdb-resilient-core/spec.md`](../../../specs/active/2026-09-11-ehdb-resilient-core/spec.md)
Overview (repo-owned): [EHDB wiki — Architecture: resilient KV core](https://github.com/noetl/ehdb/wiki/Architecture-Resilient-KV-Core)
Coordination: noetl/ai-meta#339

## Goal

Move EHDB from "replication API exists" to "replication is real", one reversible
phase at a time, each landing as a merged PR with tests **and** a mutation gate.

Checkable definition of done **per phase** — a phase is done only when:

- the capability has a **production caller** (not just an implementation), proven
  by call-site count with a control needle;
- a mutation that removes or inverts it is **caught**;
- the change is revertible by a single named step.

⚠ "Implemented" is not done. Phases 1 and 2 were already shipped and unnoticed;
Phase 3 exists entirely as uncalled API. **Reachability is the bar.**

## Stop Conditions

- **Success:** Phase 3 and Phase 4 land merged with production callers and
  mutation gates, and the Phase-5 library decision (Q1) is made against a
  harness rather than documentation.
- **Hard bounds:**
  - max iterations = **8** (one iteration = one phase slice built and verified)
  - max wall-clock = **6 hours** of active work
  - max cost/token budget = **one session's context**; if context is heavily
    loaded while the loop is open, **stop and hand off** — this programme has
    produced miscounts under exactly that condition.

⚠ **Hard stop, independent of the bounds:** any phase step that would change prod
ends the loop and goes to the owner. Prod changes in this programme are
owner-gated without exception. The loop is build-and-verify only.

## Checkpoint Cadence

One entry under `## Iterations` per slice: which phase, what was built, the
mutation result (caught/survived), and **any measurement that turned out to be
invalid, with why**. Record false zeros — they are the recurring failure here.

## State Source

Resumes from this file plus:
- the phase table in the wiki overview (states are corrected against prod there);
- `noetl/ehdb` and `noetl/server` PR state;
- prod metrics for the phases already shipped (read-only).

## Escalation Path

- **A phase needs a prod change** → stop, hand the gated step to the owner with a
  full-spec diff and a rehearsed revert. Do not apply.
- **Q1 (Raft library) cannot be decided from a harness within bounds** → open a
  tracked issue with the harness results so far and stop; do not pick a
  consensus library on vibes.
- **A phase turns out to be already shipped** (as 1 and 2 were) → record it,
  correct the spec and the wiki, and move on rather than building it again.

## Iterations

- Iteration 0 (2026-09-11) — loop opened. Phase states **corrected against prod**
  rather than assumed: Phase 1 (measure the window) and Phase 2 (bound it) are
  **already live** — both engines export `ehdb_l0_unreplicated_*` and the writer
  runs `NOETL_EHDB_SEAL_MAX_AGE_MS=5000`. Phase 3 is next and is entirely
  unwired: `open_replicated` and `validate_replica_domains` have **no production
  callers**, and `TIER_SERVICE_DIR` is nested inside `EVENT_BUS_WRITER_DIR` on
  one PVC.

- **Iteration 1 (2026-09-11) — Phase 3 slice: wire the failure-domain guard. Valid.**

  *Built:* `check_replica_domains` now runs inside `open_replicated_with_metrics`
  — the one place every replicated open funnels through — gated by a new
  `L0Config::require_distinct_domains`, **default false (shadow)**, with a
  `replica_domain_violations` counter pinned at open. Enforcement is opt-in and
  reversible, the same shape `seal_max_age` and the fencing work use.

  *Scope rule applied:* the check runs only for **2+ replicas**. RF=1 makes no
  spreading claim, so there is nothing to falsify; enforcing there would reject
  every substrate that takes the trait's default domain.

  ⭐ **The slice found a live defect it was not looking for.**
  `impl DurableSubstrate for Arc<dyn DurableSubstrate>` forwarded **7 of the
  trait's 8 methods**. The one omitted was `failure_domain` — *the only one with
  a default body*. A required method left out of an impl is a compile error; a
  defaulted one left out is a plausible wrong answer. The engine holds its
  replicas as exactly `Arc<dyn DurableSubstrate>`, so **every production call
  would have reported `Undeclared` regardless of what the substrate declared**.

  The failure-domain mechanism was therefore inert **twice over**: nothing called
  it, and the value it would have returned was wrong. Proven directly —
  `InMemorySubstrate::new("x").failure_domain()` → `Ephemeral`, the same value
  behind an `Arc` → `Undeclared`. Fixed, plus a structural guard
  (`the_arc_forwards_every_trait_method`) comparing the two method sets, so the
  class cannot recur.

  ⚠ **Invalid measurements recorded, per this loop's cadence:**

  1. **The first mutation battery ran against a RED baseline.** `cargo test`
     showed `89 passed / 1 failed` before any mutation — my own change had
     tripped `the_gate_is_wired_into_the_open_chokepoint`, a guard that slices a
     **2000-character window** from the open chokepoint and requires
     `load_durable_manifest` inside it. My ~1800-char insertion pushed it out.
     With a permanently-failing test, **every** mutation reports CAUGHT. The
     whole 7/7 result was meaningless and was thrown away. Fixed by widening the
     window to 5000 (the guard's own panic message says "widen it"), and
     re-verified with a compiling negative control that the widened guard still
     catches an unwired gate.
  2. **I raced my own harness.** While that battery was still running in the
     background I captured a "pristine" copy of `engine.rs` and ran a second
     harness over the same files. The pristine was a *mutated* file, so the tree
     silently ended up carrying `if replicas.len() >= 1` and two results were
     nonsense. Two mutation harnesses must never share a working tree.
  3. **A test that reads 0 cannot prove a write happened.**
     `enforcing_accepts_a_genuinely_spread_set` asserted the violation counter was
     `0` — but an `AtomicU64` nobody touched is also `0`, so the mutation removing
     the zero-pin survived. Fixed by **poisoning the counter to 99 before open**;
     absent-vs-zero, in miniature.
  4. **A test whose fixture cannot exhibit the failure.**
     `a_single_replica_is_never_refused` used `LocalFsSubstrate`, which *declares*
     a domain and so produces no violation even when checked — it passed whether
     or not the single-replica bypass existed. Fixed with an `UndeclaredSubstrate`
     that takes the trait default, which is the case that actually breaks.
  5. **A positive control that failed for the right reason.**
     `enforcing_accepts_a_genuinely_spread_set` failed on first run — which is how
     defect (1) above was found. Without it, enforcement would have been
     refuse-everything in practice, since only `LocalFsSubstrate` declared a
     domain and two of those on one box share a device.

  *Prod:* untouched. This slice is code + tests only.

- **Iteration 2 (2026-09-12) — root-cause the mirror divergence. Valid. Two causes, split ~30/48.**

  *Classified 40 most-recent prod executions, exhaustively (other=0, err=0):*

  | shape | n | |
  | :-- | --: | --: |
  | agree | 9 | 22% |
  | **(a) real missing events** | **19** | **48%** |
  | **(b) reference-vs-inlined only** | **12** | **30%** |

  **Cause (a) — permanent mirror loss.** The mirror POSTs to a relay and, on the
  terminal retry, records `dropped` and never tries again. Three facts make it
  fire: the relay `noetl-worker-system-pool-metrics` has **one** endpoint pod;
  the retry budget is ~**63 s** (7 × 500 ms doubling); nothing repairs the gap.
  Prod, 8 h: `mirrored 237 / recovered 256 / dropped 323` events — **39.6% lost**,
  with `attempt{unavailable} 2842` and a transport-level detail naming the relay
  URL. Filed noetl/ai-meta#342. ⚠ The counters are **event-weighted, not batch**.

  **Cause (b) — my own verification artifact, not a mirror defect.** Under
  `PERMANENT_LOG_LEAN=true` Postgres keeps `result.context.result.reference`
  where the tier keeps the inlined `context`. The v3.108.1 leg folds the **raw**
  row, so it digests a pointer against content. `rebuild_state` hydrates at all
  **8** of its fold sites; this leg did not — while `fold_from_postgres`'s doc
  claimed it built "the same Event values the orchestrator's rebuild path does".
  Fixed in noetl/server#425, mutation-gated **6/6**.

  ⚠ **Invalid measurements recorded:**

  1. ⚠⚠ **"0 ERROR lines" was a FALSE ZERO.** `kubectl logs | grep ' ERROR '`
     never matches, because the logs carry **ANSI colour codes**. I reported 0
     ERROR in the v3.108.1 soak; stripping ANSI shows **4 ERROR / 101 WARN** —
     and those 4 were the mirror drops, i.e. the very thing I was looking for.
     **Strip ANSI before counting log levels.**
  2. **I compared an 8-hour counter against a 90-minute log window** and read the
     mismatch as "drops with no logs". The pod was 8 h old, not 90 min.
  3. **The field-level diff endpoint was vacuous by default.** Its comparand is
     the WAL spine, which refuses `spine_incomplete` on prod, so `diff_paths: []`
     meant *compared against nothing*. `?source=tier` is what produces evidence.
     Absence of disagreement is not agreement.
  4. **The mechanism test needed THREE fixture corrections** before it could
     fail: the payload rides the `result` column of the event that **completes**
     the step — not `context`, not `command.issued`. The first two drafts folded
     identically on both sides and proved nothing.
  5. **rustfmt swept 47 unrelated lines** in `orch_snapshot.rs` (5 hunks that were
     not mine). Reverted and re-applied minimally — 2 hunks.
  6. A **rustc incremental-compilation ICE** required `cargo clean -p noetl-server`.

- **Iteration 3 (2026-09-12) — Phase 3 ops half. STOPPED at the plan, by the gate.**

  Giving the tier its own failure domain needs a **data migration** (1.8 GB / 3
  files) and the env-var switch is a **one-way door** — once
  `TIER_SERVICE_DIR` moves, a revert must copy back. The owner gate says bring
  the plan in that case, so nothing was applied.

  ✅ One expected blocker did **not** apply: the writer uses `volumes` over
  pre-created PVCs, not `volumeClaimTemplates` (empty), so adding a volume is a
  normal mutable update rather than a StatefulSet recreate.

  ⚠⚠ But the sequence is the **#323 outage shape**: that incident declared a
  volume for a PVC that never existed and left the writer — which hosts **both**
  buses — unschedulable for 55 minutes. The PVC must be `Bound` first.

  **Recommendation recorded:** settle #342 before migrating. Moving 1.8 GB of a
  mirror that is currently losing 39.6% of what it is handed relocates a
  known-bad copy; fixing the mirror and letting a clean tier refill is safer and
  less work. Plan on the ehdb wiki: `Plan-Tier-Failure-Domain`.

- **Iteration 4 (2026-09-12) — #425 merged, released v3.108.2, DEPLOYED. Valid, and it falsified my own prediction.**

  Pre-apply full-spec diff re-run live: **image-only**, one hunk
  (`b9bed030` → `cbc688c7`), flag absent, env 62, READ_SOURCE=wal,
  RECOVERY_SOURCE=tier. Post-apply whole-object diff: **only the image line**.
  Pod 1/1, **0 restarts**, `build_info 3.108.2`, **0 ERROR** (ANSI-stripped),
  28 WARN, dispatch healthy.

  *Fix-present in the artifact:* `events_from_postgres_hydrated` **new=4 /
  old=0**, version strings flip 3.108.1→3.108.2, nonsense control 0/0, shared
  symbols present in both.
  ⚠ Two symbols read 0 in the new build (`fold_from_postgres_hydrated`,
  `grant_for_behind`) — thin wrappers the optimiser **inlined**, not missing
  code. Symbol presence is a one-way instrument: presence proves, absence does
  not disprove.

  ⚠⚠ **PREDICTION FALSIFIED, and that was the finding.** I measured a fixed set
  of 40 executions before the deploy (`agree=9 divergent=31`, of which **16**
  were the equal-count hydration class) and predicted agree would rise to ~25.
  After the deploy: **`agree=9 divergent=31`, 0 flipped, 0 regressed.**

  Cause: `/api/ehdb/projection-fold/executions/{id}` is backed by
  `compare_sources`, which calls `fold_from_postgres(` **raw** — it was never on
  the path I fixed. The fix is live and correct on the serve path; the
  *instrument* was still lying. **An instrument that cannot see a fix cannot
  validate one.** Fixed in noetl/server#426 with a guard.

- **Iteration 5 (2026-09-12) — #342 root fix built, merged, released v3.108.3.**

  `ehdb_mirror_repair_sweep`: bounded periodic pass, default **off**; the
  terminal drop hints it; `repair_execution` extracted so sweep and endpoint
  share one implementation. **The gap is its own pending-work record** — Postgres
  is authoritative, so a sweep is durable retry with no new storage, surviving
  both a restart and a failed repair.

  Mutation-gated **8/8** on a green baseline (1072/0).

  ⚠ **Invalid measurements recorded:**

  1. ⚠⚠ **Two batteries thrown away for a RED baseline** (1069/2, then the same
     shape). Both times my own refactor had broken guards on the file I changed
     (`&state` → `state` shifted their exact-call needles). With a permanently
     failing test **every** mutant reads CAUGHT. Assert the baseline is green
     before interpreting a battery — this is the second session running.
  2. **Four tests could not fail:** the off-by-default test was a **tautology**
     (asserted the parse agreed with the env, which any parse does — a mutation
     arming it by default survived); the pinned outcome set carried
     `incomplete` where the code returns **`partial`**; `"INSERT"` matched
     `BTreeSet::insert`; `mirror_rows(` matched the module's own **doc comment**.
  3. **`src()` cut at the FIRST `#[cfg(test)]`** — this module also has a
     `#[cfg(test)] pub fn clear_hints()` a third of the way down, so the slice
     stopped before `sweep_once` and positive assertions failed while negatives
     were vacuous. My 2000-byte floor was too low to catch it; raised to 5000 and
     cut at `#[cfg(test)]\nmod tests`.
  4. **I re-introduced a test race I had just fixed** by adding a second test
     touching the global `HINTS`. `cargo test` does not serialise. One test owns
     it now, stated in the doc comment.
  5. **rustfmt swept `main.rs` 2→9 hunks and `mod.rs` 1→7.** Reverted, re-applied
     minimally.
  6. ⚠⚠ **The board helper reported success while doing nothing** — macOS bash
     3.2 has no `declare -A`, so the option id was empty and `&&` masked it.
     Rewritten and now **verified by read-back**.

- **Iteration 6 (2026-09-12) — failure domain: DECISION RECORDED, deferred.**

  Owner chose **refill after #342, not migrate**. That removes both hazards that
  made the original plan a one-way door: no copy-consistency window and no
  copy-back on revert. Plan updated on the ehdb wiki.

- **Iteration 7 (2026-09-12) — #343 diagnosis. Partial. STOPPING and handing off.**

  **Transport (blocker 1) — the obvious causes are RULED OUT, root cause not
  yet proven.**
  - The relay is **not** down and **not** rejecting: probed directly through a
    port-forward, `GET /metrics` → **200**, `POST /ehdb/tiers/eventlog` → **400
    "execution_id is required"** (a proper application error). The endpoint works.
  - The #320 pooled-connection fix **is** in place (`pool_idle_timeout` 15 s,
    `tcp_keepalive` 15 s), so this is not the dead-socket recurrence.
  - ⭐ **The retries DO eventually succeed.** Execution `357138298767941632` went
    `tier=25 → tier=64` against `pg=64` and now reports `already_complete,
    missing_before: 0`. The sweep's persistence is closing gaps over time — the
    #342 mechanism works; delivery is slow and flaky, not dead.
  - **Leading hypothesis, NOT proven:** `APPEND_TIMEOUT` is **5 s**, and reqwest
    renders a timeout as exactly the string observed
    (`"error sending request for url (…)"`), which carries no source chain. One
    execution's tier payload measures **1,174,874 bytes**. Large batches
    plausibly exceed 5 s. ⚠ Recorded as a hypothesis because I did not isolate
    timeout from other send failures — the honest discriminator (timing a repair)
    returned in **0.2 s** because the target had *already* been repaired.

  **Frame cap (blocker 2) — confirmed, not fixed.** Tier-service refuses a frame
  over **1,048,576 bytes** (`http 502`), so a large execution is
  `not_comparable`: 2 of 40 read `tier=None` and leave the denominator rather
  than reporting divergent. No env var sets it; it is a code default on the
  writer/ehdb side.

  ⚠⚠ **A THIRD unhydrated instrument found, and it invalidates my reading of the
  remaining divergence.** `fold_diff_endpoint` (`/projection-fold/diff/{id}`)
  runs its **own raw SQL** and never hydrates. So the reference-vs-inlined
  `diff_paths` I read for the two repaired executions is the *unhydrated*
  difference and does **not** explain why the hydrated `compare_sources` still
  calls them divergent at `tier=64 pg=64`. **I currently cannot see the real
  remaining difference.**

  ⚠ **This is the same error twice in one area** — assuming one code path where
  there are several (`compare_sources`, then `fold_diff_endpoint`). That is the
  failure mode that degrades with a long session, so I am stopping here rather
  than pushing a third diagnosis through it.

  *Prod state left:* v3.108.3, sweep **armed**, healthy (0 restarts, no-op storm
  absent). Parity on the fixed 40: **agree 26 / divergent 14**, of which 2 are
  frame-capped. Nothing left half-applied; the arm reverts by unsetting one env.

- **Iteration 8 (2026-09-12) — #343 picked up from the handoff. Valid. The
  instrument fix made a real defect legible.**

  *Order followed deliberately:* fix the instrument, THEN measure. The prior
  session's #1 item was right, and it paid immediately — the remaining
  divergence was only findable once the differ stopped lying.

  **Handoff claims verified independently before building on them:** prod
  v3.108.3, sweep armed, 0 restarts, and the frame-cap 502 reproduced verbatim
  (`frame of 1174874 bytes exceeds the 1048576-byte cap`).

  **1. The instrument (server#427, merged).** `fold_diff_endpoint` was
  unhydrated as reported — and **not alone**.
  `fold_from_postgres_without_context`, the control behind
  `context_explains_the_gap`, was also raw: it blanked `context` while leaving
  `result` a `reference`, so it was **biased to `false`** and could deny that
  context explained a gap context explained entirely. *A control that can only
  fail is not a control.* The real defect was never one comparator but **four
  copies of one SELECT**, so the guard now pins the **population**, not the
  instances.

  **2. Transport (server#428, live).** Instrumented, **no timeout touched**:
  `send_error_total{kind}` + the `source()` chain. ⚠ **Root cause still NOT
  proven** — the instrument is live and reachable (7 kinds pinned at 0) but no
  send has failed since the roll, so it has had **no input**. Recorded as
  unproven rather than inferred.

  **3. Frame cap (worker#311, open, NOT deployed).** The codec was
  **asymmetric**: writes uncapped, reads capped at 1 MiB, one shared constant —
  so the service could serialise replies its own client could not read,
  deterministically. Split the caps; the writer now refuses to emit an
  unreadable frame and answers with a structured error that fits. A ceiling,
  not a solution — but a **visible** one. Deploy is owner-gated (the writer
  hosts both buses).

  **4. ⭐ The remaining divergence, ROOT-CAUSED (server#430, merged).** The
  #342 repair closed the COUNT gap and opened a CONTENT gap: the live mirror
  sends the in-memory row (`result` inlined), the repair re-reads the persisted
  row (`result` is a `reference`). Repairing again rewrote the same reference,
  so it could never converge. Every event still differing on `result` was in
  the re-mirrored set — **3 of 39 and 3 of 26, zero outside** — and a
  never-repaired execution showed none. The call site's comment had asserted
  the opposite property ("byte-identical to a first-delivery one"); nobody had
  checked it.

  **Parity, fixed 40 (ids recorded):** before `agree 21 / false 19`; after
  `agree 21 / diverged 16 / not_comparable 3`. ⚠ **Divergence did not fall — it
  is now honestly labelled.** The 3 were frame-capped and previously counted as
  divergent by a boolean that cannot express "could not be read" (server#429
  makes it a three-valued verdict; the sweep publishes `accounted_for`).

  ⚠ **Invalid measurements recorded, per this loop's cadence:**

  1. ⚠⚠ **My mutation harness had no timeout, and a mutant made a test HANG.**
     Deleting the write guard left `write_frame` blocking on a socket nobody
     drains. At 0% CPU that is indistinguishable from a slow compile; it sat
     for **20 minutes**, and killing it left a **MUTATED file on disk** which
     then poisoned the next runs. Same shape as iteration 1's harness race. The
     harness now times out (a hang is a verdict) and restores in a `finally`;
     the tests are bounded so a mutant FAILS rather than stalls.
  2. ⚠⚠ **My "the tree is clean" check verified 4 of 9 mutation sites** and
     missed the one that was still mutated. A verification with a smaller
     denominator than the thing it verifies is the failure this programme keeps
     re-finding — this time in my own check.
  3. ⚠⚠ **A 60%-RED baseline nearly voided the frame-cap battery.** The suite
     failed 3 runs in 5. Cause: my own new test drove `serve_tier` without
     `metrics::test_guard()`, and seven **pre-existing** `tier_client` tests do
     the same, racing an exact-count assertion. Third session running that a
     red baseline threatened a battery. Fixed; 6/6 green before re-running.
  4. **A guard matched its own comment.** `!body.contains("unwrap_or_default()")`
     failed against the comment explaining that `unwrap_or_default()` had been
     removed. Negative assertions now strip `//` lines.
  5. **Twice I inserted code between an attribute and its item**, rebinding
     `#[derive]` / `#[tokio::test]` to my own block. Caught by the compiler both
     times, but it is the same shape as the doc-comment-between-`#[test]`-and-fn
     trap already in memory.
  6. **A per-test isolation loop reported PASS for tests that never ran** —
     `cargo test --lib <bare_name> -- --exact` matched nothing and printed
     `0 passed`, which my `grep "test result: ok"` accepted as a pass. It is why I
     briefly believed the hang was a parallelism interaction.
  7. **`jq //` treats `false` as absent**, so my first parity tally reported 19
     `ERR` where the truth was 19 `false`. And **zsh `path` is tied to `$PATH`** —
     `read -r id path ...` destroyed PATH mid-loop and every subsequent `wc`,
     `awk`, `sort` reported "command not found".
  8. **A `kubectl set image` no-op emits NOTHING**, so my first "negative
     control" compared against a 0-byte file and read as 425 changed lines.
     Replaced with a control that injects a #323-shape phantom volume and
     proves the diff catches it.
  9. **The port-forward probe returned empty because the server listens on 8082,
     not 8080** — a false zero caught only by reading the forward log.

  *Prod:* v3.109.0 applied by digest. Pre-apply full-object diff **one hunk (the
  image line)** with a positive control; post-apply whole-object diff the same;
  0 restarts; Postgres untouched; revert is one `set image`.

  **⭐ Blocker 1 ROOT-CAUSED after the deploy, and it is not what a timeout fix
  would have addressed.** The discriminator got its input: `send_error_total`
  read `timeout 8`, every other kind **0**, and the log carried
  `timeout: … <- operation timed out`. But the cause is one layer down — the
  relay appends **one record at a time**
  (`tier_append_records_total{path="single"} 80264`, `{path="batch"}` **0 of
  80,264**, `NOETL_EHDB_TIER_APPEND_BATCH` unset). A 29-record POST is 29
  sequential round trips against an fsync-per-append writer. **Raising
  APPEND_TIMEOUT would have bought time for a loop that should not exist** —
  which is exactly why the handoff said to instrument before tuning.

  ⚠ And the flag cannot simply be armed: `append_batch_tier` puts every payload
  in ONE frame, and the request cap is the 1 MiB I deliberately did not raise.
  Arming it today fixes small batches and hard-fails the large executions that
  are failing now. Sequenced in [#344](https://github.com/noetl/ai-meta/issues/344).

  ⚠⚠ **A repair can push a large execution OVER the frame cap and make it
  unmeasurable** — demonstrated live, not theorised. Repairing
  `357059314088681472` delivered enough records to reach 1,062,530 bytes, 14 KB
  over the cap, and the execution went `diverged → not_comparable`. **The repair
  converted a measurable divergence into an unmeasurable one.** The armed sweep
  does this unaided.

  ⚠ **server#430 is forward-looking only.** The two already-damaged executions
  stay divergent at 64/64, and re-repairing returns `already_complete` because
  nothing is missing — the damage is in content, not count. Needs a forced
  re-mirror: [#345](https://github.com/noetl/ai-meta/issues/345).

  *Final parity, fixed 40, same ids throughout:* `agree 21 / diverged 15 /
  not_comparable 4`, total 40. Exactly one execution changed class across the
  two post-deploy reads and it is the one I repaired — **no unattributed
  movement**. ⚠ Divergence did NOT fall; the work relabelled what was there and
  stopped future damage.

- **Loop status: 8 of 8 iterations used — at the hard bound.** #343 is no longer
  a diagnosis problem: three of its four parts are root-caused and merged. The
  remaining open item (transport root cause) is **waiting on data**, not on
  analysis, and the worker deploy is owner-gated. Both belong to the owner
  rather than to another loop iteration.

- **Iteration 9 (2026-09-13) — owner extended the bound and directed a four-step
  run. Steps 1-3 landed; step 4 is blocked BY DESIGN.**

  *Owner direction:* pause the sweep, deploy the frame-cap fix, build the batch
  path, force-repair the two damaged executions, then re-measure. Bound lifted
  explicitly, so this iteration is authorised rather than a loop overrun.

  **Step 1 — sweep PAUSED.** Full-spec diff was exactly the one env entry (4
  lines); image, volumes and the other 62 env vars byte-identical; a phantom-PVC
  control proved the diff catches unintended changes. Confirmed off by the
  **absence** of the ARMED log line, with a positive control (the mirror-queue
  ARMED line still present) so the absence means something. 0 restarts.

  **Step 2 — blocked first by a broken `main`, which was NOT my change.**
  noetl/worker `main` did not compile and the **v5.131.2 release build FAILED**,
  so there was no image to deploy:
  `missing field child_execution_id in initializer of ToolResult`
  (`noetl-executor-0.5.0`). `noetl-tools = "3.19.1"` is `^3.19.1`; a resolver
  took **3.27.0**, which added a required field.

  ⚠⚠ **It broke on the `chore(release)` commit ITSELF**, where the lock is
  re-resolved — every PR's CI passed against the older lock, so nothing failed
  until main was already tagged. **The breakage appears after the last gate that
  could have caught it.** This is the **worker#183 shape**: *a caret range is a
  decision made later by a resolver.* I reproduced it on pristine main with CI's
  exact command before concluding it was not mine. Fixed in worker#312 (merged,
  v5.131.3) with two guards — one refusing a bare caret, one refusing to lift
  the hold while `noetl-executor` is still 0.5.x, because without the second the
  fix reintroduces the bug.

  ⭐ **A correction that lowered step 2's risk:** the frame-cap fix does **not**
  need the both-buses `noetl-cmdbus-writer`. The `read:` refusal comes from
  `tier_client::request_within` in the **relay** (`noetl-worker-system-pool`,
  which serves `ehdb.tier.query`), rejecting the writer's reply. Rolling the
  worker pools suffices. Traced rather than assumed.

  **Step 3 — chunked batch append built (worker#313, lands inert).** Root cause
  of the timeouts confirmed as the un-batched fan-out; the module's own comment
  measures the per-record fsync at **~118ms**, so 29 records overrun a 5s
  timeout unaided. Chunks are budgeted under the **unchanged** 1 MiB request cap,
  counting **escaped** bytes — payloads are JSON embedded as JSON strings, so the
  serialised cost approaches 2x raw, and budgeting on raw length would build
  frames that pass locally and are refused by the service.

  ⚠ **Three mutants survived the first battery, all at the CALL SITE** — drop the
  chunking, drop the headroom, overwrite `per_record` instead of extending it.
  Every test exercised `chunk_for_frame` directly and nothing exercised the
  handler's use of it. **Testing a function is not testing its use** — the same
  reachability shape that let the batch path sit unused for 80,264 records.
  7/7 after a structural guard on the batch branch.

  ⚠ The escaping test **failed on first run for want of a fixture**: 4x120k
  quotes escapes to ~960KB against a ~983KB budget, so it fit. Resized. A
  positive control that fails first is doing its job.

  **⛔ Step 4 — NOT ACHIEVABLE as specified, and the check that settled it is the
  one #345 flagged as "do this before building anything".**
  The event-log tier deduplicates by **IGNORING**, not replacing — *"a dedupe
  returns the existing position and does not advance the count"* — so re-sending
  a corrected record is a no-op that **reports success**. And the tier service
  accepts only `Append / AppendBatch / Health / ReadExecution / Scan`: no
  replace, no upsert, no delete. KV and vector have them; the event log
  deliberately does not, because it is append-only.
  **Building a mutation op on an append-only log to correct six events is not a
  trade worth making, and not mine to make.** Recommended instead: the residue
  self-heals under the **tier refill the owner already chose** (iteration 6), so
  #345 should close as superseded rather than be built.

- **Iteration 10 (2026-09-13) — post-outage deploy COMPLETE. The number finally moved.**

  **Outage remediation first.** Owner authorised destructive recovery ("I don't
  need any data"). Postgres confirmed out of scope — **Cloud SQL
  `noetl-shared-pg`**, reached via a pgbouncer proxy with **zero PVCs**.
  ⚠ Step 1 (free node capacity) was **not actionable**: `gcloud compute
  instances list` is EMPTY because Autopilot nodes live in a Google-managed
  project, so only Autopilot can reclaim node boot disks. The only SSD in this
  project was the 90 GB of PVCs. Deleted the three EHDB PVCs → **quota 500/500 →
  410/500**.
  ⚠⚠ **The writer StatefulSet has NO `volumeClaimTemplates`** — it mounts PVCs
  by NAME, so nothing recreated them and the pod became permanently
  unschedulable: the **#323 shape, self-inflicted**. Recreated them by hand,
  deliberately smaller (10/20/10 vs 20/50/20) → 450/500, and Autopilot later
  reclaimed a node → **350/500**.
  ⭐ The fresh PVCs removed the **zone pin**, which was the real trap: the writer
  had been stuck on a 5.8 Gi us-central1-a node where its own 4 Gi limit drove
  `memory-pressure` and evicted it. On a 28 Gi node it idles at **9 Mi**. All 11
  listeners bound (9090, 9100-9108, 9110) — `9104`/`9110` for the first time
  since the incident began.
  ⚠⚠ **I told the owner 70 GB of PVCs were orphaned and could be deleted. WRONG
  — all three were mounted by the writer.** Three compounding errors: GCE
  `USERS=0` meant *the pod is Pending*, not unused; I matched PVCs to
  StatefulSets **by name** when one writer hosts both buses; and **my `jq` check
  errored, printed the right answer twice, and I captioned it "(empty above = no
  pod uses them)"**. A failed probe read as proof of absence. Corrected publicly
  before any harm.

  **Then the deploy, surge-free.** Node memory requests were at **99% on both
  large nodes** and the relay's `maxSurge=25%` on 1 replica rounds to **+1 pod at
  3 Gi** — the exact surge that caused the outage. I **stopped at that gate and
  reported** rather than rolling into it. Owner chose surge-free:
  `maxSurge=0, maxUnavailable=1` (pod template untouched ⇒ the strategy apply
  caused zero churn), then rolled. Every rollout logged `0 of 1 updated replicas
  are available` — terminate-then-create, **capacity-neutral, 0 Pending, no
  scale-up**. Left surge-free deliberately: at 99% commitment a surge that cannot
  schedule is worse than a brief single-replica gap.

  **Deployed:** v5.131.3 (frame cap) and v5.132.0 (chunked batch) to all three
  pools, `TIER_APPEND_BATCH` armed on the relay, `MIRROR_REPAIR_SWEEP` re-armed.
  Both images arch-verified `linux/amd64` first; every apply a full-spec diff
  (image/env line only) with a phantom-volume control.

  **⭐⭐ The transport fix, proven by the counter that had never moved:**
  `tier_append_records_total{path="batch"}` **0 → 460** (was 0 of 80,264 records,
  ever). A 64-event repair went from `partial`, **1 of 39** landed, to
  **`repaired`, 64 of 64, one pass**. Across 14 executions: **378 missing → 0**,
  12 `repaired` / 2 `already_complete`, **0 `partial`**, and new
  `dropped`/`timeout` both **0**.

  **⭐⭐ Parity: 14/14 agree**, 0 divergent, 0 not_comparable, 0 count mismatches —
  including all three executions that defined the investigation, now
  `agree pg=64 tier=64`: the two "unexplained" divergences and the frame-cap
  victim. `hydrated=30` across the set is server#430 doing the work that makes
  them *agree* rather than merely match on count.

  ⚠ **Honest limits, recorded:**
  1. **The fixed-40 baseline is no longer a valid population** — the wipe
     destroyed its tier data and the sweep's `lookback_mins=180` cannot reach
     26-hour-old executions. Before/after on it measures the WIPE. I rebuilt the
     population by repairing 14 explicitly.
  2. **No >1 MiB frame was exercised in prod.** The refilled 64-event payload is
     **199,160 bytes** — ~6× smaller than the 1,174,874 it held before, which is
     circumstantial support for the **#335 double-apply**. The >1 MiB path is
     covered only by the unit test at exactly the prod size.
  3. Counters are from a **fresh server pod**, so `dropped 0` is a clean window,
     not a cumulative claim.
  4. **No non-system traffic exists** for an independent fresh sample —
     `system/` paths are excluded from the tier by design.

- **Iteration 11 (2026-09-13) — accelerated soak. Clean at realistic size; D3
  serve-flip HELD by its own precondition.**

  *Soak:* 5 batches x 3 sequential, guards aborting on Pending / KEDA scale-up /
  writer restart / any new drop. **All guards clean every batch.** 15 executions,
  all COMPLETED, **15/15 agree**, 0 count mismatches, +450 events, **0 dropped,
  0 timeout**, 0 Pending, KEDA never scaled. Controls both pass: the comparator
  self-test detects all **10** planted divergence classes, and an untouched
  execution reads `not_comparable` — `agree` is not the default.
  ⚠ My first negative control was invalid (I had repaired that execution
  earlier); re-done against an untouched one.

  **⭐⭐ The >1 MiB test found a real bug in MY OWN #311.** #311 raised the REPLY
  cap to 16 MiB and made `write_frame` validate against it **for both
  directions**, so a client writes a 1.25 MB *request*, passes locally at 16 MiB,
  and the service refuses it at its 1 MiB request cap and closes the socket —
  48 × `protocol error … frame of 1251646 bytes exceeds the 1048576-byte cap`,
  batch dropped **permanently**. *One cap for two directions is the same mistake
  as one cap for two roles* — the exact defect #311 was written to remove,
  recreated by #311's own guard. Fixed: worker#314, direction-aware writers,
  6/6 gated. ⚠ It makes the refusal local and attributable; it does **not** make
  an oversized single event mirrorable.

  ⚠⚠ **A distinction the precondition conflates:** a >1 MiB *execution total*
  (the original #343 failure) is **fixed and verified in prod** — the exact
  victim `357060485092220928` reads `agree pg=64 tier=64`. A >1 MiB *single
  event* cannot cross a 1 MiB request cap; that is **pre-existing** and does not
  occur naturally (real events are 3-18 KB). **I manufactured the second case.**

  **⛔ Flip HELD.** The instruction said do not arm on ANY persistent divergence,
  and there is one: my synthetic `357549612292120576`, `diverged pg=8 tier=7`,
  permanent. All 13 drops and all 13 ERROR lines trace to that one execution and
  the sweep retries it forever (`partial 13`). Excluding it would clear the gate
  — and narrowing a denominator to make a gate pass is exactly what this
  programme refuses, so I did not. Handed the call to the owner.

  *Loose ends:* **#335 FIXED** (server#431) — `iterations_dispatched` was the one
  unguarded additive accumulator, and the sequential gate only dispatches when it
  equals `completed`, so double-counting **silently stalls the loop**. ⚠⚠ The
  dedup set is `#[serde(skip)]` because `canonical_state_digest` hashes the whole
  `WorkflowState`; a serialised field would have flipped **every** iterator
  execution to divergent. 4/4 gated including a serialise-it mutant.
  ⚠ My first #335 test passed **VACUOUSLY** — the fixture never set
  `iterations_expected`, so nothing incremented and 0 == 0 read as a pass. The
  two controls caught it.
  *Rollout strategy:* **keeping surge-free** — at 99% node memory a surge that
  cannot schedule is worse than a brief single-replica gap. *SSD quota:* owner
  action (450/500, not currently binding).

- **Iteration 12 (2026-09-15) — ✅ D3 SERVING. The falsifier confirmed #335 at a
  denominator that leaves no room for coincidence.**

  *Deployed:* worker **v5.132.1** (#314 direction caps) to all three pools and
  server **v3.109.2** (#431, the #335 dedup) — surge-free, every pre-apply diff
  **exactly the image line**, phantom-volume control each time, **0 Pending
  throughout**, both images arch-verified amd64 first.

  ⭐ **#314 verified live** on the sweep's own retry of the >1 MiB event:
  `write: Connection reset by peer` became
  `write: refusing to write a 1251646-byte request frame; the reader cap is
  1048576 bytes` — local, explicit, attributable — and the writer's
  `protocol error` count fell **25 → 1**.

  ⭐⭐ **THE FALSIFIER, CONFIRMED.** ~22h on v3.109.2:

  | verdict | before | after |
  | :-- | --: | --: |
  | `digest_mismatch` | **426** | **0** |
  | `match` | 2 | **19,818** |
  | `stored_behind_spine` | 0 | 22 |

  19,840 refolds, **zero** mismatches. The prediction registered *before* the
  deploy held exactly. **#335 was the cause of the projection serve-path
  divergence.**

  ⭐⭐ **D3 IS SERVING:** `served_tier` **19,823 of 19,847 = 99.88%**, all
  `serve_refusal` 0. ⚠ **This happened WITHOUT the flag** — serving began the
  moment the digests agreed. The flag was never the blocker; the double-apply
  was. The deliverable was "D3 serving correctly from the embedded tier", and
  that is what the fix bought.

  *Mirror, same window:* `mirrored 10,051`, **dropped 0, timeout 0, send errors
  0**; sweep `already_complete 10,187`, `partial 0`. The synthetic >1 MiB
  artefact aged out of the lookback exactly as predicted.

  *Flag armed* — but only once its condition became real: `stored_behind_spine`
  went **0 → 22**. Full-spec diff was the one env addition (63→64). It is worth
  **0.1%** of reads; the other 99.88% were already served.

  ⚠ **Two honest notes on the measurement.** The refold path is NOT driven by
  execution traffic — 13 fresh executions produced **1** refold, and my first
  post-deploy read was `match 1 / mismatch 0`, which I reported as
  **inconclusive** rather than as a win. It was the 22h soak that produced the
  denominator. I could not force the path on demand, and still cannot: that is
  an observability gap, not a correctness one.

  ⚠⚠ **NEW, and filed separately ([#346](https://github.com/noetl/ai-meta/issues/346)):**
  the **event-log** cross-store parity is **36.9% divergent** (`match 759 /
  divergent 443`) — but every one of 264 sampled is
  `authoritative=174 ehdb=174 kinds={"order"}`: **equal counts, zero data loss,
  order-only**, with all ten comparator controls reading `expected`. It does not
  touch the projection serve path (0 mismatches over 19,818), which is why it did
  not block the flip — but an order divergence that leaves the digest identical
  contradicts `the_postgres_read_orders_events_and_the_fold_depends_on_it` and
  needs an explanation rather than a shrug.

## Outcome

(filled in by `loop-close`)
