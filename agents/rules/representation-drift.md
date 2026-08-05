# Representation drift — when the thing describing reality stops tracking it

A **representation** is anything that claims to describe the running system:
a manifest, a checkbox, a status column, a version pin, a dashboard, a
runbook. Every one of them is a copy, and a copy is only true while
something forces it to agree with the original.

This rule exists because in a single session five separate representations
were found lying, all confidently, none of them broken in a way any test
would catch. They are the same defect wearing five costumes.

## The five found on 2026-08-04/05

| # | representation | what it claimed | what was true |
| :-- | :-- | :-- | :-- |
| 1 | `ci/manifests/**` image pins ([#234](https://github.com/noetl/ai-meta/issues/234)) | workloads in project `noetl-demo-19700101` | prod is `shastaratech-noetl-prod`; 8 files, incl. all three prod deployments |
| 2 | `#194` T0–T5 checkboxes | none of the program shipped | all six shipped; NATS deleted entirely |
| 3 | `ehdb#241` phases 6–10 | nothing done | built + kind-validated, deliberately not serving |
| 4 | `noetl.execution.status` ([#235](https://github.com/noetl/ai-meta/issues/235)) | 3,225 executions RUNNING | frozen since the Python retirement; API says FAILED |
| 5 | worker `noetl-tools = "3.19.1"` ([#185](https://github.com/noetl/ai-meta/issues/185)) | DuckDB in the shipped image | caret range resolved to 3.26.1; `libduckdb-sys` gone |

Note how ordinary each cause is. Nobody edited the pin in #5 — a caret
range did it. Nobody falsified #2 or #3 — the boxes simply were not
ticked. #4 did not rot; it was *abandoned* when its writer was retired.

## Why tests do not catch these

A test asserts that code does what code is supposed to do. Every one of the
five is a claim about **the world outside the code**, and there is no
assertion site. #4 in particular had a green platform and a correct API the
whole time — the wrong number was in a column nothing reads and nothing
writes.

This is the sibling of [`inert-gate-audit`](../../playbooks/inert-gate-audit-20260804.md):
an inert gate is *logic that cannot fire*; representation drift is
*a description that cannot be wrong loudly*.

## The check

For any representation, ask the two questions in order:

1. **What forces this to agree with reality?**
   A CI job, a reconcile loop, a foreign key, a human ritual. If the honest
   answer is "someone remembering", it is already drifting — the only
   question is how far.
2. **If it disagreed, how would anyone find out?**
   If the answer is "they would have to already suspect it", the
   representation is not observable and must not be used as evidence.

A representation that fails both is **decorative**. Do not read a decision
off it, and say so where it lives.

## Rules that follow

- **Read the original, not the copy, when it matters.** Prod state comes
  from the cluster; execution status comes from the event log; the resolved
  dependency comes from `Cargo.lock`, not the manifest range. Every one of
  the five was caught this way and none other.
- **A number with no staleness signal is not evidence.** `noetl.execution`
  carried no "last maintained" marker, so it read exactly like live data.
  When publishing a derived number, publish its as-of.
- **Prefer derivation over denormalization.** #4 exists only because status
  was stored as well as derivable. When both exist, one will be wrong and
  the loud one is rarely the one being read.
- **A caret range is a decision made later by a resolver.** If a pin
  expresses a *capability guarantee*, the guarantee belongs in a feature
  flag or a lock, not in a range.
- **A guard that has not merged is not a guard.** worker#183 described the
  exact failure that then happened, and sat as a draft while it did.
- **When you cannot make the copy true, mark it.** Where a fix is a
  disposition decision (drop / annotate / replace), say so in the artifact
  and open the issue — do not leave a confident wrong value unremarked.

## The sibling question: is it *reached*?

Drift asks whether a description still matches the system. The neighbouring
failure is a thing that exists, is registered, is documented — and never runs.
Both produce confident clean readings, and the second is caught by asking
**reachability** rather than **existence**.

On 2026-08-05 that one substitution found, in a few hours:

| artefact | existence said | reachability said |
| :-- | :-- | :-- |
| two `#[test]`-less test fns | the test exists | never ran; one guarded the marker that stops the sweep terminating healthy work, while that sweep ran on prod |
| `record_nats_consumer_lag` | the recorder exists | no caller since T5 → three materializer alerts permanently inert |
| `NOETL_STATE_AFFINITY_ROUTE` | set `true` in prod | its only reader has no caller — the one inert flag of 77 |
| `EnvGuard`'s SAFETY note | claims `cargo test` serialises tests | it does not; the tests raced |

The reason it works is that **existence is what a naive grep measures**, and
every one of these passes that grep.

### The zeros to distrust

A clean result from a pattern-based scan is a claim about the pattern as much
as about the code. Each of these produced a confident, wrong zero:

- **A narrow read idiom.** Matching `env::var("X")` alone missed 55 of the
  worker's 107 variables, because it wraps typed reads in `env_bool` /
  `env_u32` / `env_addr` / `env_millis`. Server and gateway read directly, so
  two of three components looked consistent and the gap survived three passes.
- **Existence standing in for use.** "Does a recorder exist for each metric"
  reported *zero* orphans across 136 metrics. Every dead one had a recorder.
- **Comments counting as callers.** A doc comment naming a function, or prose
  naming a test, cleared two separate checks.
- **A stale local checkout.** Comparing code against an unfetched wiki made
  already-documented variables read as missing — and produced a duplicate
  section on a page that already had the row. Fetch before comparing.
- **Name ambiguity in both directions.** A bare `from_env` matches every type's
  `from_env`; a qualified `Type::method` misses `value.method()`.

And one substantive rule, not a tooling one: **a thing is unused only if
*every* use is unreachable.** `NOETL_SHARD_INDEX` is read by the dead affinity
path *and* reachably by the durable-eventlog backend. Finding the first reader
is not finding all of them.

### What to do with a clean result

Ask what a *positive* result would have looked like, and run something that
produces one. A check that has never once fired is indistinguishable from a
check that cannot fire — which is the same defect, one level up.

## When this rule does not fire

- Deliberately-frozen snapshots (rollback digests, incident captures, a
  dated audit). These are *records*, not representations of now — they
  should carry their date and are correct precisely by not updating.
- Shadow/observe-only surfaces documented as inert. Inert **and labelled**
  is a shipped shadow slice, not drift.

## A repeatable check

`playbooks/drift-audit.sh` runs the classes above mechanically — stale project
pins, a caret range that dropped a capability, published image architectures
vs where they must run, a release job reported working that is not, a table
the live control plane never touches, declared workloads that are not running,
**running pods no applied scrape selects**, **tests that carry no `#[test]`**,
**env vars the binary reads that its deployment-spec page omits**, and **metric
recorders nothing calls**. Eleven checks; read-only; one command.

That last check (`scrape`) generalises a subtlety worth stating on its own: an
**enumerated selector is itself a representation** — a copy of the workload set.
`podmonitoring-noetl.yaml` listed four worker `app` names, two of which never
existed, and omitted `noetl-worker-system-pool-shard1`, live since #166 Phase 5.
Applying it would have scraped half the system pool and looked green. Partial
monitoring coverage emits no error at all, so it can only be found by comparing
the selector against the cluster — which is what the check does.

It deliberately reports evidence rather than verdicts, because several of these
have a stale **issue** as well as a stale artifact, and the two want different
fixes.

What it cannot catch is the class it was written from: **unticked checkboxes for
shipped work** (#194, ehdb#241, #201). Those need the issue read against the
cluster, which is judgement, not grep.

## Related

- [`wiki-maintenance.md`](wiki-maintenance.md) Rule 0a — the dashboard is a
  representation and drifts the same way; this rule generalises it.
- [`issue-tracking.md`](issue-tracking.md) Rule 1b + [`roadmap-boards.md`](roadmap-boards.md)
  — pointer bumps reconcile three trails at once for exactly this reason.
- [`deployment-validation.md`](deployment-validation.md) — kind validation is
  the forcing function for the manifest→cluster representation.
