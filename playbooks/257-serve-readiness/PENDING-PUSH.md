# Staged for GitHub — nothing pushed

Sessions 2026-08-12 (capstone, then the P0 fix). The instruction was explicit
both times: build and prove in kind, **do not push, open PRs, merge, or comment
on issues**. Nothing below has left this machine.

**GitHub was reachable throughout** — `git fetch`, `git ls-remote` and `gh` all
work. Writes are being withheld by instruction, not by availability.

## 1. Branches — local only

| repo | branch | tip | based on | contains |
| :-- | :-- | :-- | :-- | :-- |
| `noetl/worker` | **`feat/257-serve-readiness`** | **`8d46b33`** | `feat/257-pr4-tier-query-service` @ `7fd7e42` | cherry-pick of `dcd0266` (#260) + **the P0 fix** (`8d46b33`) |
| `noetl/worker` | `feat/257-pr4-tier-query-service` | `7fd7e42` | `feat/258-server-authored-mirror` @ `11e7145` | PR-4 completion + the corrected startup line |
| `noetl/worker` | `feat/260-tier-service-metrics` | `dcd0266` | `origin/main` @ `dfcf9d9` (v5.115.3) | tier-service observability |
| `noetl/worker` | `feat/258-server-authored-mirror` | `11e7145` | `feat/ehdb-authoritative-event-id` (worker#265, OPEN PR) | accept server-authored appends, disarm the worker mirror |
| `noetl/server` | **`feat/257-pr4-tier-query-service`** (new ref, this session) | `2206728` | `feat/258-server-authored-mirror` @ `b97e3bf` | the verdict names the store it compared (PR 4's server half) |
| `noetl/server` | `feat/258-server-authored-mirror` | **`b97e3bf`** (moved back) | `origin/feat/ehdb-crossstore-parity` @ `37aad5e` (server#343, OPEN PR) | the full-set mirror |

### The two topology facts, settled

**(b) — SETTLED.** The server's PR-4 commit now sits on a branch of its own.
`playbooks/261-tier-query-service/PENDING-PUSH.md` described a server branch
`feat/257-pr4-tier-query-service` @ `2206728` that did not exist; `2206728` was
the tip of `feat/258-server-authored-mirror`, so the two staged documents
disagreed about the stack. Fixed **ref-only**: the branch was created at
`2206728` and `feat/258-server-authored-mirror` moved back to `b97e3bf`. No
commit was lost — both are reachable — and the server worktree still holds
`2206728`, so the server gate image (`pr4real`) matches what is on the branch.

**(a) — STILL A DECISION, and it is a merge-order one.**
`feat/260-tier-service-metrics` is a **separate lineage**: it branches off
v5.115.3 directly, while `feat/257-pr4-tier-query-service` branches off the #258
mirror. **No build before this work contained both.**
`feat/257-serve-readiness` is the composition, and it exists only locally.

Recommended order, because it is the one that leaves a gated artefact:

1. merge worker#265 (`feat/ehdb-authoritative-event-id`) and server#343
   (`feat/ehdb-crossstore-parity`) — both already open;
2. merge `feat/260-tier-service-metrics` into `main` **first** — it is
   independent, small, and off the release tip;
3. rebase the PR-4 stack onto the new `main`; the composed branch's cherry-pick
   of `dcd0266` then drops out as already-applied, leaving `8d46b33` (the P0 fix)
   as the only content of `feat/257-serve-readiness`;
4. merge the stack bottom-up.

Merging #260 and the stack independently into `main` also *works*, but then the
composed artefact that was actually gated is `main` — and nothing has gated
`main`. If that path is taken, re-run `gate.sh service` + `gate.sh primary`
against a build of `main` before any flip.

### The stack, as it stands

```
worker/main
 └── worker#265  feat/ehdb-authoritative-event-id        (OPEN PR)
      └── feat/258-server-authored-mirror                (staged)
           └── feat/257-pr4-tier-query-service           (staged)
                └── feat/257-serve-readiness   8d46b33   (staged — THE P0 FIX)
worker/main
 └── feat/260-tier-service-metrics                       (staged, parallel lineage)

server/main
 └── server#343  feat/ehdb-crossstore-parity  37aad5e    (OPEN PR)
      └── feat/258-server-authored-mirror     b97e3bf    (staged)
           └── feat/257-pr4-tier-query-service 2206728   (staged)
```

None of the PR-4 or serve-readiness branches may be opened against `main` — that
would show the comparator's 1,944 lines and the #258 mirror as part of the change.

### Release type, before merging

`agents/rules/release-versioning.md`: the **merge subject** is what
semantic-release reads. `8d46b33`'s subject is `fix(ehdb): …` ⇒ **patch**; the
other staged worker subjects are `feat(ehdb): …` / `fix(ehdb): …` ⇒ **minor**;
the server subjects are `feat(ehdb): …` ⇒ **minor**. All of them must reach a
cluster before any flip, so `chore:` / `docs:` would be wrong — they produce no
release at all, silently. Do **not** hand-edit `Cargo.toml`, do **not** push a
tag, merge with `--merge` (squash is forbidden here), and read the tag back
afterwards.

## 2. ai-meta commits — staged, not pushed

* `playbooks/257-serve-readiness/`
  * `RESULTS.md` — run 2 (the P0 fix, measured) prepended; run 1 kept verbatim
    below it as the evidence the defect existed.
  * `RUNBOOK.md` — **P0 rewritten from blocker to satisfied**, with the
    three-surface pre-flip check; P8 split into the handled half and the `#259`
    half; §3 watch table rows 1/1b/2/3 corrected; §5 now carries both runs;
    §6 gains the reachability-vs-existence trap.
  * `gate.sh` — four new assertions: the serve-series pin, `serve_state` at the
    endpoint per replica, the shadow negative control (6c), and the flip measured
    as a **delta** rather than an absolute.
  * `deploy.sh` — new `poolimg <image>` verb: swap only the pool's image, so the
    mutation moves one variable.
  * `mutation-p0.patch` — **new**. Reinstates the bypass; targets arm `primary`.
  * `README.md` — the composed branch now names `8d46b33`.
  * `PENDING-PUSH.md` — this file.
* `playbooks/261-tier-query-service/PENDING-PUSH.md` — the wrong metric name
  corrected in place (`noetl_worker_ehdb_query_ops_total`), with the correction
  marked and `serve_state` added to the reply-field list.

## 3. Wiki edits — ✅ **WRITTEN AND COMMITTED 2026-08-12** (not pushed)

> **Status update.** Everything specified in this section is now written and
> committed locally: `noetl-worker-wiki` **`2acfd0f`** and `noetl-server-wiki`
> **`9673f45`**, each sitting on top of the earlier `#258` commit (`6bff4d9` /
> `0f11841`). Both push dry-runs are clean fast-forwards. The `NOETL_EHDB_EVENTLOG`
> P0 note was **replaced** as required below, not appended. See
> `MERGE-ORDER.md` §4 B1 for the verification counts.
>
> Two things were found while writing it and fixed in the same commit: the
> serve-path description named no call site (so it read as "any `primary` flip
> serves"), and the three-outcome flip-time signal table documented
> **worker#263, which is open and unmerged** — a binary from `main` records only
> `primary_not_wired`.

The original specification, kept because it is what the commit was written
against:

`wiki-maintenance.md` Rule 2a — the deployment-spec page is the env-var source of
truth and must move in the same change set as the code.

* `repos/noetl-worker-wiki/deployment-specification.md`
  * `NOETL_EHDB_EVENTLOG` — ⚠ **the P0 note must be REPLACED, not added.** The
    previous staging document asked for a line saying `primary` is inert on
    `MIRROR_SOURCE=server` + `TIER_QUERY_SOURCE=service`. As of `8d46b33` that is
    **false**. What the page needs instead: `primary` serves through the
    writer-fronted tier service on that configuration, the three conditions it
    requires, and that it demotes to the incumbent — never errors the caller —
    when any of them fails.
  * `NOETL_EHDB_TIER_QUERY_SOURCE` — `service` **fails loud** (503) when an
    address is set but unusable; the no-address case downgrades with a WARN.
    ⚠ **the multi-replica constraint, in plain words**: at N>1 replicas `local`
    answers from one pod's fragment. An operator reading the page today cannot
    know that.
  * `NOETL_EHDB_TIER_SERVICE_BIND` / `_DIR` — the tier-service metric surface
    appears **only when the listener exists**; absence is the correct reading of
    "no listener", and the store dir must be on a PVC or it dies with the pod.
  * The metric families: the tier-service ones, the
    `noetl_worker_ehdb_query_ops_total{operation="tier_query_source.*"}` counter,
    and **the now-pinned `noetl_ehdb_eventlog_ops_total{operation="mirror"}`
    outcome set** — seven values, present at 0 whenever EHDB is enabled and the
    tier is not `off`, on `shadow` as well as `primary`.
  * **New reply field `serve_state`** on `GET|POST /ehdb/tiers/eventlog`, with
    its five values (`served_primary`, `not_primary`, `no_durable_service`,
    `parity_diverged`, `unknown`) and the note that `unknown` means this pod has
    decided nothing — not `not_primary`.
* `repos/noetl-server-wiki/deployment-specification.md`
  * `tier_query_source` on `/api/ehdb/parity/executions/{id}`.

## 4. Issues / RFC — not written, deliberately

* **ai-meta#257** — PR 7 complete; **P0 is closed**, so §3.4's prerequisite list
  needs the opposite correction from the one the previous document asked for: it
  must name `TIER_QUERY_SOURCE=service` as a prerequisite AND state that
  `primary` now has a reachable serve path on it as of worker `8d46b33`. The flip
  remains blocked on P5/P6/P7/P9, which are prod-side or human decisions.
* **A new sub-issue (worker)** for the P0 fix itself, per `issue-tracking.md`
  Tier 2 — one per submodule per round, linking up to #257 and closed by the PR.
* **ai-meta#259** — `fix/259-primary-flip-signal` is pushed but unmerged. Its
  premise is now narrower and worth recording: the stale warning is *unreachable*
  on the serve-ready configuration (the same disarm routes around it), so landing
  it was never sufficient for P0 — and it is still needed for
  `MIRROR_SOURCE=worker`.
* **ai-meta#260 / #258** — their gate results stand; both are composed here.
* **Board** — #257 stays `In progress` on project 3.
* **ai-meta wiki** — `Home.md` *Last refreshed* + *Active umbrellas*,
  `Sessions-Log.md`, `Releases.md` if a tag moves, and the matching `Umbrella-*`
  page, per `wiki-maintenance.md` Rule 0a. A change set touching only
  `Sessions-Log.md` is incomplete.
* **ai-meta pointer bumps** — none; no submodule PR has merged.

## 5. Explicitly NOT done, and must stay that way

* No prod change of any kind.
* No tier promoted to `primary` outside kind.
* No `NOETL_EHDB_TIER_SERVICE_*`, `NOETL_EHDB_TIER_QUERY_SOURCE`,
  `NOETL_EHDB_EVENTLOG_MIRROR_SOURCE` or `NOETL_EHDB_EVENTLOG=primary` on prod.
* Kind restored to released images with zero EHDB env on the pool and the writer;
  worker pool back to 0 replicas with KEDA `paused-replicas=0`. Verified, not
  assumed — see `RESULTS.md` *State left behind*.

## 6. Ready-to-run commands (do not run without a go)

```bash
cd repos/worker
git push -u origin feat/257-serve-readiness
# base MUST be feat/257-pr4-tier-query-service, not main
gh pr create --repo noetl/worker --base feat/257-pr4-tier-query-service \
  --title "fix(ehdb): the serve decision runs on the configuration that makes the tier correct"

cd ../server
git push -u origin feat/258-server-authored-mirror          # b97e3bf
git push -u origin feat/257-pr4-tier-query-service          # 2206728
gh pr create --repo noetl/server --base feat/258-server-authored-mirror \
  --title "feat(ehdb): the cross-store verdict names the store it compared"
```

PR bodies cite `Refs noetl/ai-meta#257` and link
`playbooks/257-serve-readiness/RESULTS.md` and `RUNBOOK.md`.
