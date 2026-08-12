# Merge order + push script — the EHDB event-log go-live stack

Assembled 2026-08-12. **Nothing here has been executed.** Every git command was
dry-run-verified where a dry run exists; the rebases were performed in scratch
worktrees and discarded.

---

## 1. Topology, as it actually is

Verified against the repos, not against the earlier staging documents.

```
noetl/worker                                    noetl/server
origin/main  dfcf9d9  (v5.115.3)                origin/main  4f15b03
 │                                               │
 ├─ feat/ehdb-authoritative-event-id  29d7e68     ├─ feat/ehdb-crossstore-parity  37aad5e
 │    worker#265  OPEN, MERGEABLE                 │    server#343  OPEN, MERGEABLE
 │    +301 / -12, 2 files                         │    +1944, 5 files   ← the comparator
 │  │                                             │  │
 │  └─ feat/258-server-authored-mirror  11e7145   │  └─ feat/258-server-authored-mirror  b97e3bf
 │       staged   +375 / -2, 4 files              │       staged   +432 / -2, 6 files
 │     │                                          │     │
 │     └─ feat/257-pr4-tier-query-service 7fd7e42 │     └─ feat/257-pr4-tier-query-service 2206728
 │          staged   +414 / -86, 5 files          │          staged   +83 / -12, 1 file
 │        │
 │        └─ feat/257-serve-readiness  8d46b33    ← THE P0 FIX
 │             staged   2 commits, +1598 / -31
 │             ( a87dd14 = cherry-pick of #260 ) + ( 8d46b33 = the fix, +803 / -6 )
 │
 └─ feat/260-tier-service-metrics  dcd0266        ← parallel lineage, off main
      staged   +795 / -25, 4 files
```

Ancestry confirmed with `git merge-base --is-ancestor` for every edge above.
Both base PRs are `OPEN` and `MERGEABLE` against `main`.

### The two flagged discrepancies, resolved

**(a) #260 is a parallel lineage — and it must merge FIRST.**
`feat/260-tier-service-metrics` branches off `origin/main` @ `dfcf9d9`, while
the PR-4 stack branches off the #258 mirror. No build before this work contained
both. `feat/257-serve-readiness` is the composition, and it carries `a87dd14`, a
**cherry-pick** of `dcd0266`.

The earlier plan predicted that cherry-pick would "drop out as already-applied"
once #260 is in `main`. **It does — but not for the stated reason, and the
distinction matters.** Their patch-ids differ:

```
a87dd14  72eeb130…      dcd0266  12503cc1…
```

so `git cherry` / `git log --cherry-pick` would still list `a87dd14` as unique
(the cherry-pick landed on a different base, so its context lines differ).
What actually removes it is `git rebase`'s **empty-commit elimination**: applied
on top of a history that already contains the change, it produces no diff and is
dropped. Verified empirically, not assumed:

```
L3: rebase serve-readiness onto rebased pr4  →  CLEAN, 1 commit
    2544054 fix(ehdb): the serve decision runs on the configuration…
    diff vs base: 4 files changed, 803 insertions(+), 6 deletions(-)
```

**Consequence for review size.** With #260 merged first, the serve-readiness PR
is **803 lines** — the P0 fix alone. Without it, the same PR shows **1,598
lines** with #260's instrumentation folded in. That is the whole reason to
order it this way.

**(b) The server PR-4 base — settled, ref-only, no commit lost.**
An earlier document described a server branch `feat/257-pr4-tier-query-service`
@ `2206728` that did not exist; `2206728` was the tip of
`feat/258-server-authored-mirror`. The branch now exists at `2206728` and
`feat/258-server-authored-mirror` sits back at `b97e3bf`. Both commits are
reachable, and the server gate image `pr4real` matches what is on the branch.
**Verified as of this pass — no further action.**

### Why nothing may be opened against `main`

| PR, if opened against `main` | reviewer sees |
| :-- | --: |
| server `feat/258-server-authored-mirror` | +2,376 (the 1,944-line comparator folded in) |
| server `feat/257-pr4-tier-query-service` | +2,459 |
| worker `feat/257-serve-readiness` | ~+2,688 |

Against the correct base, each is 83–1,598 lines and reads as one idea.

---

## 2. Rebase verification

Performed in scratch worktrees against a **simulated merged `main`** (built with
`git merge --no-ff`, matching `gh pr merge --merge`), then discarded. Real
branches were not moved — re-confirmed after cleanup.

### worker — sim main = `origin/main` + #265 + #260

| step | result |
| :-- | :-- |
| merge #265 into `origin/main` | **clean** |
| merge #260 into that | **clean** → sim main `4f650f2` |
| rebase `feat/258-server-authored-mirror --onto sim-main origin/feat/ehdb-authoritative-event-id` | **CLEAN** — 1 commit (`148a4c9`); the #265 commit correctly drops |
| rebase `feat/257-pr4-tier-query-service --onto <above> feat/258-server-authored-mirror` | **CLEAN** — 2 commits (`64fc9ee`, `96306a2`) |
| rebase `feat/257-serve-readiness --onto <above> feat/257-pr4-tier-query-service` | **CLEAN** — **1 commit** (`2544054`); `a87dd14` dropped as empty |

### server — sim main = `origin/main` + #343

| step | result |
| :-- | :-- |
| merge #343 into `origin/main` | **clean** → sim main `c070ecc` |
| rebase `feat/258-server-authored-mirror --onto sim-main origin/feat/ehdb-crossstore-parity` | **CLEAN** — 1 commit (`6230d70`), +432 / -2 |
| rebase `feat/257-pr4-tier-query-service --onto <above> feat/258-server-authored-mirror` | **CLEAN** — 1 commit (`58d63b4`), +83 / -12 |

**Zero conflicts anywhere.** No branch needed moving; every staged branch
already sits on its stated base as a strict descendant, so the "rebase onto its
stated base today" case is a no-op fast-forward.

---

## 3. The merge order

Nine steps. Each layer is an isolated diff.

| # | repo | PR | head | **base** | diff | release |
| :-- | :-- | :-- | :-- | :-- | --: | :-- |
| 1 | worker | **#265** (open) | `feat/ehdb-authoritative-event-id` | `main` | +301 | minor |
| 2 | server | **#343** (open) | `feat/ehdb-crossstore-parity` | `main` | +1944 | minor |
| 3 | worker | **new** | `feat/260-tier-service-metrics` | `main` | +795 | **minor → v5.116.0** |
| 4 | server | **new** | `feat/258-server-authored-mirror` | `main` *(after #343)* | +432 | minor |
| 5 | worker | **new** | `feat/258-server-authored-mirror` | `main` *(after #265)* | +375 | minor |
| 6 | server | **new** | `feat/257-pr4-tier-query-service` | `feat/258-server-authored-mirror` | +83 | minor |
| 7 | worker | **new** | `feat/257-pr4-tier-query-service` | `feat/258-server-authored-mirror` | +414 | minor |
| 8 | worker | **new** | `feat/257-serve-readiness` | `feat/257-pr4-tier-query-service` | **+803** | **patch** (`fix:`) |
| 9 | worker | **#263** (open) | `fix/259-primary-flip-signal` | `main` | — | patch — P8's other half |

Steps 1–2 are independent of each other. Step 3 is independent of everything and
**must precede step 8** or the P0 diff doubles. Steps 4–8 are strictly ordered.
Step 9 can land any time.

**Two ways to sequence 4–8**, and they are not equivalent:

* **Stacked review (recommended).** Push all branches now, open every PR against
  its real base, review each as an isolated diff. As each base merges, GitHub
  retargets the child to `main` automatically; rebase only if it reports a
  conflict — none is expected, per §2.
* **Merge-then-rebase.** Merge #265/#343/#260, then rebase each staged branch
  and open it against `main` one at a time. Same end state, more round trips,
  and the intermediate states are never reviewed together.

### Release discipline — the trap that costs a build cycle

`agents/rules/release-versioning.md`: **semantic-release reads the merge
subject.** `feat:` ⇒ minor, `fix:` ⇒ patch, and *anything else produces no
release at all, silently* — a merged, correct, undeployable change.

* Merge with `--merge`. **Squash is forbidden in these repos.**
* **Never** hand-edit `Cargo.toml`; **never** hand-push a tag.
* **Read the tag back** after each merge. Everything downstream — the image tag,
  the `crane` GHCR→AR copy, the ai-meta pointer bump — takes that value as an
  input. Do not decide the version in advance and work backwards to it.

```bash
gh run watch --repo noetl/<repo>
git fetch origin --tags && git tag --sort=-v:refname | head -1   # did it move?
```

---

## 4. ⚠ Blockers on a clean one-pass push

Four things are **not** ready. Three are quick; one is real work.

### B1 — the wiki trail is incomplete (Rule 2a)

`wiki-maintenance.md` Rule 2a: the deployment-spec page is the env-var source of
truth and must move **in the same change set** as the code. Current state:

| item | state |
| :-- | :-- |
| `noetl-worker-wiki` `MIRROR_SOURCE` row (#258) | committed `6bff4d9`, **unpushed** |
| `noetl-server-wiki` `MIRROR_SOURCE` row (#258) | committed `0f11841`, **unpushed** |
| `noetl-worker-wiki` tier-service metrics (#260) | **uncommitted**, 49 lines in the working tree |
| `NOETL_EHDB_TIER_QUERY_SOURCE` | **0 hits — undocumented.** It is precondition **P3** |
| `serve_state` reply field | **0 hits — undocumented** |
| `tier_query_source` reply field | **0 hits — undocumented** |

Steps 6–8 cannot ship compliantly until the last three are written. Content is
specified in the four `PENDING-PUSH.md` files; the P0 note in particular must
**replace**, not extend, the earlier text — the previous draft said `primary` is
inert on `MIRROR_SOURCE=server` + `TIER_QUERY_SOURCE=service`, which `8d46b33`
made false.

### B2 — ops#255 was mis-cited as the monitoring PR

`RUNBOOK.md` P6 cited **ops#255** for "7 rules + the events scrape". That PR is
*"declare the writer's tier-service face (:9110), default OFF"* — the manifest
half of **P4**. Monitoring is **ops#252**. Applying ops#255 and ticking P6 would
leave the flip unalerted. **Corrected in `RUNBOOK.md` in this pass**; the row is
now split across P4 and P6.

### B3 — worker#263 exists as a PR, not just a branch

`RUNBOOK.md` P8 described `fix/259-primary-flip-signal` as "pushed, unmerged".
It is open as **worker#263**. **Corrected in this pass.**

### B4 — sub-issues and board items do not exist yet

`issue-tracking.md` Tier 2 wants one sub-issue per submodule per round, and
`roadmap-boards.md` Rule 1 wants each on board 3. Six PRs ⇒ up to six
sub-issues. §5 step 0 creates them; the PR bodies reference them.

**Not blockers:** the local ai-meta tree is dirty with ~19 modified submodule
gitlinks and many untracked files, but the five unpushed commits touch
`playbooks/**` **only** — no gitlink, no `repos/*`. `git push --dry-run`
reports a clean fast-forward `817a3f5d..e20c160e`. Per the standing constraint,
do not sweep the sibling dirty `repos/*`.

---

## 5. The push script

**Dry-run status:** all six branch pushes verified as clean `[new branch]`
creates; ai-meta `main` verified as a fast-forward. Nothing else has a dry run.

```bash
set -euo pipefail
AM=/Volumes/X10/projects/noetl/ai-meta
```

### Step 0 — sub-issues (do first; the PR bodies cite them)

```bash
# one per submodule per round, per issue-tracking.md Tier 2.
# Each body: "Tracks noetl/ai-meta#<NNN>" + the phases it covers.
gh issue create --repo noetl/worker --label ai-task \
  --title "EHDB tier service records no metrics — Round 01"                    # → ai-meta#260
gh issue create --repo noetl/worker --label ai-task \
  --title "EHDB shadow parity never compares against the authoritative log — Round 01"   # → #258
gh issue create --repo noetl/server --label ai-task \
  --title "EHDB shadow parity never compares against the authoritative log — Round 01"   # → #258
gh issue create --repo noetl/worker --label ai-task \
  --title "EHDB primary serve path — Round 02 (PR 4: tier reads via the writer)"          # → #257
gh issue create --repo noetl/server --label ai-task \
  --title "EHDB primary serve path — Round 02 (PR 4: the verdict names its store)"        # → #257
gh issue create --repo noetl/worker --label ai-task \
  --title "EHDB primary serve path — Round 03 (PR 7: the serve decision's third call site)"  # → #257
```

### Step 1 — wiki first (Rule 2a: same change set, and it gates B1)

```bash
cd "$AM/repos/noetl-worker-wiki"
# WRITE the missing sections first — see B1. Then:
git add deployment-specification.md
git commit -m "docs(deployment-spec): EHDB tier-service metrics, TIER_QUERY_SOURCE, serve_state (ai-meta#257/#260)"
git push origin master          # also carries the unpushed 6bff4d9 (#258 MIRROR_SOURCE row)

cd "$AM/repos/noetl-server-wiki"
# WRITE tier_query_source on /api/ehdb/parity/executions/{id}. Then:
git add deployment-specification.md
git commit -m "docs(deployment-spec): tier_query_source in the parity reply (ai-meta#257)"
git push origin master          # also carries the unpushed 0f11841
```

### Step 2 — push all six branches

```bash
cd "$AM/repos/worker"
git push -u origin feat/260-tier-service-metrics      # dcd0266
git push -u origin feat/258-server-authored-mirror    # 11e7145
git push -u origin feat/257-pr4-tier-query-service    # 7fd7e42
git push -u origin feat/257-serve-readiness           # 8d46b33

cd "$AM/repos/server"
git push -u origin feat/258-server-authored-mirror    # b97e3bf
git push -u origin feat/257-pr4-tier-query-service    # 2206728
```

### Step 3 — open the PRs, each against its real base

⚠ **`--base` is load-bearing on every one of these.** Omitting it defaults to
`main` and folds the comparator's 1,944 lines into the diff.

```bash
cd "$AM/repos/worker"

gh pr create --repo noetl/worker --base main \
  --head feat/260-tier-service-metrics \
  --title "feat(ehdb): the tier service's server half is observable" \
  --body "Closes noetl/worker#<S1>
Refs noetl/ai-meta#260

Gate: 41/0 up, 11/0 off (the discriminating arm — /metrics 291 vs 403 lines),
mutation 38/2 on exactly the two intended assertions.
Evidence: playbooks/260-tier-service-metrics/RESULTS.md"

gh pr create --repo noetl/worker --base feat/ehdb-authoritative-event-id \
  --head feat/258-server-authored-mirror \
  --title "feat(ehdb): accept server-authored appends, and disarm when the server mirrors" \
  --body "Closes noetl/worker#<S2>
Refs noetl/ai-meta#258

Stacked on worker#265. Gate: 13 == 13, match, 21/0; flag-off arm 6 of 12.
Evidence: playbooks/258-full-set-mirror/RESULTS.md"

gh pr create --repo noetl/worker --base feat/258-server-authored-mirror \
  --head feat/257-pr4-tier-query-service \
  --title "feat(ehdb): tier reads resolve through the writer, observably or not at all" \
  --body "Closes noetl/worker#<S4>
Refs noetl/ai-meta#257

Gate at 3 replicas: local 0/13/0, service 13/13/13, 22/0.
Evidence: playbooks/261-tier-query-service/RESULTS.md"

gh pr create --repo noetl/worker --base feat/257-pr4-tier-query-service \
  --head feat/257-serve-readiness \
  --title "fix(ehdb): the serve decision runs on the configuration that makes the tier correct" \
  --body "Closes noetl/worker#<S6>
Refs noetl/ai-meta#257

The P0. Gate: service 45/0, primary 49/0 (served_primary +13), killswitch 23/0,
bypass mutation 47/2 on exactly the two serve assertions, restored 49/0.
Evidence: playbooks/257-serve-readiness/RESULTS.md + RUNBOOK.md + GO-LIVE.md"

cd "$AM/repos/server"

gh pr create --repo noetl/server --base feat/ehdb-crossstore-parity \
  --head feat/258-server-authored-mirror \
  --title "feat(ehdb): mirror the full authoritative event set from the server" \
  --body "Closes noetl/server#<S3>
Refs noetl/ai-meta#258

Stacked on server#343.
Evidence: playbooks/258-full-set-mirror/RESULTS.md"

gh pr create --repo noetl/server --base feat/258-server-authored-mirror \
  --head feat/257-pr4-tier-query-service \
  --title "feat(ehdb): the cross-store verdict names the store it compared" \
  --body "Closes noetl/server#<S5>
Refs noetl/ai-meta#257

Evidence: playbooks/261-tier-query-service/RESULTS.md"
```

### Step 4 — merge, in the §3 order, reading each tag back

```bash
# 1  gh pr merge 265 --repo noetl/worker --merge
# 2  gh pr merge 343 --repo noetl/server --merge
# 3  gh pr merge <260pr> --repo noetl/worker --merge     ← MUST precede step 8
# 4  gh pr merge <srv258> --repo noetl/server --merge
# 5  gh pr merge <wk258>  --repo noetl/worker --merge
# 6  gh pr merge <srvpr4> --repo noetl/server --merge
# 7  gh pr merge <wkpr4>  --repo noetl/worker --merge
# 8  gh pr merge <wkserve> --repo noetl/worker --merge
# 9  gh pr merge 263 --repo noetl/worker --merge

# after EACH merge — the tag is an output, not an input:
gh run watch --repo noetl/<repo>
git fetch origin --tags && git tag --sort=-v:refname | head -1
```

### Step 5 — board (roadmap-boards.md Rules 1–2)

```bash
PROJECT_ID=PVT_kwDOAOaXws4BZkHw
STATUS_FIELD_ID=PVTSSF_lADOAOaXws4BZkHwzhUh54g
OPT_IN_PROGRESS=47fc9ee4

for N in 257 258 260; do
  gh project item-add 3 --owner noetl --url https://github.com/noetl/ai-meta/issues/$N
done
# #260 is Todo → flip to In progress when its PR opens; #257/#258 already In progress.
ITEM_ID=$(gh project item-list 3 --owner noetl --format json \
  | jq -r '.items[] | select(.content.number == 260) | .id')
gh project item-edit --project-id "$PROJECT_ID" --id "$ITEM_ID" \
  --field-id "$STATUS_FIELD_ID" --single-select-option-id "$OPT_IN_PROGRESS"
```

### Step 6 — ai-meta wiki (Rule 0a — four pages, not one)

`Sessions-Log.md` alone is an incomplete change set.

```bash
cd "$AM/repos/ai-meta-wiki"
#  Home.md          — Last refreshed → 2026-08-12; #257/#258/#260 Active-umbrella
#                     rows; Ecosystem-map worker/server version cells after step 4
#  Sessions-Log.md   — prepend the 2026-08-12 entry
#  Releases.md       — one row per tag that actually moved in step 4
#  Umbrella-*.md     — Recent activity + Next concrete steps for the EHDB umbrella
git add -A && git commit -m "wiki: EHDB event-log go-live stack (ai-meta#257/#258/#260)"
git push origin master
```

### Step 7 — ai-meta itself

```bash
cd "$AM"
git push origin main      # dry-run verified: 817a3f5d..e20c160e, playbooks/** only
```

⚠ **Do not `git add repos/*`.** ~19 sibling gitlinks are dirty from unrelated
work. Pointer bumps come later, gitlink-only via a temp index off HEAD by object
SHA, one repo at a time — and only after a submodule PR has merged. None has.

### Step 8 — issue comments (after the merges, not before)

```bash
gh issue comment 257 --repo noetl/ai-meta --body "PR 7 complete; P0 CLOSED by worker <sha>. …"
gh issue comment 258 --repo noetl/ai-meta --body "Full-set mirror landed; single-replica caveat discharged by PR 4. …"
gh issue comment 260 --repo noetl/ai-meta --body "Landed via noetl/worker#<n> — 41/0 up, 11/0 off, 38/2 mutation. …"
```

#257 §3.4 needs a **correction note, not a silent edit**: the flip's stated
blocker (an incomplete tier) is addressed, and it has a prerequisite the section
never named — `NOETL_EHDB_TIER_QUERY_SOURCE=service` on every replica.

**Do not close #257.** `Closes` ignores trailing qualifiers, so
`Closes noetl/ai-meta#257 Round 03` would close the whole umbrella while P5–P9
are open. Use `Refs`.

---

## 6. What this push does NOT do

* No prod change of any kind. No tier promoted to `primary` outside kind.
* No `NOETL_EHDB_TIER_*`, `NOETL_EHDB_EVENTLOG_MIRROR_SOURCE`, or
  `NOETL_EHDB_EVENTLOG=primary` on prod.
* No ai-meta pointer bumps — no submodule PR has merged.
* ops#252 and ops#255 stay open and unapplied; both are the user's call.
* #257 stays open. See `GO-LIVE.md` §3 for what is still between here and a flip.
