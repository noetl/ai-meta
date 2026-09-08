# Every change is documented twice — centrally and in its own repo

A standing mandate. It exists because a change recorded only in ai-meta is
invisible to whoever opens the repo it actually landed in.

## The rule

**Every substantive change gets BOTH:**

1. **A central record in ai-meta** — a `memory/` topic file and/or an entry in
   the ai-meta wiki's `Sessions-Log.md`, plus the `MEMORY.md` index line, per
   [`wiki-maintenance.md`](wiki-maintenance.md) Rule 0a.
2. **The affected repo's own wiki updated** — `noetl-server-wiki`,
   `noetl-worker-wiki`, `noetl-tools-wiki`, `noetl-cli-wiki`, `ehdb-wiki`,
   `noetl-ops-wiki`, and so on. It must describe **what changed in that repo**,
   in that repo's own terms — not a copy of the central log entry.

Both, in the same change set as the code. Not "later".

## Why both, and why they differ

They have different readers and answer different questions.

- **ai-meta** answers *"what happened across the system, and why"* — the
  cross-repo arc, the decision, the sequence. Its reader is someone
  reconstructing a program.
- **A repo's wiki** answers *"what does this component do now"* — the surface,
  the invariant, the knob. Its reader is someone opening that repo, who will
  never see the central log and should not have to.

⚠ **Copying the ai-meta entry into the repo wiki satisfies neither.** The
cross-repo narrative is noise to a component reader, and it usually omits the
thing they need: the new function, the changed default, the guard they must not
delete. Write the repo entry from the diff, not from the summary.

## What counts as substantive

The same threshold as [`issue-tracking.md`](issue-tracking.md) Rule 1: new
behaviour, changed behaviour, a bug fix worth finding later, or anything that
changes a public surface. Cosmetic refactors and lint fixes do not.

Specifically, in a repo's wiki, record:

- a new module, type, or public function, and what invariant it holds;
- a changed default or a new env var (per
  [`wiki-maintenance.md`](wiki-maintenance.md) Rule 2a, deployment-spec pages are
  the source of truth for env vars);
- **a guard and what it exists to prevent** — the single most valuable thing to
  write down, because a guard whose purpose is unrecorded is a guard someone
  deletes as noise;
- a decision that constrains future work in that repo.

## When a repo has no wiki

Stop and ask for it to be enabled, per `wiki-maintenance.md` Rule 1b. Do not
silently skip — that is how the drift starts.

## Coordination

- [`wiki-maintenance.md`](wiki-maintenance.md) — the mechanics of which wiki, and
  the ai-meta dashboard's four-page discipline.
- [`issue-tracking.md`](issue-tracking.md) — the issue is the third trail; a
  pointer bump reconciles all three.

## History

Codified 2026-09-08 from a standing instruction: *"track everything in the
ai-meta repo memory AND update the per-repo wiki docs in each repo we change."*
Prompted by a run of cross-repo work whose central record was thorough while the
per-repo coverage was thin.
