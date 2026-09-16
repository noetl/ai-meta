# Open work, and what each is waiting on

Updated 2026-09-16, after the merge round.

## ✅ Merged this round — ten PRs, all green on main

| PR | what | prod impact of the MERGE |
| :-- | :-- | :-- |
| [worker#321](https://github.com/noetl/worker/pull/321) | per-test metric + serve state (#299/#302) | none — `#[cfg(test)]` only |
| [worker#322](https://github.com/noetl/worker/pull/322) | a tool's error status stops the DAG | **none — gate default OFF** |
| [server#441](https://github.com/noetl/server/pull/441) | Postgres as the recovery ladder's final rung | behaviour change ⚠ not rolled |
| [server#442](https://github.com/noetl/server/pull/442) | path filter before the candidate window | behaviour change ⚠ not rolled |
| [server#443](https://github.com/noetl/server/pull/443) | catalog/list bodies off by default | **wire change** ⚠ not rolled |
| [server#444](https://github.com/noetl/server/pull/444) | embedded root fails closed | none — guard only |
| [ehdb#359](https://github.com/noetl/ehdb/pull/359) | Arc impl dropped `failure_domain` | library only |
| [ehdb#360](https://github.com/noetl/ehdb/pull/360) | torn tail skipped, anything else still fails | library only |
| [ehdb#343](https://github.com/noetl/ehdb/pull/343) | second-substrate write-up | docs |
| [ops#310](https://github.com/noetl/ops/pull/310) | digest ledger seeded with the rollback targets | none — nothing applies `ledger/` |

`main` after the merges: **worker** 19 binaries ok / 0 clippy errors; **server**
14 ok / 0 clippy errors; **ehdb** 80 ok / fmt clean / clippy clean.

⚠ **Merged is not deployed, and nothing was.** semantic-release cut versions and
the release workflows built images to Artifact Registry. No workflow in any repo
contains a deploy step. Verified against prod directly: every running pod's image
digest is **byte-identical** to the pre-merge baseline, with 0 restarts and pod
ages of 30h / 4h18m. Prod stays on its current digests until an explicit rollout.

⚠ The three behaviour-changing ones (#441, #442, #443) still want a canary and an
owner-timed rollout. #443 in particular is a **wire change**: anything reading
`content`/`layout` from `/api/catalog/list` now gets `null`.

## Open for review

| PR | what |
| :-- | :-- |
| [tools#99](https://github.com/noetl/tools/pull/99) | policy rules can see a transport failure — completes noetl/server#434's third symptom |
| [worker#324](https://github.com/noetl/worker/pull/324) | the three HTTP clients with **no timeout** are bounded (materializer ×2, plugin) |
| [tools#100](https://github.com/noetl/tools/pull/100) | a poll wait long enough for real Pub/Sub, and a clamp that stops truncating silently (noetl/tools#57) |

⚠ The care in #99 is the preservation half, not the fix: converting the `Err`
into a result would have moved every postgres failure from `command.failed` to
`command.completed`, and with `NOETL_EXECUTION_FAIL_ON_STEP_ERROR` off by default
the DAG would advance past it — **silencing a currently-failing path**, the exact
inverse of the issue. Rules gained the ability to fire; nothing that used to fail
stopped failing.

## Ready for review, but DEPLOY-GATED on the writer pin

| PR | what | why it must not merge yet |
| :-- | :-- | :-- |
| [worker#323](https://github.com/noetl/worker/pull/323) | the durable kv/object shadow store + the live mirrors routed to it | on a `cmdbus-writer` that predates it, **every shadow append is refused** (`append_failed`, not lost — but nothing accumulates). Merging would put an un-deployable-without-the-writer change into a release someone might roll by accident rather than choose. |

⚠ **Queue correction.** This file previously listed *two* held #348 branches. Only
one is outstanding. The server-side kv/object parity comparator and the ehdb
`event_id` pin bump are **already on main** and inert there — the comparator's
endpoint is gated. Rebased onto current main: 19 binaries ok, 0 clippy errors.

## Ready to merge, but the FLIP is an owner decision

| flag | PR | what flipping does |
| :-- | :-- | :-- |
| `NOETL_EXECUTION_FAIL_ON_STEP_ERROR` | worker#322 (merged, OFF) | fails runs that have been silently completing with a failed step |

⚠ Confirmed OFF on merged `main` three ways: unset → `unwrap_or_default()` → no
match → `false`; the test passes on main; and the variable appears in **no** ops
manifest. The flip surfaces existing failures in a volume nobody knows, because
the defect is that those runs report success — measure with `has_errored_step`
first, then canary one pool. ⚠ `NOETL_EXECUTION_STATUS_FROM_STEPS` is **not** a
substitute: it changes what the read boundary REPORTS while scheduling keys on the
event TYPE, so with it on and this off a run reports FAILED *and still executes
every downstream step*.

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

## Delivered to the wiki (no PR — wikis take direct pushes)

**noetl/ehdb#323** — both pages existed, and each was missing exactly the half
the issue asked for. Added: the shadow→primary **transition** section (visibility,
what is dual-written, what parity does NOT prove, the recovery ladder, a pre-flip
checklist) and the **L0–L3 layer stack + node roles**. Re-measured against prod
2026-09-16 rather than restated from design. Commits `61e5765`, `08e45b9`.

⚠ Two findings in it that bear on the owner decisions: `SERVE_ON_BEHIND=true`
means **projection reads are not read-your-writes**; and the
`NOETL_EHDB_<TIER>` mode variables are **not set on the prod pods at all**, so
live modes come from code defaults rather than any manifest.

## Closed with a measurement, no work needed

**noetl/server#344 + #345** (EHDB parity rounds 01/02) — both delivered; verified
against their acceptance lists in code, and #344 against **prod**:
`mirrored=1772` with **five other outcome arms reading a real 0**, and
`lag_seconds_count` equal to `mirrored` (so no silent path). That is the
"closed set pinned at 0 unconditionally" criterion demonstrated rather than
asserted.

**noetl/ehdb#320** (scope: four engines) — ⚠ `SCOPE.md` claims it "supersedes"
the README/AGENTS framing, and *supersedes is a claim, not evidence*. Read the
superseded docs: README leads with "four engines" and marks Qdrant/ClickHouse
explicitly out of scope, AGENTS matches. Delivered everywhere, not just in the
normative doc.

**noetl/tools#94** — the tools twin of server#300. `test.yml` runs on
`pull_request` with fmt + clippy, i.e. **stricter than server's or worker's**,
whose fmt steps are non-gating because their `main` is already dirty. Same
remaining gap: `main` is unprotected, so nothing blocks a merge.

⚠ Branch protection is now the single outstanding item across **six** repos
(server, worker, cli, tools, ehdb, gateway) and wants one owner decision applied
once — not six issues.



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

## ⚠ Two more of my own mistakes, both the same shape

**A grep that read comments as code.** I told noetl/tools#94 that its CI runs
`cargo fmt` and `cargo clippy` and is "stricter than server's or worker's". The
`cargo fmt` hits were inside a **comment block saying the opposite** — that repo
deliberately does not gate fmt (rustfmt 1.9.0 pins the tree) and runs clippy with
`|| true`. Corrected publicly on the issue. ⚠ This is the exact failure I built
comment-stripping into two test matchers to prevent today, committed in my own
analysis where no matcher was watching.

**An unchecked per-file claim.** I wrote in tools#100 that "my two files are
individually clean" on fmt without checking per file. `source/mod.rs` reports
dirty — the diff is rustfmt following `mod` declarations into sibling files
already dirty on `main`, so the substance held, but the claim was not one I had
verified. Corrected in the PR body.

## ⚠ A negative control that lied

**Twice today a negative control silently selected nothing.** While building
worker#324's guard, my first RED control **passed** — and the
guard was not at fault. `sed '0,/re/'` is a **GNU extension that BSD sed silently
ignores**, so the planted defect never landed and I was testing unmodified
source. Re-planted in Python with an asserted match count, the guard fails at
`materializer.rs:252` naming the exact line.

And again on tools#100: a RED control ran **0 tests** and looked like a pass,
because `cargo test` takes a plain substring, not the regex alternation I gave
it.

⚠⚠ The failure mode is the dangerous one: a control that *cannot fail* and a
control that *selects nothing* both look exactly like a passing test. Every plant
should assert the substitution happened AND the run should assert a non-zero test
count — `sed -i ''` on macOS is not GNU sed, and `cargo test` filters are not
regexes.

## ⚠ My own miss, worth keeping

**I pushed noetl/ehdb#360 red and reported it green.** I ran the suite and both
negative controls locally, but never `cargo fmt --check` or `cargo clippy`.
ehdb's CI gates both (`clippy --workspace --all-targets -- -D warnings`), so the
PR sat red on gates unrelated to the change's correctness while I described it
as "workspace-green".

Swept every open branch afterwards: two server branches also added fmt dirt in
my own files (#443, #444 — now fixed); the worker branches were clean. ⚠ Note
`server` and `worker` run `cargo fmt` **non-gating**, because `main` itself is
already fmt-dirty in `orchestrate-core/` — so a green check there does NOT mean
formatted.

**Also: a pre-existing CI flake, not mine.** `ehdb-feed`'s
`append_to_subscriber_latency_and_parity` asserts an absolute wall-clock
`p99 < 50_000 us`. It failed CI at 90121 us, passed on `main` AND on the branch
locally with identical runtime (20.49s vs 20.47s), and passed on re-run. Its own
comment says the bound is "generous so a loaded CI runner doesn't flake" — it is
not. Same class as noetl/worker#299: a test whose verdict depends on the machine.

## Measurement notes worth keeping

**noetl/worker#316 — the stated mechanism is impossible.** The issue attributes
an indefinite consumer wedge to blocking on a cross-pod shared-memory attach.
The worker has **no shm read path at all**: its only arrow-cache call is one
`put_arrow_ipc`. The cache is write-only — staged by the producer, read by
nobody — so a consumer cannot block attaching to it. The wedge is real; the
framing has been sending the investigation the wrong way.

Ruled out with evidence: control-plane HTTP (30s timeout, preserved across
`with_server_url`), `emit_event_with_retry` (bounded, logs each attempt),
`plugin.rs` (WASM only), and a stdin/stdout pipe deadlock (**probed directly and
disproven** at 16 KB / 100 KB / 1.6 MB).

Found instead: `noetl/tools` `python.rs:702-706` waits on
`child.wait_with_output()` with **no bound** when a step configures no timeout,
so any child hang wedges the command forever, silently — matching the symptom
profile. ⚠ It does **not** explain the cross-pod correlation, and I am not
presenting it as the root cause. Settling that needs the 3-replica kind repro
with the wedged pod's stack sampled, not more code reading.



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
