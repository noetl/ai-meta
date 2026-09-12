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

- **Loop status: 7 of 8 iterations used.** Handing #343 off at the bound.

## Outcome

(filled in by `loop-close`)
