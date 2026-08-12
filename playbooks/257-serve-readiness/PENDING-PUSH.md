# Staged for GitHub — nothing pushed

Session 2026-08-12 (capstone). The instruction was explicit: build and prove in
kind, **do not push, open PRs, merge, or comment on issues**. Nothing below has
left this machine.

**GitHub was reachable throughout** — `git fetch`, `git ls-remote` and `gh` all
work. Writes are being withheld by instruction, not by availability. (The three
previous PENDING-PUSH files record the same; the "GitHub is down" premise that
shaped the earliest of them was wrong.)

## 1. Branches — local only

| repo | branch | tip | based on | contains |
| :-- | :-- | :-- | :-- | :-- |
| `noetl/worker` | **`feat/257-serve-readiness`** (new, this session) | `a87dd14` | `feat/257-pr4-tier-query-service` @ `7fd7e42` | cherry-pick of `dcd0266` (#260 tier-service metrics) |
| `noetl/worker` | `feat/257-pr4-tier-query-service` | `7fd7e42` | `feat/258-server-authored-mirror` @ `11e7145` | PR-4 completion + the stale startup line |
| `noetl/worker` | `feat/260-tier-service-metrics` | `dcd0266` | `origin/main` @ `dfcf9d9` (v5.115.3) | tier-service observability |
| `noetl/worker` | `feat/258-server-authored-mirror` | `11e7145` | `feat/ehdb-authoritative-event-id` (worker#265, OPEN PR) | accept server-authored appends, disarm the worker mirror |
| `noetl/server` | `feat/258-server-authored-mirror` | `2206728` | `feat/ehdb-crossstore-parity` (server#343, OPEN PR) | comparator, full-set mirror, verdict names its store |

### ⚠ Two topology facts to settle before pushing

**(a) `feat/260-tier-service-metrics` is a SEPARATE LINEAGE, not part of the
stack.** It branches off v5.115.3 directly; `feat/257-pr4-tier-query-service`
branches off the #258 mirror. **No build before this session contained both.**
`feat/257-serve-readiness` is the first, and it exists only locally. Whatever
merge order is chosen, one of these must be true before a flip is attempted:
#260 merges first and the PR-4 stack rebases onto it, or the stack merges first
and #260 rebases onto that. Merging them independently into `main` also works —
but then the composed artefact that was actually gated is `main`, and nothing
has gated `main`.

**(b) The server's PR-4 commit sits on the #258 branch, not on a branch of its
own.** `playbooks/261-tier-query-service/PENDING-PUSH.md` describes a server
branch `feat/257-pr4-tier-query-service` @ `2206728`; that branch does not
exist. `2206728` is the tip of `feat/258-server-authored-mirror`. Either create
the branch pointer and reset #258 back to `b97e3bf`, or review the two server
commits as one PR — but the two staged documents currently disagree about which
it is, and that disagreement should not reach a reviewer.

### The stack, as it stands

```
worker/main
 └── worker#265  feat/ehdb-authoritative-event-id        (OPEN PR)
      └── feat/258-server-authored-mirror                (staged)
           └── feat/257-pr4-tier-query-service           (staged)
                └── feat/257-serve-readiness             (staged, THIS session)
worker/main
 └── feat/260-tier-service-metrics                       (staged, parallel lineage)

server/main
 └── server#343  feat/ehdb-crossstore-parity             (OPEN PR)
      └── feat/258-server-authored-mirror  (+ the PR-4 server commit on the same branch)
```

None of the PR-4 or serve-readiness branches may be opened against `main` —
that would show the comparator's 1,944 lines and the #258 mirror as part of the
change.

### Release type, before merging

`agents/rules/release-versioning.md`: the **merge subject** is what
semantic-release reads. All the staged worker subjects are `feat(ehdb): …` /
`fix(ehdb): …` ⇒ **minor**; the server subject is `feat(ehdb): …` ⇒ **minor**.
Both must reach a cluster before any flip, so `chore:`/`docs:` would be wrong —
they produce no release at all, silently. Do **not** hand-edit `Cargo.toml`, do
**not** push a tag, merge with `--merge` (squash is forbidden here), and read
the tag back afterwards.

## 2. ai-meta commits — staged, not pushed

* `playbooks/257-serve-readiness/` — README, deploy.sh, gate.sh, mutation.patch,
  RESULTS.md, **RUNBOOK.md (RFC PR 7)**, this file.

## 3. Wiki edits — REQUIRED, not yet written

`wiki-maintenance.md` Rule 2a — the deployment-spec page is the env-var source
of truth and must move in the same change set as the code.

* `repos/noetl-worker-wiki/deployment-specification.md`
  * `NOETL_EHDB_TIER_QUERY_SOURCE` — `service` **fails loud** (503) when an
    address is set but unusable; the no-address case downgrades with a WARN.
  * ⚠ **the multi-replica constraint, in plain words**: at N>1 replicas `local`
    answers from one pod's fragment. An operator reading the page today cannot
    know that.
  * `NOETL_EHDB_TIER_SERVICE_BIND` / `_DIR` — the metric surface appears **only
    when the listener exists**; absence is the correct reading of "no listener",
    and the store dir must be on a PVC or it dies with the pod.
  * The tier-service metric families and the `tier_query_source.*` counter.
    ⚠ the counter's real name is `noetl_worker_ehdb_query_ops_total`, **not**
    `noetl_ehdb_query_ops_total` as `playbooks/261-tier-query-service/PENDING-PUSH.md`
    records — fix that line too.
  * ⚠ **`NOETL_EHDB_EVENTLOG=primary` is inert** when
    `NOETL_EHDB_EVENTLOG_MIRROR_SOURCE=server` and
    `NOETL_EHDB_TIER_QUERY_SOURCE=service`. Measured this session. This belongs
    on the page next to the variable, not only in a playbook.
* `repos/noetl-server-wiki/deployment-specification.md`
  * `tier_query_source` on `/api/ehdb/parity/executions/{id}`.

## 4. Issues / RFC — not written, deliberately

* **ai-meta#257** — PR 7 complete; the serve-readiness bundle is green and the
  flip is blocked on P0. §3.4 needs a further correction: the flip's
  prerequisite list must name `TIER_QUERY_SOURCE=service` **and** state that
  `primary` currently has no reachable caller on that configuration.
* **A new sub-issue (worker)** for P0 itself: give `primary` a serve path on the
  server-authored + service-resolved configuration, or state that the event-log
  flip requires `MIRROR_SOURCE=worker` and re-derive the evidence there.
* **ai-meta#259** — `fix/259-primary-flip-signal` is pushed but unmerged; this
  session measured something stronger than a stale warning: **no line at all**
  is emitted at flip time on the composed configuration.
* **ai-meta#260 / #258** — their gate results stand; both are now composed.
* **Sub-issues** per `issue-tracking.md` Tier 2, one per submodule per round.
* **Board** — #257 stays `In progress` on project 3.
* **ai-meta wiki** — `Home.md` *Last refreshed* + *Active umbrellas*,
  `Sessions-Log.md`, `Releases.md` if a tag moves, and the matching
  `Umbrella-*` page, per `wiki-maintenance.md` Rule 0a. A change set touching
  only `Sessions-Log.md` is incomplete.
* **ai-meta pointer bumps** — none; no submodule PR has merged.

## 5. Explicitly NOT done, and must stay that way

* No prod change of any kind.
* No tier promoted to `primary` outside kind.
* No `NOETL_EHDB_TIER_SERVICE_*`, `NOETL_EHDB_TIER_QUERY_SOURCE` or
  `NOETL_EHDB_EVENTLOG=primary` on prod.
* Kind restored to released images with zero EHDB env; worker pool back to 0
  replicas with KEDA `paused-replicas=0`.

## 6. Ready-to-run commands (do not run without a go)

```bash
cd repos/worker
git push -u origin feat/257-serve-readiness
# base MUST be feat/257-pr4-tier-query-service, not main
gh pr create --repo noetl/worker --base feat/257-pr4-tier-query-service \
  --title "feat(ehdb): compose the serve-readiness stack — metrics + tier-query service"
```

PR bodies cite `Refs noetl/ai-meta#257` and link
`playbooks/257-serve-readiness/RESULTS.md` and `RUNBOOK.md`.
