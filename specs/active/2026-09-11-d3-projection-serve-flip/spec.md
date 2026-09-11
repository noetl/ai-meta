---
spec: 2026-09-11-d3-projection-serve-flip
status: draft
created: 2026-09-11T06:36:01Z
owner: Claude (ai-meta session 2026-09-10/11)
---

# D3 projection serve-flip: let a behind snapshot serve, make an ahead snapshot unserveable

## Problem

The D3 projection tier can already answer an orchestrator read, and is never
allowed to.

Measured on prod (server v3.107.1, `NOETL_EHDB_PROJECTION_READ_SOURCE=wal`):

```
noetl_ehdb_projection_read_total{outcome="served_tier"}     0
noetl_ehdb_projection_read_total{outcome="spine_refused"}  12   (later 21)
```

Every read was refused. When the refusal reason was narrowed it was
`stored_behind_spine` on **11 of 11** attempts — the tier being refused for the
one condition that is *safe* to serve.

The two failure directions are not symmetric, and the whole design follows from
that asymmetry:

- A snapshot **behind** the spine is **slow but correct**. `rebuild_state` folds
  every event after `snap.version`, so a stale snapshot costs extra folding and
  yields the same answer.
- A snapshot **ahead** of the spine is **silently wrong**. The events between the
  real watermark and the claimed one are never folded, the caller receives a
  state that never existed, and nothing downstream can detect it — a rebuild has
  no second opinion to compare against.

So "refuse everything that is not an exact match" is safe but useless, and the
naive fix ("serve when behind") is only safe if ahead is made genuinely
impossible rather than merely unlikely.

Secondary problem, which shapes the verification: **prod's topology structurally
starves the evidence.** `NOETL_STATE_BUILDER=offserver` routes drives through
`dispatch_offserver_stateless_drive`, so the worker builds state from the WAL
spine and the server's `rebuild_state → orch_snapshot::load_latest → D3 read`
path fires roughly **12 times in 20 hours** (~0.6/hour). A dark-launch on prod
would accumulate a denominator too small to distinguish a healthy tier from an
unexercised one.

## Goals

- Serve a **behind** projection snapshot to the orchestrator, with the caller
  forward-folding from the snapshot's own version.
- Make serving an **ahead** snapshot structurally impossible, not merely
  rejected by a branch.
- Produce read-path evidence at a denominator large enough to be meaningful,
  which requires inducing prod's condition (mirror lag) in kind rather than
  waiting for prod.
- Keep every step reversible, with Postgres intact and authoritative as the
  revert target throughout.

## Non-Goals

- **Not** making the embedded engine authoritative for any other dataset. D1
  (`noetl.event`) stays shadow/capture-only; D2/D4/D5/D6/D8/D9/D10 are out of
  scope (they have zero server wiring — see the survey note in Constraints).
- **Not** replacing `noetl.projection_snapshot` as a stored table. This spec
  changes which store *answers a read*; Postgres keeps being written and keeps
  being the fallback.
- **Not** changing `NOETL_STATE_BUILDER` away from `offserver` on prod. That is a
  topology change with its own blast radius; it is named here only because it
  explains the evidence problem.
- **Not** arming the flag on prod. The prod flip is owner-gated and is the
  terminal step of the Plan, deliberately not executed by the implementing
  session.

## Constraints

- **Reversibility is inviolable.** Every step has a one-command revert, and the
  revert is rehearsed before the forward step is taken.
- **Postgres is never dropped or truncated.** "Replacement" here means EHDB
  answers a read while Postgres remains written and available as fallback.
- **No prod apply without a full-spec `kubectl diff --server-side`** showing only
  the intended change (`agents/rules/apply-safety.md`, the #323 incident rule).
- **Reads-correct ≠ writes-agree.** The D1 shadow's `diverged=0` compares append
  *counts* on the write path and never reads back; it is not evidence for a read
  flip. Read-path claims need content-level (digest) comparison.
- **Absence ≠ disagreement.** A comparison where one side is missing is a third
  outcome, never a divergence. Two separate measurements in this program
  produced false divergences by violating this (3 phantom, then 60 phantom).
- **A digest is computed *at* a version.** Comparing digests across different
  versions is meaningless; comparisons must be version-matched.
- The D3 read path is the only EHDB dataset with server-side wiring (5 modules:
  `ehdb_projection_fold`, `_mirror`, `_mirror_queue`, `_parity`, `_read`). Every
  other dataset would be a greenfield build.
- `d7_catalog` is a name with no `Dataset` implementation — relevant only as the
  reason this spec targets D3 and not the larger `noetl.catalog` table.

## Acceptance Criteria

- [x] **AC1 — Behind serves with a forward fold.** A snapshot whose version is
      below the spine's is served, and the caller is told to fold forward from
      the *snapshot's* version (not the spine's).
      *Status: implemented in server#423, merged, released as v3.108.0.*
- [x] **AC2 — Ahead is unrepresentable.** There exists no value a caller can
      construct or pass that causes an ahead snapshot to be served.
      *Status: `ServeGrant` has a private field and no public constructor;
      `ServeGrant::evaluate` is the only way to obtain one and cannot produce one
      for `stored > spine`.*
- [x] **AC3 — The ahead guard is mutation-proven, not merely present.** Removing
      it, weakening `>` to `>=`, folding forward from the wrong version, and
      reordering the ahead check after the digest check are each caught by a
      test.
      *Status: 4/4 CAUGHT. The reorder mutation was NOT caught by the first test
      set and required an added ordering control — recorded because a mutation
      that does not fail is a question about the test.*
- [x] **AC4 — The serve decision has enforced positive AND negative controls.**
      Controls run through the real `evaluate()`, and cover: exact serves, behind
      serves, ahead refuses, ahead-refuses-even-when-digests-agree, digest
      mismatch refuses, absent refuses, and ahead-is-checked-before-digest.
      *Status: 7 controls, all firing.*
- [x] **AC5 — Wired, not orphaned.** `ServeGrant::evaluate` has a real caller on
      the D3 read path, gated by a default-off flag, and a guard fails if the
      call site is removed or the gate is dropped.
      *Status: called from `wal_projection_state`; 3 wiring guards, all
      mutation-proven.*
- [x] **AC6 — The bounded verification uses the ladder.** The re-fold that
      verifies a behind snapshot at its own version goes through
      `events_for_recovery`, never `fold_spine_inner` directly.
      *Status: enforced by two guards. The first draft violated this and was
      caught by the pre-existing
      `recovery_reaches_the_spine_only_through_the_ladder` guard — a real
      ai-meta#307 bug, since the spine index evicts completed executions and the
      verification would have refused for exactly the executions it must cover.*
- [x] **AC7 — The released build carries the flag and defaults OFF.** Verified at
      the binary with a control that fires in both builds.
      *Status: v3.108.0 binary contains `SERVE_ON_BEHIND` ×1, v3.107.1 ×0;
      control string `RECOVERY_SOURCE` ×1 in both.*
- [x] **AC8 — Behind-serve is exercised under induced lag at a non-trivial
      denominator.** `stale_within_window` is non-zero under deliberately
      induced mirror lag, with `serve_refusal{*}` all zero.
      *Status: kind, v3.108.0, flag armed, 750 executions at concurrency 20–25:
      `stale_within_window=17`, refold `stored_behind_spine=17` (1:1), all four
      `serve_refusal` series 0. At concurrency 5 the mirror mean was ~16 ms and
      produced ZERO behind states — inducing the condition required real load.*
- [x] **AC9 — Content parity is version-matched, with a negative control.**
      Tier and Postgres digests agree, compared only at equal versions, with
      distinct digests proving agreement is non-trivial.
      *Status: 80 comparable, 80 agree, 0 differ, 80 distinct digests. ⚠ The
      first attempt compared across unequal versions and reported 60 false
      divergences; corrected.*
- [x] **AC10 — Prod deploy is prepped and reversible, not applied.** A full-spec
      server-side diff shows image-only change with the flag NOT set, and the
      revert is written down and rehearsed.
      *Status: 1 spec difference (image `b444baea…` → `867b822f…`),
      `volumeClaimTemplates` unchanged, env 62 → 62 with the flag absent. Revert
      recorded; the identical image-only roll has been performed twice on this
      StatefulSet.*
- [ ] **AC11 — Behind-serves are individually attributable.** A specific served
      read can be tied to a specific execution whose answer was then verified
      against Postgres. *(OPEN GAP — see Open Questions Q1.)*
- [ ] **AC12 — Ahead-refusal is demonstrated live, not only at unit level.** An
      induced ahead snapshot is observed being refused on a running server, with
      `serve_refusal{reason="stored_ahead"}` incrementing.
      *(OPEN GAP — see Open Questions Q2.)*
- [x] **AC14 — The bounded verification is independent of the store it verifies.**
      **CLOSED 2026-09-11** by noetl/server#424. Both verification legs
      (`wal_projection_state`, which decides `Match`, and `grant_for_behind`,
      the serve-on-behind leg) now fold `noetl.event`. Proven by
      `a_tier_missing_middle_events_is_refused_not_served`, which reproduces the
      `356712944081313792` shape (30 events in Postgres, 26 in the tier,
      **identical version**) and asserts `DigestMismatch` + `is_fault()`; its
      control folds the tier against itself and asserts `Match`, pinning what
      the shipped code did. Mutation-gated 11/11.
      ✅ **LIVE ON PROD since 2026-09-11 22:45Z** (v3.108.1, `b9bed030`). The
      verification is now Postgres-authoritative on the running build. ⚠ Its
      effect on the read path is **unmeasured** — that path is cold under
      `STATE_BUILDER=offserver` (2 reads in 35 min).
- [ ] **AC13 — Prod flip executed and held.** Flag armed on prod, `served_tier`
      and/or `stale_within_window` climbing, `serve_refusal{stored_ahead}=0`,
      no no-op re-drive storm, serving unaffected — then held for a soak window.
      *(OWNER-GATED — not to be executed without explicit go.)*

## Plan / Task Breakdown

1. **(done)** Build the pure serve decision with a grant type that makes ahead
   unrepresentable, plus positive and negative controls. — server#423 commit
   `4821ba8f`.
2. **(done)** Wire it into `wal_projection_state` behind
   `NOETL_EHDB_PROJECTION_SERVE_ON_BEHIND` (default off), with the bounded
   re-fold routed through the ladder. — server#423 commit `4cef1f14`.
3. **(done)** Merge + release inert. — merge `06fcfe70`, tag **v3.108.0**, AR
   digest `sha256:867b822f838bd54a9bc13069954f3ae337c836aa497759ba9a624574f6111daf`.
4. **(done)** Induce mirror lag in kind and prove behind-serve fires with content
   parity at a version-matched denominator. — AC8, AC9.
5. **(done)** Prep the inert prod deploy diff (image-only, flag unset) and
   rehearse the revert. — AC10.
6. **(open)** Close AC11: make a served behind-read individually attributable —
   see Q1 for the two candidate mechanisms.
7. **(open)** Close AC12: induce an ahead snapshot in kind and observe the live
   refusal — see Q2.
8. **(owner-gated)** Deploy v3.108.0 to prod (inert), soak, then arm the flag,
   watch, and hold or revert. — AC13.

## Open Questions

- [ ] **Q1 — How should a behind-serve be made individually attributable?**
      Metrics are counters and cannot tie a served read back to an execution.
      Candidates: (a) a structured log line at the grant site carrying
      `execution_id`, `stored_version`, `spine_version`; (b) extending the
      `projection-fold` diagnostic endpoint to report whether a grant *would*
      be issued and at what version. (a) is cheaper; (b) is queryable. Needs a
      decision before AC11 can be written as a test.
- [ ] **Q2 — How is an ahead snapshot induced without manufacturing corruption?**
      An ahead stored record is a corruption-like state that does not occur
      naturally (`serve_refusal{stored_ahead}=0` over the whole kind run means it
      never happened, not that it was tested). Options: write a synthetic
      projection record through the tier write path in kind; or add a
      test-only injection seam. Both have a cost; the second risks shipping a
      seam that exists only for tests.
- [ ] **Q3 — Does AC13's soak need prod's read path to fire at a useful rate?**
      Given `STATE_BUILDER=offserver` starves the D3 read (~0.6/hour), arming the
      flag on prod may produce a near-zero denominator indefinitely. Either the
      flip is accepted as low-signal-but-harmless, or it is deferred until the
      topology question is addressed. This is a scope decision for the owner.

- [x] **Q4 — How should a tier-sourced bounded verification be made independent?**
      **ANSWERED 2026-09-11: option (b)** — fold the bounded verification from
      Postgres regardless of recovery source. Landed in noetl/server#424.

      The measurement that settles it is the fold-source split on prod:

      ```
      recovery_fold{source="spine"} spine_incomplete  25390
      recovery_fold{source="spine"} folded                0
      recovery_fold{source="tier"}  folded            25349
      ```

      The spine **never** completes on prod, so the ladder resolves to the tier
      on 100% of calls. That re-prices every option:

      - **(a) refuse on tier fallback** — refuses ~100% of behind-serves. The
        flip becomes a no-op that still consumes the flag and the soak window.
        It reads as the conservative choice and is actually the vacuous one.
      - **(c) accept + out-of-band comparator** — violates the stated bar
        outright. Execution `356712944081313792` sat divergent for 15+ min and
        blocked nothing; worse, it was being served as `Match`, not merely
        going unnoticed.
      - **(b) fold from Postgres** — the only option that can see a gap in the
        mirror, because it is the only one reading something other than the
        mirror.

      The cost argument against (b) was that it puts Postgres back on the hot
      path. That cost is **already being paid**: the WAL path hands
      `rebuild_state` a snapshot with `version: 0`, so the caller re-reads the
      execution's entire event set from Postgres immediately afterwards
      (`orch_snapshot.rs:211` → `events.rs:2274`). (b) makes an existing read
      honest rather than adding a new one.

⚠ This spec is **not approved**. Q3 and Q4 are resolved; **Q1 and Q2 remain
open**, and AC11/AC12 with them. AC1–AC10 are satisfied and recorded as the
established baseline. AC14 is closed in code and awaits a release + inert
deploy. AC13 is owner-gated and currently **no-go** — see `arm-runbook.md`.

**AC11 and AC12 are left explicitly open rather than argued closed:**

- **AC11** (behind-serves individually attributable) — the *denominator*
  problem is solved (prod load produced 180 `served_tier` reads off 51
  executions, ~1 read per 3), so the volume is reachable. What is missing is
  the attribution mechanism itself, which is Q1 and needs a scoped code
  change. Not closable by measuring harder.
- **AC12** (live ahead-refusal) — `ServeGrant` has a private field and no
  public constructor, so an ahead snapshot is **structurally
  unrepresentable**; `evaluate` cannot return one. Inducing it live therefore
  requires a test-only injection seam. Per this work's loop escalation path,
  that seam is not to be shipped unilaterally: a seam that exists only for
  tests is itself a surface, and accepting compile-time + property evidence
  for the ahead case is a legitimate answer the owner may prefer. **Owner
  decision, not an engineering gap.**

## Verification Plan

| Criterion | How it is checked |
| :-- | :-- |
| AC1, AC2 | `cargo test --lib ehdb_projection_serve` — property sweep asserts no grant is ever issued for `stored > spine` across 30 ahead combinations. |
| AC3 | Mutation harness: apply each of the 4 mutations, confirm the suite FAILS, restore, confirm it passes. Harness must distinguish a compile error from a caught mutation (a prior harness reported catches as compile errors). |
| AC4 | `every_serve_control_fires` drives all 7 controls through the real `evaluate()` and asserts each fires. |
| AC5, AC6 | Source-level guards over the non-test region of `ehdb_projection_fold.rs`, each asserting its own extraction size first so an empty slice cannot pass. |
| AC7 | `crane export <image> \| grep -ac SERVE_ON_BEHIND`, run against **both** v3.108.0 and v3.107.1, with a control string present in both. A zero is only meaningful beside a control that fires. |
| AC8 | kind with flag armed + `STATE_BUILDER=server` + `READ_SOURCE=wal`; drive load until `stale_within_window > 0`; assert `serve_refusal{*} = 0` across all four pinned series. |
| AC9 | For each sampled execution call `/api/ehdb/projection-fold/executions/{id}`; compare digests **only when `tier.version == postgres.version`**; count version-mismatch and absent-side as a third outcome; require distinct-digest count > 1. |
| AC10 | `kubectl diff --server-side -f <spec>` plus a structured whole-object comparison asserting exactly one spec difference; then rehearse the revert and confirm via `noetl_server_build_info{version}`. |
| AC11 | Still pending Q1 — attribution mechanism, not measurement volume. |
| AC12 | Still pending Q2 — needs a test-only seam; owner decision. |
| AC13 | Post-arm: `served_tier`/`stale_within_window` climbing, `serve_refusal{stored_ahead}=0`, no-op storm at 0/min, dispatch completing end-to-end, 0 ERROR — with the revert one command away. |

⚠ **Denominator discipline applies to every row above.** A result is reported
with the population it measured. `served_tier=0` alongside `spine_incomplete=0`
means *not exercised*, not *healthy* — the two are indistinguishable without the
denominator, and this program has produced that false-clean reading more than
once.

## Change Log

Append-only, per `agents/rules/spec-driven-development.md` ("log scope changes as
new dated notes rather than silently rewriting Goals or Acceptance Criteria after
implementation has started"). This spec was shared for review as
[noetl/ai-meta#334](https://github.com/noetl/ai-meta/pull/334) before the entries
below.

### 2026-09-11 — inert prod deploy of v3.108.0 executed (owner-authorized)

Plan step 8 is **half done**: the image is deployed, the flag is **not** armed.
AC13 remains unchecked, because it requires the flag armed plus a soak — not the
deploy alone.

Pre-apply gate (re-run immediately before the apply against freshly captured
live state, not the spec prepped hours earlier):

- structured whole-object comparison: **exactly 1 spec difference** — the image
  (`b444baea…` → `867b822f…`);
- env **62 → 62**, env name-sets identical, `SERVE_ON_BEHIND` **not added**;
- `volumeClaimTemplates` unchanged; volumes, volumeMounts, containers,
  resources, replicas all unchanged;
- `NOETL_EHDB_RECOVERY_SOURCE=tier` present in the object being applied.

Post-apply verification:

| check | result |
| :-- | :-- |
| running digest | `sha256:867b822f…`, `build_info version="3.108.0"` |
| flag in pod env | **absent** (62 vars) — deploy is inert |
| `recovery_source_info{tier}` | **1** — the prior GO flip survived the roll |
| `serve_refusal` series | **0 → 4** — proves the new build is running |
| `stale_within_window` | **0** — serve-on-behind did **not** engage, as required with the flag off |
| pod | 1/1, **0 restarts**, health `ok`, database connected |
| logs | **0 ERROR**, 0 panic; WARNs all pre-existing kinds |
| no-op storm | **0/min** (the 2026-09-09 failure signal was ~52/min) |
| PV | **1072 KB before and after** — data survived the roll, same PVC rebound |
| canary | submitted 10 s, **reached a terminal event** end-to-end |

⚠ Worth recording because it changes a number quoted in the Problem section: at
pre-apply baseline prod showed `projection_read_total{served_tier}=1` and
`{stored_behind_spine}=24`. The Problem section's "0 served / 11 of 11 refused"
was measured on 2026-09-10; prod has since served once. The **shape** of the
problem is unchanged (refusals still dominate at 24:1) but the literal "never"
is now "once", and the spec should not keep asserting a stale zero.

Revert, unchanged and rehearsed:

```
kubectl --context gke_shastaratech-noetl-prod_us-central1_noetl-prod-autopilot -n noetl \
  set image statefulset/noetl-server-rust-embedded \
  noetl-server=us-central1-docker.pkg.dev/shastaratech-noetl-prod/noetl/server-rust@sha256:b444baeabaa60b4041ec3dd8351ab2b3552ae78af83514385d8686a48917510b
# confirm: noetl_server_build_info{version="3.107.1"} 1
```

Postgres untouched and authoritative throughout; nothing dropped or truncated.

### 2026-09-11 — v3.108.1 DEPLOYED to prod (owner-gated); AC14 fix now live

Applied 22:45Z. Pre-apply full-spec diff re-run live: **image-only, one hunk**
(`867b822f` → `b9bed030`), flag absent, env 62, `READ_SOURCE=wal`,
`RECOVERY_SOURCE=tier`, `replicas: 1`. Post-apply whole-object diff against the
pre-apply snapshot showed **only the image line**. Pod 1/1, **0 restarts**,
`build_info{version="3.108.1"}`, health 200, **0 ERROR / 0 WARN**. Dispatch
end-to-end healthy: 5/5 probe executions COMPLETED with 30 events each.

**Verdict: HOLD (do not revert).** No abort trigger met — no crash, no latency
regression, no no-op storm (`nonconvergence_sweep` 15 candidates / 15
`skipped_live`), `stored_ahead` 0, `recovery_source` still tier.

⚠ **The soak's headline signal is UNOBSERVABLE at current traffic, and that is
reported rather than papered over.** The D3 read path is cold under
`NOETL_STATE_BUILDER=offserver`: **2 reads in 35 minutes**, against a pre-deploy
baseline of 29,842 on a 16h-old pod — which was dominated by the earlier load
run, not steady state. So `served_tier=0` here is **absence of traffic, not the
refuse-everything abort trigger**, and `digest_mismatch` cannot rise-then-fall
when nothing reads. A bounded probe (5 × `test/simple_loop`, concurrency 1)
moved the counter by **+1**. The deploy is stable; the behaviour change is
**unmeasured on the read path**.

**What the comparator does show, and it is a flip-killer.** Exercised directly
(`/api/ehdb/projection-fold/executions/`), tier-vs-Postgres divergence is
**widespread and persistent**:

| population | divergent |
| :-- | :-- |
| 5 probe executions, re-checked after ~12 min settle | **4/5** (23/30, 23/30, 26/30, 22/30; one converged 30/30) |
| **7 executions created BEFORE the roll** (the control) | **7/7** |

The pre-deploy control is what settles attribution: **the gap is pre-existing and
the deploy did not cause it.** Three of the seven have no tier record at all, and
three have *equal counts* with disagreeing digests — content divergence, not
missing events (the #325 class). Re-checking after settle is what separates this
from lag: one probe execution did converge, so the mirror works sometimes.

⚠ Per the runbook this is **explicitly not a revert condition**: reverting would
restore a build that verifies the tier against itself and serves these as
`Match`. The fix is doing its job — it makes a real, widespread gap refuse
instead of serve.

**Consequence for AC13:** the serve-flip stays **NO-GO**, and the blocker is no
longer the verification (fixed, shipped, live) but **mirror coverage**. Arming
the flag over a mirror that loses events on most executions would widen serving
over exactly the population that cannot be served correctly.

### 2026-09-11 — #424 merged and released as v3.108.1 (NOT deployed)

Owner authorized merge + release only. Prod still runs **v3.108.0**; the deploy
is a separate gate because this change is **not inert**.

| | |
| :-- | :-- |
| merge commit | `f82f69f7` (conventional subject, so semantic-release reads it) |
| release commit | `aea78ec7` |
| tag | **v3.108.1** — read back from the remote, not assumed |
| AR digest | `sha256:b9bed0304104247caa7b01594033c216ff98fa09f275173d7011160d07d075ee` |

Pre-merge gate: `MERGEABLE`/`CLEAN`, CI green, branch 0 commits behind main,
1063 tests pass, and the mutation battery re-run **11/11 on the exact merge
content** rather than trusting the earlier run.

⚠ The merge subject was set explicitly to `fix(ehdb): …` rather than accepting
`Merge pull request #424 from …`. Per `release-versioning.md` a non-conventional
merge subject releases **nothing, silently** — the failure mode that costs a
build cycle to discover.

**Fix confirmed in the built artifact**, by symbol inspection of
`app/noetl-control-plane` (linux/amd64) in both images:
`bounded_fold_agrees` / `bounded_fold_at` / `events_from_postgres` present in
v3.108.1 and absent in v3.108.0; shared symbols (`wal_projection_state`,
`grant_for_behind`) present in **both** as the positive control that makes those
zeros meaningful; a nonexistent symbol 0 in both; version string `3.108.1`
present and `3.108.0` absent. Digest resolution was itself controlled — resolving
`v3.108.0` by the same method returns exactly the digest prod is running.

**Deploy prepped, not applied** — `deploy-3108.1-runbook.md`. Full-spec
server-side dry-run is **image-only** (one line), with `env` unchanged at 62 and
the flag still absent; a positive control confirms the diff method reports a
second change when one exists.

⚠ **This deploy changes live behaviour, unlike the v3.108.0 roll.** The v3.108.0
deploy was genuinely inert because its flag defaulted off. This one alters the
*currently live* read path: the check that decides `Match` becomes able to fail.
The expected outcome is **fewer `served_tier` and more refusals**, and a refusal
falls back to a full Postgres rebuild — the safe direction. So the soak watches
`digest_mismatch` **rise and then fall**; a rise is the fix becoming visible, not
a regression, and the discriminator for a real gap is *persistence*, not
presence. ⚠ `served_tier` falling to **0** is an abort trigger — that would be
the option-(a) refuse-everything failure this fix was chosen to avoid.

Reverting is an image rollback to `867b822f`, rehearsed. ⚠ Revert restores the
defect, not correctness — revert for a crash/latency/storm, never because
`digest_mismatch` is non-zero.

### 2026-09-11 — Q4 answered, AC14 closed, and the serve path found to be live

Worked the spec's remaining open questions. Three findings, in the order they
changed the picture.

**1. The spine never folds on prod, so the self-reference is total.**
`recovery_fold{source="spine"}` is 25,390 `spine_incomplete` against **0**
folded, while the tier folded 25,349. The recovery ladder resolves to the tier
on 100% of calls. Q4's option (a) — refuse on tier fallback — would therefore
have refused ~100% of behind-serves: a flip that ships, changes nothing, and
looks conservative while being vacuous. Answered **(b)**; see Q4.

**2. The flag is not what put the tier on the read path.** `wal_projection_state`
compares a tier record against a fold of the same tier events and serves on
`Match`. `orch_snapshot.rs:193` maps `ReFoldVerdict::Match => "served_tier"`,
and prod shows `served_tier = 2212` **with `SERVE_ON_BEHIND` off**. The flag
widens serving from `Match` to `Match + StoredBehindSpine`; it is not the thing
that made the tier authoritative for reads. The serve-flip question was
therefore smaller than assumed and the correctness question larger.

⚠ This inverts how AC14 was originally filed. It was logged as a gap in the
*bounded* verification behind the gate — a risk the flip would introduce. It is
actually a defect in the verification that is **already deciding live reads**.

**3. The `356712944081313792` shape is served, not merely unnoticed.** `version`
is `max(event_id)`, so a tier missing MIDDLE events reports the *same version*
as Postgres. Both sides of the old comparison folded the same 26 events →
equal version, equal digest → `Match` → served as correct. The stated bar —
"a completed execution whose tier copy is missing events must NOT be served as
if correct" — was being violated on the current build.

**Fix:** noetl/server#424. Both verification legs fold `noetl.event`. Postgres
remains never-a-source and never-a-fallback; it is the verifier. Three pure
functions were extracted (`events_from_postgres`, `bounded_fold_at`,
`bounded_fold_agrees`) because the serve decision was inline behind a `DbPool`
and **a mutation replacing the entire agreement check with `true` survived the
full suite**. Now mutation-gated 11/11; two of the eleven (M6 ordering, M8
no-verification) only became catchable after the extraction.

A guard **inverted**: `the_bounded_verification_uses_the_ladder` →
`..._is_independent_of_the_tier`. Its property never changed — the serve
decision must rest on evidence independent of the thing served — but the source
satisfying it moved, because the original reasoning (the ladder gives completed
executions coverage, ai-meta#307) was right about coverage and wrong about what
was being compared.

**Separate live defect found and filed, deliberately not fixed here:**
noetl/ai-meta#335. The WAL path hands `rebuild_state` `version: 0`, so every
event is applied **twice** onto the tier-folded base. Of the 4 accumulating
mutations in `apply_event`, 3 are dedup-guarded by set inserts and
`iterations_dispatched` is not — so `dispatched = 2N` while `completed = N`, and
`orchestrator.rs:845` reads that as "an iteration is in flight" and never
dispatches the next one. `test/simple_loop` is `mode: sequential`. Reproduced
at unit level (`left: 2, right: 1`). It is ~83% masked because most reads return
`no_stored_record` and rebuild cleanly from Postgres, which makes the symptom an
intermittent non-dispatch rather than a hang. Kept out of #424 because the fix
changes the canonical state digest for every iterator step, on a path already
live in prod — that is the owner's call, not a rider on a correctness PR.

**Prod untouched.** Everything above is code, unit-level proof, and read-only
`--dry-run=server` diffs. No apply, no arm.

### 2026-09-11 — synthetic load against prod v3.108.0 (flag OFF, inert build)

Bounded run: **51 executions** over ~4.5 min of load — 30 at concurrency 1
(30 ok / 0 err, p50 **210 ms**) then 21 at concurrency 2 (19 ok / **2 err**,
p50 **19,560 ms**, throughput *inverting* 0.25 → 0.13/s). Stopped there rather
than escalating: throughput going down as concurrency goes up is saturation, and
8-way concurrency wedged prod for ~40 min on 2026-09-09.

**Answers Q3 (the "is a flip measurable?" question): YES, decisively.**

| | |
| :-- | --: |
| D3 reads at idle | ~**1.4/hour** (2 in 87 min) |
| D3 reads under this load | **180** `served_tier` |
| reads per execution | ≈ **1 per 3** |

The ~0.6–1.4/hr trickle is an artefact of an idle prod, not of the topology.
`STATE_BUILDER=offserver` starves the read path *relative to traffic*, but the
absolute rate scales with executions, so a flip is measurable under load.

Read path (cumulative on this pod): `served_tier=180`,
`stored_behind_spine=2`, `digest_mismatch=2`, `no_stored_record=1`,
`stale_within_window=0`. All four `serve_refusal` series **0**.

⚠ `digest_mismatch=2` on the read path is the guard **refusing on the live serve
path** — evidence the refusal arms are reachable in production, not only in kind.

#### ⚠⚠ Transient divergence under load is NOT divergence — 13 phantoms avoided

During load, 13 of 42 comparable executions showed **same version, different
`applied_count`** (tier 27/23/16 vs Postgres 30) with `context_explains_the_gap:
false`. Because `version = max(event_id)`, a tier that received the *last* event
but not some middle ones reports the same watermark with fewer events — which is
exactly what an **async** mirror does under concurrency.

Every one of the 6 sampled re-converged within ~3 min (tier n=30, digests agree).
**Reporting those 13 as divergences would have been a false flip-killer.** The
discriminator is re-checking after settle; a single-shot sweep cannot tell
transient lag from loss.

Settled sweep, same 60 executions:

| | |
| :-- | --: |
| comparable (same version) | **60** |
| digests **agree** | **59** |
| digests differ | **1** |
| not comparable | **0** |
| distinct digests | **59** (negative control) |

#### ⚠⚠ One PERSISTENT divergence — a real tier gap

`356712944081313792` (`test/simple_loop`, COMPLETED 08:09:58Z, 30 events):
tier folded **26 of 30** at the same version, still divergent **15+ minutes**
later. The mirror's retry window is ~64 s, so this is not lag. The tier is
missing 4 events for a completed execution.

#### ⚠⚠ The bounded verification is self-referential for completed executions

`events_for_recovery` falls back to `tier_events_within` when the spine refuses
and `mode.serves_tier()` — true under prod's live `RECOVERY_SOURCE=tier`. A
completed execution has no spine, so **both** the fold and `grant_for_behind`'s
bounded re-fold read the **tier**. A tier missing events is missing them on both
sides, the digests agree, and the check passes on incomplete data.

Scope, stated precisely rather than alarmingly: the D3 *serve* path answers
rebuilds for **in-flight** executions, where the spine is present and the check
**is** independent. The self-reference bites when the spine refuses for an
in-flight execution (`WAL chain incomplete`, which does occur) — then a served
read is verified against the same store it came from.

**This does not block the inert build, and it is not a new defect class** — it is
the "a digest compared with itself" shape #265 A3 already names. But it is a
**new AC for the flip**, added below.

#### Health throughout

0 ERROR, 0 panic, 0 restarts (100 min uptime), no-op storm **0/min** at rest
(peaked at 7/min under load, vs the 52/min failure signal), `recovery mode
tier=1`, flag **absent** from the pod's 62 env vars, `stale_within_window=0` —
the deploy stayed inert under load. All load generators cleaned up.

## Linked Issues

- **Coordination issue: [noetl/ai-meta#336](https://github.com/noetl/ai-meta/issues/336)**
  — status, task breakdown and PR links for this spec, per
  [`agents/rules/spec-locations.md`](../../../agents/rules/spec-locations.md)
  (file = truth, issue = tracking, wiki = reading room). Indexed on the
  coordinator wiki's Specs Index.
- Per-plan-item issues: (filled in by `spec-to-tasks` once the spec is approved)
- Related umbrella: [noetl/ai-meta#332](https://github.com/noetl/ai-meta/issues/332)
- Related: [noetl/server#423](https://github.com/noetl/server/pull/423) (merged),
  [noetl/server#419](https://github.com/noetl/server/issues/419),
  [noetl/ai-meta#307](https://github.com/noetl/ai-meta/issues/307),
  [noetl/ai-meta#265](https://github.com/noetl/ai-meta/issues/265)
