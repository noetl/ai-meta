# Staged for GitHub — nothing pushed

Session 2026-08-12. The instruction for this session was explicit: build and
prove in kind, **do not push, open PRs, merge, or comment on issues**. Nothing
below has left this machine.

**GitHub was reachable throughout.** `gh issue view 257`, `git fetch` and
`git ls-remote` all succeeded. The two previous sessions recorded the same. The
"GitHub is down" premise that shaped the earlier PENDING-PUSH files was wrong
then and is wrong now — writes are being withheld by instruction, not by
availability.

## Branches (local only)

| repo | branch | based on | contains |
| :-- | :-- | :-- | :-- |
| `noetl/worker` | `feat/257-pr4-tier-query-service` | `feat/258-server-authored-mirror` @ `11e7145` | `19862ca` PR-4 completion, `7fd7e42` the stale startup line |
| `noetl/server` | `feat/257-pr4-tier-query-service` | `feat/258-server-authored-mirror` @ `b97e3bf` | `2206728` the verdict names its store |

**This is a three-deep stack, and it must not be opened against `main`.**

```
main
 └── worker#265  feat/ehdb-authoritative-event-id   (OPEN PR)
      └── feat/258-server-authored-mirror            (staged, previous session)
           └── feat/257-pr4-tier-query-service       (staged, this session)

main
 └── server#343  feat/ehdb-crossstore-parity        (OPEN PR)
      └── feat/258-server-authored-mirror            (staged, previous session)
           └── feat/257-pr4-tier-query-service       (staged, this session)
```

Opening either PR-4 branch against `main` would show the comparator's 1,944
lines plus the #258 mirror as part of this change. Either #343/#265 and the #258
branches merge first and these rebase, or all three are reviewed as a stack.

### Release type, before merging

`agents/rules/release-versioning.md`: the merge subject is what
semantic-release reads.

* worker: subjects are `feat(ehdb): …` and `fix(ehdb): …` → **minor**.
* server: subject is `feat(ehdb): …` → **minor**.

Both need to reach a cluster before any tier flip, so `chore:`/`docs:` would be
wrong — they produce no release at all, silently. Do **not** hand-edit
`Cargo.toml`, do **not** push a tag, merge with `--merge` (squash is forbidden
in these repos), and read the tag back afterwards.

## Wiki edits — REQUIRED, not yet written

`wiki-maintenance.md` Rule 2a: the deployment-spec page is the env-var source of
truth and must be updated **in the same change set** as the code. This change
does not add a variable but it materially changes what two existing ones do:

* `repos/noetl-worker-wiki/deployment-specification.md`
  * `NOETL_EHDB_TIER_QUERY_SOURCE` — the `service` value now **fails loud**
    (503) when an address is set but unusable, instead of falling back to local.
    The no-address case still downgrades with a WARN; the table in
    `tier_query_source.rs` is the text to mirror.
  * `NOETL_EHDB_TIER_SERVICE_ADDR` — a malformed value now disables the read
    path rather than being ignored.
  * New reply fields `tier_query_source` **and `serve_state`** on
    `GET|POST /ehdb/tiers/{tier}`, and the
    `noetl_worker_ehdb_query_ops_total{operation="tier_query_source.*"}` counter.
    ⚠ **corrected 2026-08-12**: this line previously named
    `noetl_ehdb_query_ops_total`, which is not a series that exists — the family
    is `noetl_worker_ehdb_query_ops_total`. A wiki page written from the old
    line would have documented a metric nobody can scrape.
  * ⚠ **The multi-replica constraint belongs here in plain words**: with more
    than one replica, `local` answers from one pod's fragment. An operator
    reading the current page has no way to know that.
* `repos/noetl-server-wiki/deployment-specification.md`
  * `tier_query_source` now appears in the `/api/ehdb/parity/executions/{id}`
    body.

## Not yet written, and deliberately so

* **ai-meta#257 comment** — PR 4 closed, with the multi-replica measurement.
  §3.4's cutover paragraph should also record that the event-log flip now has a
  prerequisite it did not name: `NOETL_EHDB_TIER_QUERY_SOURCE=service` on every
  replica, or the serve path is per-pod.
* **ai-meta#258 comment** — its gate result stands, but its single-replica
  caveat is now discharged rather than merely stated.
* **Sub-issues** — one per submodule per `issue-tracking.md` Tier 2, linking up
  to #257.
* **Board status** — #257 is already `In progress` on project 3; it stays there
  until the PRs land.
* **ai-meta wiki** — `Home.md` *Last refreshed* + *Active umbrellas*,
  `Sessions-Log.md`, and the matching `Umbrella-*` page, per
  `wiki-maintenance.md` Rule 0a. A change set touching only `Sessions-Log.md` is
  incomplete.
* **ai-meta pointer bumps** — none; no submodule PR has merged.

## Explicitly NOT done, and must stay that way

* No prod change of any kind.
* No tier promoted to `primary`.
* No `NOETL_EHDB_TIER_SERVICE_*` or `NOETL_EHDB_TIER_QUERY_SOURCE` on prod.
* Kind restored to released images with zero EHDB env; worker pool back to 0
  replicas with KEDA `paused-replicas=0`.

## Ready-to-run commands (do not run without a go)

```bash
cd repos/worker
git push -u origin feat/257-pr4-tier-query-service
# base MUST be feat/258-server-authored-mirror, not main
gh pr create --repo noetl/worker --base feat/258-server-authored-mirror \
  --title "feat(ehdb): tier reads resolve through the writer, observably or not at all"

cd ../server
git push -u origin feat/257-pr4-tier-query-service
gh pr create --repo noetl/server --base feat/258-server-authored-mirror \
  --title "feat(ehdb): the cross-store verdict names the store it compared"
```

Both PR bodies cite `Refs noetl/ai-meta#257` and link
`playbooks/261-tier-query-service/RESULTS.md`.
