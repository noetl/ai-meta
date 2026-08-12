# Staged for GitHub — nothing pushed

Session 2026-08-11 (late). The session was told GitHub was down and to defer
every push / PR / issue comment. **Note for whoever picks this up: `gh` reads
worked throughout this session** — that is how server#343 and worker#265 were
confirmed still *open*, which changed the branch base for this work. Writes were
still withheld, as instructed. Nothing below has left this machine.

## Branches (local only)

| repo | branch | based on | contains |
| :-- | :-- | :-- | :-- |
| `noetl/server` | `feat/258-server-authored-mirror` | `origin/feat/ehdb-crossstore-parity` (PR #343, **open**) | the server-side mirror + comparator scope widening |
| `noetl/worker` | `feat/258-server-authored-mirror` | `origin/feat/ehdb-authoritative-event-id` (PR #265, **open**) | the append relay + the worker-side disarm |

Both branch off **open PRs**, not `main`. They must not be pushed as PRs against
`main` — either #343/#265 merge first and these rebase, or these are stacked on
top and reviewed as such. Opening them against `main` would show the comparator's
1,944 lines as part of this change.

## Wiki edits (local only, in the submodules)

* `repos/noetl-server-wiki/deployment-specification.md` — `NOETL_EHDB_EVENTLOG_MIRROR_SOURCE` row.
* `repos/noetl-worker-wiki/deployment-specification.md` — same variable, worker half.

Required by `wiki-maintenance.md` Rule 2a in the same change set as the env-var
addition.

## Not yet written, and deliberately so

These need the gate result to be accurate, and are listed so they are not
forgotten rather than because they are drafted:

* **ai-meta#258 comment** — the closure, the measured full-set match, and the
  fact that the "6 of 13" finding is now addressed rather than merely documented.
* **ai-meta#257 §3.4** — the event-log flip's stated blocker was an incomplete
  tier. That paragraph needs a correction note, not a silent edit.
* **Sub-issues** — one per submodule per `issue-tracking.md` Tier 2, linking up
  to #258.
* **Board status** — #258 is already `In progress` on project 3; it stays there
  until the PRs land.
* **ai-meta wiki** `Home.md` + `Sessions-Log.md` + the matching `Umbrella-*` page
  per `wiki-maintenance.md` Rule 0a.
* **ai-meta pointer bumps** — none yet; the submodule PRs have not merged.

## Explicitly NOT done, and must stay that way

* No prod change of any kind.
* No tier promoted to `primary`.
* No `NOETL_EHDB_TIER_SERVICE_*` or `NOETL_EHDB_EVENTLOG_MIRROR_SOURCE` set on
  prod.
* Kind was restored to released images with no EHDB env after the gate.
