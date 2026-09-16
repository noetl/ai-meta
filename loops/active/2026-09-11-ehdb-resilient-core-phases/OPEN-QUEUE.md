# Open work, and what each is waiting on

Updated 2026-09-16. Eleven PRs/branches are open. **None has been self-merged and
none is rolled to prod.** Eight are independently shippable; two are held on a
decision that is not mine.

## Independently mergeable — nothing blocks review

| PR | what | why it is independent |
| :-- | :-- | :-- |
| [noetl/server#441](https://github.com/noetl/server/pull/441) | Postgres as the recovery ladder's final rung — a tier that cannot answer no longer ends recovery | server-only; no tier storage format, no worker change, no config change |
| [noetl/server#442](https://github.com/noetl/server/pull/442) | the execution path filter is applied before the candidate window, not after — it was returning false empties | server-only; one query shape, no storage or config change |
| [noetl/ehdb#360](https://github.com/noetl/ehdb/pull/360) | a truncated TAIL record is skipped and counted; anything else still fails the open | library-only; changes a read posture, adds no dependency, no deployment coupling |
| [noetl/ehdb#359](https://github.com/noetl/ehdb/pull/359) | the Arc forwarding impl dropped `failure_domain`, and nothing called the guard | library-only; restores an already-specified behaviour |
| [noetl/worker#321](https://github.com/noetl/worker/pull/321) | each test thread gets its own metric and serve state (#299, #302) | **test-only**: both scopes are `#[cfg(test)]`, so no production path changes at all |
| [noetl/ehdb#343](https://github.com/noetl/ehdb/pull/343) | the second-substrate choice, written up for the owner | docs only |
| [noetl/server#443](https://github.com/noetl/server/pull/443) | `/api/catalog/list` stops shipping every body by default — 32 MB → 811 kB at the same 2539 rows (noetl/server#436) | server-only; no storage change, no config change |
| [noetl/server#444](https://github.com/noetl/server/pull/444) | the embedded-shadow root actually fails closed when nothing is mounted (noetl/server#419) | server-only; verified it does NOT turn off the working prod shadow |


All are kind-proven or workspace-green with two-sided negative controls. All are
additive and reversible. They are waiting on review, not on a decision.

⚠ [noetl/worker#222](https://github.com/noetl/worker/pull/222) is also open but
is **not** mine to merge on evidence: it stops `publish-ar` reddening every
release, and that is only correct while noetl/worker#211 stays undecided.

## Held on the `cmdbus-writer` pin decision

| branch | what |
| :-- | :-- |
| `noetl/worker` `feat/348-durable-kv-object-shadow-store` | kv/object shadow tiers get a durable store on the writer's PVC + the tier-service read path |
| `noetl/server` `feat/348-kv-object-parity-comparator` | the per-tier parity comparator + its gated endpoint |

**Why held:** the prod rollout requires moving `sts/noetl-cmdbus-writer`, which
runs a deliberately different digest from the worker pools
(`sha256:c13b2957…` vs v5.132.5 `sha256:14759cee…`). `memory/current.md` records
it as held back on purpose and the reason is not written down anywhere I could
find. **Rollout order is load-bearing** — on a writer that predates the change
every shadow append is refused (correctly labelled `append_failed`, not lost
silently, but nothing accumulates).

The code is done and kind-proven; only the deployment is blocked. The documented
rollout sequence is in `kv-object-cutover/PROPOSAL.md` §8.

## Ready to merge, but the FLIP is an owner decision

| PR | what | what merging does | what flipping does |
| :-- | :-- | :-- | :-- |
| [noetl/worker#322](https://github.com/noetl/worker/pull/322) | a tool's error status emits `command.failed`, so a failed step stops the DAG (noetl/server#434) | **nothing** — byte-identical with `NOETL_EXECUTION_FAIL_ON_STEP_ERROR` unset | fails runs that have been silently completing with a failed step |

⚠ The flip does not introduce failures, it **surfaces existing ones**, in a
volume nobody currently knows — the defect is precisely that those runs report
success. `has_errored_step` (noetl/ai-meta#251) can count them from the existing
event log **before** anything changes, which is the measurement to take first,
then canary one pool. Rollback is one env var; nothing is written differently.

Same shape as `NOETL_EXECUTION_STATUS_FROM_STEPS`, and for the same stated
reason — a semantics change must be a deliberate flip, not a deploy side effect.
⚠ But that flag is **not a substitute** for this one: it changes what the read
boundary REPORTS, while downstream scheduling keys on the event TYPE. With it on
and this off, a run reports FAILED *and still executes every downstream step* on
a guard that already failed. Reporting FAILED while still running is not a gate.

## Owner decisions, with the artifacts prepared

| decision | artifact |
| :-- | :-- |
| the KV/object primary-serve cutover | `kv-object-cutover/PROPOSAL.md` — recommendation is **do not flip**; prerequisites now built, what remains is this decision, the writer pin, and noetl/ehdb#321 |
| the event-log durability substrate | `substrate/EVENTLOG-DURABILITY.md` — four options costed with rollback stories; **only option D is not cleanly reversible**, and it is the one the architecture points toward |
| the `cmdbus-writer` pin | no artifact; needs the reason it was pinned |
| flipping `NOETL_EXECUTION_FAIL_ON_STEP_ERROR` | [noetl/worker#322](https://github.com/noetl/worker/pull/322) — code ready, default off; measure with `has_errored_step` first, then canary |

⚠ The two proposals are **the same question in different clothes**: the
event-log tier is `primary` on a single-zone disk, and the kv/object shadow
tiers now sit on that same substrate. Neither cutover question can be settled
until the substrate one is.

## Closed this session

noetl/ai-meta#343 (hydration, shipped + verified in prod), #346 (parity
false alarm, shipped), #284 (batch tier-append, already done — closed with the
measurement), noetl/server#438 (resolve_canonical blind on GCS, shipped),
adiona/frontend#22.

## Closed with a measurement, no work needed

**noetl/server#300 (PR-level test CI).** The premise no longer holds: `test.yml`
runs `cargo test --all-targets --locked` on `pull_request` + push to `main`, and
every Rust repo has it (server, worker, cli, tools, ehdb, gateway). The red test
the issue cited as the cost is green on `main`.

⚠ But the TITLE's claim still stands, and it is an **owner action**: `main` is
**unprotected** in server, worker and ehdb (`404 Branch not protected`), so there
are no required status checks. A red suite is visible and does not block. That
needs branch protection / a ruleset, which changes merge policy for every
contributor — surfaced, not done. Worth noting while 8 open PRs' green checks are
advisory only.

## Measurement notes worth keeping

**noetl/server#419 — the live risk was already gone.** The issue reports prod
mounting no `/data`; it now mounts a 10Gi PVC, provisioned the day after filing.
So the fix closes a latent trap, not an incident: any deploy without that PVC
silently resumes writing to ephemeral storage. Scale from the mounted root —
357 MB in 7 days (~51 MB/day) against a 1Gi ephemeral limit is ~3 weeks to
eviction. ⚠ Verified the new guard does **not** turn off the working prod
shadow, on both the steady-state and fresh-pod paths.



**noetl/server#436 — the stated fix would not have fixed it.** The issue asked
for `limit`/`offset` with a default page and a hard cap, plus
`include_content`. Measuring first showed rows are not the problem: `content` is
55.9% of the response and `layout` a further **41.5%**, against **1.2%** for the
identity fields callers list by. So `include_content` alone leaves 41.5%
behind, and a row cap bounds nothing — the largest single prod entry is 509 KB,
so a 100-row page can still exceed 50 MB. A bounded DEFAULT would additionally
have truncated the GUI's playbook picker, which lists the whole catalog. What
shipped drops 97.4% of the bytes and **zero** records.

⚠ Also: the issue's 77.2 MB (1369 entries, 2026-09-13) no longer reproduces —
today it is 32.9 MB at 2539 entries. The count nearly doubled while the average
entry shrank. Same defect, different number.



**noetl/worker#299/#302 — the run count that proved nothing.** The metric-state
flake reproduces about **once in 25 full-suite runs at 32 test threads**. That is
too rare for a run-count comparison to distinguish a fix from luck, and it did
not: a 40-run fixed-vs-broken comparison came back **0 failures on BOTH sides**.
Both fixes in #321 are therefore proven against their mechanism — an explicit
sibling thread, deterministic RED 5/5 and 3/3 — not against a green streak.

Two corrections from that item, recorded because the wrong version was the
intuitive one:

1. #299 looked **already fixed** at the default thread count (6/6, then 8/8
   clean). It was not; the suite still flaked at 32 threads, through *other*
   tests. The first read was under-powered.
2. A guard banning exact-value metric assertions outright was **measured wrong**
   and discarded: a planted `assert_eq!(series_value(&text, health), Some(1))`
   passed 8/8, because that series is written by exactly one test. What is
   enforced instead is the one load-bearing assumption — every `#[tokio::test]`
   under `src/ehdb/` stays on a current-thread runtime.

A **third** process-wide race was found while measuring the first and is fixed in
the same PR: `projection::LAST_SERVE_STATE` had no guard at all, and at 32
threads `the_flip_is_never_silent_in_either_direction` read `"not_primary"` where
it had just written `"served_primary"`.
