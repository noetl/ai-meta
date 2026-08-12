# Staged for GitHub — nothing pushed

Session 2026-08-11 (late). The session was told GitHub was down and to defer
every push / PR / issue comment.

**⚠ GitHub was reachable throughout this session.** `gh issue view 260`,
`git fetch`, and `git ls-remote` all succeeded, at the start and again at the
end. The previous session's `PENDING-PUSH.md` records the same thing for reads;
this session confirms **writes would also have worked** — `fix/259-primary-flip-signal`
is already on `origin` at `a757f55`, pushed before this session began.

Writes were still withheld, as instructed. Nothing below has left this machine.
It needs one "go" to ship.

## Branch (local only)

| repo | branch | based on | contains |
| :-- | :-- | :-- | :-- |
| `noetl/worker` | `feat/260-tier-service-metrics` | `origin/main` @ `dfcf9d9` (v5.115.3) | `dcd0266` — the tier-service instrumentation |

Based on **`main`, not on an open PR** — unlike the #258 work, which stacks on
`server#343` / `worker#265`. #260 touches only `src/ehdb/{metrics,tier_service,
tier_store}.rs` + `src/event_bus.rs`, none of which those PRs move, so it can be
reviewed and merged independently and in any order.

### The release-type decision, before merging

`agents/rules/release-versioning.md`: the merge subject is what semantic-release
reads. The commit subject is `feat(ehdb): …`, so this cuts a **minor**
(5.115.3 → 5.116.0). That is intended — this needs to reach a cluster before any
tier flip, and `chore:`/`docs:` would silently produce no release at all.

Do **not** hand-edit `Cargo.toml` and do **not** push a tag. Merge with
`--merge` (these repos forbid squash), then read the tag back:

```bash
gh pr merge <n> --repo noetl/worker --merge
gh run watch --repo noetl/worker
git fetch origin --tags && git tag --sort=-v:refname | head -1
```

## Wiki edit (local only, in the submodule)

* `repos/noetl-worker-wiki/deployment-specification.md` — a new **EHDB tier
  service — the server half** bullet under `## Observability`: the five metrics,
  the closed outcome set, the `degraded ≠ !ok` alerting rule, and the pin's
  exact condition. Required by `wiki-maintenance.md` Rule 2 in the same change
  set. Uncommitted in the submodule.

No env var was added or changed, so Rule 2a's env-var table needs no edit.

## Not yet written, and deliberately so

* **ai-meta#260 comment** — the closure: metric design, the 41/41 `up` arm, the
  11/11 `off` arm, and the mutation arm failing on exactly the two intended
  assertions while `store_appends_total` still passed.
* **Sub-issue** — one on `noetl/worker` per `issue-tracking.md` Tier 2, titled
  `EHDB tier service records no metrics — Round 01`, linking up to
  `noetl/ai-meta#260`, closed by the PR body's `Closes noetl/worker#NN`.
* **Board status** — #260 is `Todo` on project 3; it moves to `In progress` when
  the PR opens (`roadmap-boards.md` Rule 2).
* **ai-meta wiki** — `Home.md` *Last refreshed* + *Active umbrellas*,
  `Sessions-Log.md` entry, and the matching `Umbrella-*` page, per
  `wiki-maintenance.md` Rule 0a. A change set touching only `Sessions-Log.md`
  is incomplete.
* **ai-meta pointer bumps** — none yet; the worker PR has not merged.
* **`Releases.md`** — a row once the merge cuts v5.116.0.

## Explicitly NOT done, and must stay that way

* No prod change of any kind.
* No tier promoted to `primary`.
* No `NOETL_EHDB_TIER_SERVICE_*` set on prod.
* [ops#255](https://github.com/noetl/ops/pull/255) not applied. #260's own note
  stands: it needs **no** amendment, because the new families render on
  `:9090`, which the writer's Service already publishes.
* Kind restored to `ghcr.io/noetl/worker:5.115.3-arm64` with zero tier-service
  env.

## Ready-to-run commands (do not run without a go)

```bash
cd repos/worker
git push -u origin feat/260-tier-service-metrics
gh pr create --repo noetl/worker \
  --title "feat(ehdb): the tier service's server half is observable" \
  --body "..."   # Closes noetl/worker#NN, Refs noetl/ai-meta#260

cd ../noetl-worker-wiki
git add deployment-specification.md
git commit -m "docs(deployment-spec): EHDB tier-service metrics (ai-meta#260)"
git push origin master
```
