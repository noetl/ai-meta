---
loop: 2026-09-11-d3-serve-flip-evidence
status: active
created: 2026-09-11T06:36:01Z
owner: Claude (ai-meta session 2026-09-10/11)
---

# Close the two open evidence gaps on the D3 serve-flip

Spec: [`specs/active/2026-09-11-d3-projection-serve-flip/spec.md`](../../../specs/active/2026-09-11-d3-projection-serve-flip/spec.md)

## Goal

Satisfy **AC11** and **AC12** of the spec, in kind, so the spec's Open Questions
Q1 and Q2 are resolved in writing and the prod flip (AC13) can be put to the
owner with complete evidence rather than a partial case.

Checkable definition of done — both must hold:

- **AC11:** a specific behind-serve is attributable to a specific
  `execution_id`, and that execution's served answer is then verified against
  Postgres at a matched version. Evidenced by a run producing ≥10 attributable
  behind-serves with 0 unexplained divergences.
- **AC12:** an induced ahead snapshot is observed being refused on a running
  server, with `noetl_ehdb_projection_serve_refusal_total{reason="stored_ahead"}`
  incrementing from 0 to ≥1 and no serve occurring for it.

Not done if either is argued rather than observed. AC2's compile-time
unrepresentability and the 30-case property sweep are *already* true and are not
a substitute for AC12 — this loop exists precisely because a structural argument
and a live observation are different evidence.

## Stop Conditions

- **Success:** AC11 and AC12 both observed as above, each recorded under
  `## Iterations` with the command run and the counter values before/after, and
  Q1/Q2 answered in the spec body.
- **Hard bounds:**
  - max iterations = **6** (one iteration = one design-and-measure attempt at
    either AC11 or AC12)
  - max wall-clock = **4 hours** of active work across the loop
  - max cost/token budget = **one session's context**; if the loop is still open
    when context is heavily loaded, stop and escalate rather than continue —
    this program has produced miscounts under exactly that condition.

⚠ Additional hard stop, independent of the bounds above: **any prod mutation
ends the loop immediately.** This loop is kind-only. Deploying v3.108.0 to prod
or arming `NOETL_EHDB_PROJECTION_SERVE_ON_BEHIND` there is owner-gated (AC13)
and is not inside this loop's scope under any circumstance.

## Checkpoint Cadence

Append one entry under `## Iterations` per attempt, recording:

- which AC the iteration targeted;
- the exact mechanism tried (and for AC12, whether it required a test-only seam);
- counter values **before and after**, with the denominator — a bare
  `stored_ahead=1` is not a result without the population it was measured over;
- whether the measurement was valid, including any that turned out not to be.

⚠ Record invalid measurements too, and say why they were invalid. Two
measurements in this program produced phantom divergences (3, then 60) and were
only caught by re-reading the raw fields; a loop log that records only the
corrected numbers teaches the next reader nothing about the trap.

Durable outcomes also land in ai-meta memory + the server wiki per
`agents/rules/change-documentation.md`.

## State Source

Resumes from this file plus:

- the spec's Acceptance Criteria checkboxes (AC11/AC12 unchecked = not done);
- kind cluster state: `kubectl --context kind-noetl -n noetl get deploy noetl-server-rust`
  (image should be `ghcr.io/noetl/server:3.108.0`, `NOETL_EHDB_PROJECTION_SERVE_ON_BEHIND=true`,
  `NOETL_STATE_BUILDER=server`, `NOETL_EHDB_PROJECTION_READ_SOURCE=wal`);
- the counters themselves, which are cumulative per pod — so a pod roll resets
  the denominator and any iteration spanning a roll must be re-measured, not
  summed across it.

Each iteration is re-runnable: driving more load and re-reading counters is
additive and has no partial-apply hazard in kind.

## Escalation Path

If hard bounds are hit without success:

- **AC11 unresolved** → open a tracked `ai-task` issue on `noetl/ai-meta`
  (label `repo:server`) citing this loop and the spec, proposing Q1 option (a)
  or (b) as a scoped change, and stop.
- **AC12 unresolved because inducing an ahead snapshot needs a test-only
  injection seam** → do **not** ship the seam unilaterally. Open an issue and put
  the trade-off to the owner: a seam that exists only for tests is itself a
  surface, and the alternative (accepting compile-time + property evidence for
  ahead) is a legitimate answer the owner may prefer.
- **Either gap judged unclosable in kind** → say so plainly and record it as a
  known limitation on the spec rather than widening the loop's bounds. A spec
  that ships with a named, accepted gap is honest; one that quietly drops a
  criterion is not.

## Iterations

- Iteration 0 (2026-09-11) — loop opened. No iterations run yet. Baseline
  established by the prior session and recorded in the spec as AC1–AC10:
  v3.108.0 released with the flag defaulting off (binary-verified with a
  control), serve-on-behind wired and mutation-gated 4/4, under-lag behind-serve
  observed in kind (`stale_within_window=17`, `serve_refusal{*}=0` over 750
  executions), version-matched content parity 80/80 with 80 distinct digests,
  and the inert prod-deploy diff prepped (image-only) with the revert rehearsed.
  AC11 and AC12 are the remainder.

- Environment note (2026-09-11, not a loop iteration) — prod was rolled to
  **v3.108.0 inert** (image-only, flag NOT armed; owner-authorized). This does
  not advance AC11/AC12, which are kind-only, but it changes two of this loop's
  assumptions: prod and kind now run the **same build**, so a behaviour
  difference between them can no longer be explained by version skew; and the
  four `serve_refusal` series now exist on prod, so `stored_ahead` there is a
  real zero rather than an absent family. Recorded here because the loop's
  State Source is what a resuming session reads first.

- Environment note 2 (2026-09-11, not a loop iteration) — synthetic load run
  against **prod** v3.108.0 with the flag OFF. Two results change this loop's
  assumptions:

  1. **The denominator problem is solved by load, not by topology.** D3 reads
     went from ~1.4/hour idle to **180 `served_tier`** off 51 executions
     (≈1 read per 3). AC11's "≥10 attributable behind-serves" is therefore
     reachable; what is still missing is *attribution*, not volume.
  2. **A new gap was found that this loop should probably absorb:** the bounded
     verification reads the **tier** when the spine refuses
     (`events_for_recovery` → `tier_events_within` under `RECOVERY_SOURCE=tier`),
     so for a spine-refused execution it compares a tier-derived fold against a
     tier-derived record. Logged on the spec as **AC14 / Q4**.

  ⚠ Also recorded because it is a trap this loop's Checkpoint Cadence explicitly
  asks for: **13 apparent divergences under load were transient and all
  converged within ~3 minutes.** Same version, different `applied_count` — an
  async mirror delivering the last event before some middle ones. A single-shot
  sweep cannot distinguish that from loss; re-checking after settle can. One
  divergence did persist (tier 26 of 30 events, 15+ min) and is real.

- **Iteration 1 (2026-09-11) — target: AC14 / Q4. Valid. Closed AC14.**

  *Mechanism:* read the code rather than measure harder. Followed the serve
  decision from `orch_snapshot::load_latest` through `wal_projection_state` to
  `grant_for_behind`, then asked the ladder what it actually resolves to on
  prod.

  *Counters, with the denominator:*

  ```
  recovery_fold{source="spine"} spine_incomplete  25390     folded: 0
  recovery_fold{source="tier"}  folded            25349
  projection_read{outcome="served_tier"}           2212     <- flag is OFF
  projection_read{outcome="no_stored_record"}      10452
  ```

  The spine folded **0 of 25,390**. That single ratio is what decided Q4: option
  (a) would refuse ~100% of behind-serves, so the "conservative" option was the
  vacuous one. Answered (b), implemented in noetl/server#424.

  *What the denominator also exposed:* `served_tier = 2212` **with the flag
  off** — the tier is already serving control-flow reads, verified only against
  itself. AC14 was filed as a risk the flip would introduce; it is a defect in
  the path that is already live. The loop's premise (that this work gates a
  future flip) was too narrow.

  *Proof:* `a_tier_missing_middle_events_is_refused_not_served` reproduces the
  `356712944081313792` shape — 30 events vs 26, **identical version**, because
  `version = max(event_id)` and the missing events are in the middle — and
  asserts `DigestMismatch` + `is_fault()`. Its control folds the tier against
  itself and asserts `Match`, pinning the pre-fix behaviour. Mutation-gated
  11/11 after two rounds; 3 mutants survived round one (M3 truncation boundary,
  M6 query ordering, M8 agreement forced true) and were only catchable after
  extracting three pure functions.

  ⚠ **Invalid measurements recorded, per this loop's cadence:**

  1. **The AC14 control failed for an unrelated reason.** Two folds of
     "identical" events digested differently — `event_from_tier_payload` does
     `.unwrap_or_else(chrono::Utc::now)` for an absent `created_at`, so an
     unpinned fixture re-stamps the clock on every call. Fixed by pinning
     `created_at`. Had I read the failure as "the fix doesn't work" I would have
     chased a real result as a bug.
  2. **The order-sensitivity fixture proved nothing on its first draft.**
     Twelve `step.enter` events on distinct nodes digest the same in either
     order — distinct keys build the same map and the canonical digest sorts
     keys. Order is only observable across a state transition on **one** node.
     The first version asserted a property its own fixture could not exhibit.
  3. **`cargo test --lib <name> -- --exact` ran 0 tests and reported `ok`.**
     `--exact` needs the full module path. "80 passed" had not included the new
     guard at all; a green run over a filter that matches nothing is
     indistinguishable from a green run over the thing you meant.

- **Iteration 2 (2026-09-11) — target: AC13 arm gate prep. Valid. Not executed.**

  Full-object diff of the arm, via `patch --dry-run=server` against live:
  **exactly 2 lines**, the env addition, nothing else. Positive control (same
  method, patch also setting `replicas: 2`) reports **both** hunks, so the
  one-hunk result is the method working rather than blind — the #323 lesson
  applied. Revert rehearsed both ways (set `false`; remove index 62). Recorded
  in `specs/active/.../arm-runbook.md`.

  ⚠ A reconstructed full manifest did **not** diff clean against live — it would
  rewrite `last-applied-configuration`. Hence `patch`, not `apply`.

  ⚠ Arming writes `spec.template` and therefore **rolls the pod by
  construction** (`replicas: 1` → ~30–60s serving gap). Stated up front rather
  than discovered in the window.

  **Outcome: NO-GO on v3.108.0**, on the iteration-1 finding — arming would
  widen serving on a check that cannot fail. Not a defect in the arm materials,
  which are ready.

- **Out-of-scope defect found and filed:** noetl/ai-meta#335 — the WAL path
  double-applies every event (`version: 0` + `event_id > 0`), and
  `iterations_dispatched` is the 1 of 4 accumulators in `apply_event` with no
  dedup guard, so sequential loops can silently fail to dispatch. Reproduced at
  unit level. Not fixed inside this loop: the fix changes the canonical state
  digest on a live path, which is a scope decision rather than a loop iteration.

- **Loop status: 2 of 6 iterations used.** AC14 closed; Q4 answered; AC11/AC12
  remain open and are now **owner decisions** (Q1 needs a scoped code change;
  Q2 needs a test-only seam this loop's escalation path forbids shipping
  unilaterally), not further measurement. No prod mutation occurred, so the
  hard stop did not trigger.

## Outcome

(filled in by `loop-close`: status, iterations run, final result, links to any
issue/handoff opened on escalation)
