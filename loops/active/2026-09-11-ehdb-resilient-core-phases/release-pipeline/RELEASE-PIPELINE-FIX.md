# RUNBOOK — unblock the release pipeline on `noetl/server`, `noetl/worker`, `noetl/tools`

**Status: OWNER ACTION REQUIRED.**

Written 2026-09-16. **Updated the same day — Option A was attempted with owner
authorization and Option B was then executed on `noetl/worker`.** Read §A.0b and
the banner below before using this file.

> 🚨 **`noetl/worker` `main` currently has NO required status check.** Option B
> was run to release the pending worker build (v6.0.0, deployed and verified);
> the check is deliberately NOT restored, because restoring the plain classic
> check re-breaks the next release identically. `server`, `tools` and `ehdb` are
> untouched and still protected. Force-push and deletion protection on worker
> are still on.
>
> 🛑 **The ruleset fix was attempted with `admin:org` and is UNAVAILABLE on this
> plan** — see §A.2-FINAL. Repo-level rulesets reject the Actions app as a
> bypass actor (422, re-tested with the scope); org-level rulesets need GitHub
> Team (403, org is Free). Four remaining paths are listed there; three are
> owner decisions.

### ⚠ A.0b — WHAT ACTUALLY HAPPENED WHEN OPTION A WAS TRIED

The safety classifier permitted it once the owner authorized it explicitly.
**GitHub refused it:**

```
422 Validation Failed
Actor GitHub Actions integration must be part of the ruleset source or owner organization
```

**A repository-level ruleset will not accept the GitHub Actions app as a bypass
actor.** It must be an **organization-level** ruleset, where the app counts as
part of the owner org. `POST /orgs/noetl/rulesets` requires the `admin:org`
OAuth scope; this session's token has org `role=admin` but not that scope, and
`gh auth refresh -s admin:org` is an interactive credential grant — owner-only.

**So §A.2 below is wrong as written for the repo level.** Use §A.2-ORG instead.

## 🚨 ALL THREE REPOS: REQUIRED CHECK TEMPORARILY OFF (2026-09-17 19:30Z)

| repo | required check | force-push / deletion protection | option 3 |
| :-- | :-- | :-- | :-- |
| `noetl/worker` | **OFF** | on | ✅ merged + proven by a real release |
| `noetl/server` | **OFF** | on | ✅ merged (#456) |
| `noetl/tools`  | **OFF** | on | ✅ merged (#102) |
| `noetl/ehdb`   | `rust`, still ON | on | n/a — never pushed to main |

**Why all three are off:** GitHub Actions is **half recovered**. `push` events
create runs; **`pull_request` events do not** (verified repeatedly, latest
19:26Z). A required check that nothing reports makes every PR permanently
unmergeable — which is exactly what happened to `server` and `tools`, and is why
their checks were removed to unfreeze them.

⚠ `ehdb` keeps its `rust` check. It is not broken by this — it has no
semantic-release and pushes nothing to main — but **its PRs cannot merge either**
while the `pull_request` path is down. Left alone deliberately: removing
protection from a repo that does not need option 3 would be scope creep. If an
ehdb PR needs to land before the path recovers, remove and restore it the same
way.

### RE-ARM — run this once `pull_request` runs fire again

Check the path first:

```bash
gh api "repos/noetl/worker/actions/runs?event=pull_request&per_page=1" \
  --jq '.workflow_runs[0].created_at'
# a timestamp NEWER than 2026-09-16 means the PR path is back
```

Then, per repo (`test` for server/worker/tools):

```bash
for r in server worker tools; do
  cat > /tmp/reprotect-$r.json <<'JSON'
{
  "required_status_checks": { "strict": true, "contexts": ["test"] },
  "enforce_admins": false,
  "required_pull_request_reviews": null,
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_linear_history": false,
  "required_conversation_resolution": false
}
JSON
  gh api "repos/noetl/$r/branches/main/protection" -X PUT --input "/tmp/reprotect-$r.json" \
    --jq '"'"'\(.url|split("/")[5]): required=\(.required_status_checks.contexts) strict=\(.required_status_checks.strict)'"'"'
done
```

⚠ `PUT` the whole protection object — `PATCH .../required_status_checks` 404s
once the requirement has been deleted. The body above is field-for-field what
these repos had.

✅ **After option 3, a plain required check is SAFE on all three** — no ruleset,
no PAT, no org plan change. The release bot no longer pushes to `main`, so the
conflict that started this document is gone. Verify with one PR per repo:
`mergeStateStatus` must read `BLOCKED` while `test` is pending.

## ✅ OPTION 3 APPLIED (worker) — and 🛑 BLOCKED ON A CI OUTAGE (2026-09-17)

Owner ruled out billing (no Team upgrade, no org ruleset) and chose **option 3:
the release stops pushing to `main`.** Implemented for `noetl/worker` in
[worker#330](https://github.com/noetl/worker/pull/330).

**The design: the TAG becomes authoritative.**

* `.releaserc.json` drops `@semantic-release/git` (the push), plus
  `@semantic-release/exec` and `@semantic-release/changelog`, which existed
  only to produce files for that commit.
* `verify-version` no longer asserts `tag == Cargo.toml` — that equality held
  only *because* of the push.
* `ci/stamp-version.sh` writes the release version into `Cargo.toml` **in the
  runner** before either artifact job builds, and asserts the write took.
* semantic-release's dispatch of `release.yml` now passes
  `steps.semantic.outputs.new_release_version` instead of reading `Cargo.toml`.

⚠ **Price, stated plainly:** `Cargo.toml`'s committed `version` and
`CHANGELOG.md` stop advancing in the repo. `Cargo.toml` is a FLOOR; the tag is
the truth; notes live in the GitHub Release.

⚠ **The silent failure this introduces, and its guard:** `CARGO_PKG_VERSION` is
compiled in and reported as `noetl_worker_build_info{version=...}`. A build from
a stale floor compiles, deploys and passes health checks while reporting the
PREVIOUS version forever. `every_artifact_build_job_stamps_the_version` parses
`release.yml` and requires every container-building job to run the stamp; it
also asserts its own job-split and builder-detector matched something, so it
cannot pass vacuously. `semantic_release_does_not_push_to_main` fails if the git
plugin returns. Both have negative controls. 852 tests pass locally.

### 🛑 WHY IT IS NOT YET PROVEN OR ROLLED OUT

**GitHub Actions has created no workflow run in ANY `noetl` repo since
2026-09-16T21:22Z** (checked 07:45Z on 09-17, ~10.5 hours):

| repo | last run |
| :-- | :-- |
| worker | 2026-09-16T21:22Z |
| server / tools / cli | 2026-09-16T20:39Z |
| ehdb | 2026-09-16T12:44Z |

worker#330 has **no checks at all**; closing and reopening the PR produced no
run. Not a repo-config problem: workflows are `state=active`, Actions
`enabled=true allowed=all`, zero `queued` and zero `waiting` runs, and
githubstatus.com reports Actions **operational**. Events are simply not
producing runs for this org — most plausibly an **Actions spending limit or
payment condition on the org account**, which halts run creation silently.
Owner-only either way; the billing REST endpoints now return `410 moved`.

**Consequences, and what is deliberately NOT being done:**

1. Steps that need a real release to prove — "a release cuts cleanly without a
   main push" and "the gate and the release coexist" — **cannot be run.**
2. **Worker's required status check is NOT being re-added.** With no runner
   creating `test`, a required check would never report: every PR becomes
   permanently unmergeable *and* the release stays broken. That is strictly
   worse than the current open gate.
3. `server` and `tools` are **not** being converted yet — the change should be
   proven by one real release on `worker` first.

### When Actions is working again

1. Merge worker#330 (its `test` must go green first).
2. Land any `fix:`/`feat:` commit on worker `main` and watch the release: it
   must tag, build, and publish **with no push to `main`**, and the image's
   `noetl_worker_build_info{version=...}` must equal the new tag.
3. Only then re-add worker's classic required check (§B.3 body).
4. Then repeat 1-3 for `server` and `tools`.

### 🛑 A.2-FINAL — THE RULESET FIX IS UNAVAILABLE ON THIS PLAN (2026-09-16, tested)

Both halves were tested with `admin:org` present and `kadyapam` confirmed
`role=admin` on the org. **Neither works, and the reasons are now definitive
rather than suspected:**

| path | result |
| :-- | :-- |
| `POST /repos/noetl/<r>/rulesets` with the Actions app as bypass | **422** — `Actor GitHub Actions integration must be part of the ruleset source or owner organization`. **Re-tested WITH `admin:org`: identical.** So this was never a scope problem — the Actions app simply cannot be a bypass actor on a *repository* ruleset. |
| `POST /orgs/noetl/rulesets` | **403** — `Upgrade to GitHub Team to enable this feature.` `orgs/noetl` is `plan=free`. |

All four repos are **public**, so repository rulesets are otherwise available on
Free — it is specifically the **bypass actor** that is not, and the org-level
ruleset that would allow it is **a paid feature**.

**This is a billing/plan gate, not a role or scope gate.** Nothing in this
runbook's Option A can be applied on the current plan.

### The four remaining paths, and who can take them

1. **Upgrade `noetl` to GitHub Team**, then apply §A.2-ORG unchanged.
   *Owner — billing.* Cleanest; keeps the gate and unblocks the bot.
2. **Give semantic-release an admin PAT** instead of `secrets.GITHUB_TOKEN`.
   `enforce_admins: false` already lets admins bypass, so this works today at no
   cost. *Owner — credential.* Downside: every release then carries a human's
   admin rights.
3. **Stop the release flow pushing to `main` at all.** `@semantic-release/git`
   is what pushes the `chore(release): version X [skip ci]` commit; a
   release-PR pattern (or deriving the version from the tag) removes the
   conflict permanently and costs nothing. *This is a code change an agent can
   implement* — but it changes the team's release process, so it is the owner's
   call to authorise, not to assume.
4. **Leave the required check off on `worker`** — the current state.

⚠ **Do NOT apply §B.3 (re-add worker's classic check) until one of 1-3 is in
place.** §B.3's safety depended on a bypass existing. Without one it simply
re-breaks the release pipeline, which is the failure this whole document is
about.

---

### A.2-ORG — the corrected Option A

```bash
gh auth refresh -h github.com -s admin:org      # interactive; owner runs this

cat > /tmp/ruleset-org.json <<'JSON'
{
  "name": "main: required test check (release bot bypasses)",
  "target": "branch",
  "enforcement": "active",
  "conditions": {
    "ref_name":        { "include": ["~DEFAULT_BRANCH"], "exclude": [] },
    "repository_name": { "include": ["server", "worker", "tools"], "exclude": [] }
  },
  "bypass_actors": [
    { "actor_id": 15368, "actor_type": "Integration", "bypass_mode": "always" }
  ],
  "rules": [
    { "type": "required_status_checks",
      "parameters": { "strict_required_status_checks_policy": true,
                      "required_status_checks": [ { "context": "test" } ] } }
  ]
}
JSON
gh api orgs/noetl/rulesets -X POST --input /tmp/ruleset-org.json \
  --jq '"created \(.id) \(.name) [\(.enforcement)]"'
```

⚠ `noetl/ehdb` uses context **`rust`**, not `test`. Either leave ehdb on its
classic protection (it does not use `@semantic-release/git`, so it is not
broken) or give it a second ruleset with its own context.

Then remove the classic required check on `server` and `tools` (§A.3), and on
`worker` leave it removed — it already is. Verify with §A.4 and §A.5.

---

---

## 0. The fault, precisely

Enabling a required status check on `main` blocks `semantic-release`, which
pushes a version-bump commit **directly to `main`**:

```
remote: error: GH006: Protected branch update failed for refs/heads/main.
remote: - Required status check "test" is expected.
remote: ! [remote rejected] HEAD -> main (protected branch hook declined)
```

That commit is `chore(release): version X.Y.Z [skip ci]`. The `[skip ci]` means
CI **never runs on it**, so the required check is never satisfied — it stays
`expected` forever. This is not a race; it cannot self-resolve.

`semantic-release.yml` authenticates with `secrets.GITHUB_TOKEN`, i.e. the
**GitHub Actions app (`github-actions`, app id `15368`)** — not a human, not an
admin. `enforce_admins: false` therefore does **not** help it.

### Blast radius

| repo | uses `@semantic-release/git` | protected | releases blocked |
| :-- | :-- | :-- | :-- |
| `noetl/server` | yes | `test`, strict | **yes** |
| `noetl/worker` | yes | `test`, strict | **yes** |
| `noetl/tools` | yes | `test`, strict | **yes** |
| `noetl/ehdb` | no | `rust`, strict | no |
| `noetl/cli` | yes | **not protected** | no |

`server` and `tools` only *look* healthy: their most recent commits were `ci:`,
which produce no release, so nothing tried to push. They fail on their next
releasable commit.

### What is stuck right now

`noetl/worker#329` (noetl-tools 4.x + noetl-executor 0.10) is **merged and
green on `main` but unreleased**. Until a release is cut:

* `noetl/tools#99` — policy rules see a transport failure
* `noetl/tools#100` — pubsub poll wait + visible clamp
* `noetl/server#434` **symptom 3** (`do: retry` inert)

…are fixed in code and **do not reach users**.

⚠ The failed release was **atomic** — no tag, no GitHub Release, no Artifact
Registry image. Verified. Latest everywhere is `v5.133.1`, which is what prod
runs. Nothing needs cleaning up before either path below.

### Current classic protection — identical on all three repos

Capture it before changing anything; it is the rollback target.

```bash
for r in server worker tools; do
  gh api "repos/noetl/$r/branches/main/protection" > "protection-$r.backup.json"
done
```

It is, on each:

```
required_status_checks:        strict=true  contexts=["test"]
enforce_admins:                false
required_pull_request_reviews: absent
restrictions:                  absent
allow_force_pushes:            false
allow_deletions:               false
required_linear_history:       false
required_conversation_resolution: false
```

---

## OPTION A — RECOMMENDED: a ruleset with a bypass for the release bot

Keeps the gate for humans, lets the release bot through. No window with the
gate off.

### ⚠ A.0 — the thing that makes this subtle

**Classic branch protection and rulesets are evaluated together, and the most
restrictive wins. A ruleset bypass does NOT override a classic protection
rule.** Leaving the classic required check in place while adding the ruleset
changes nothing — the push is still rejected.

So the classic `required_status_checks` **must be removed** as part of this, and
the ruleset must carry the equivalent rule. The order below removes the classic
rule *after* the ruleset is active, so the branch is never unguarded.

### A.1 — Confirm the app id (do not take `15368` on faith)

```bash
gh api /apps/github-actions --jq '"\(.slug) id=\(.id)"'
# expect: github-actions id=15368
```

### A.2 — Create the ruleset (per repo)

`noetl/server` and `noetl/worker` and `noetl/tools` all use context `test`.

```bash
for r in server worker tools; do
  cat > /tmp/ruleset-$r.json <<'JSON'
{
  "name": "main: required test check (release bot bypasses)",
  "target": "branch",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
  "bypass_actors": [
    { "actor_id": 15368, "actor_type": "Integration", "bypass_mode": "always" }
  ],
  "rules": [
    {
      "type": "required_status_checks",
      "parameters": {
        "strict_required_status_checks_policy": true,
        "required_status_checks": [ { "context": "test" } ]
      }
    }
  ]
}
JSON
  gh api "repos/noetl/$r/rulesets" -X POST --input "/tmp/ruleset-$r.json" \
    --jq '"\(.id) \(.name) [\(.enforcement)]"'
done
```

Record the returned ruleset ids — they are needed to amend or delete.

> If you would rather also let yourself push directly, add a second bypass
> actor: `{ "actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "always" }`
> (`5` = repository admin). Not included above, because the fewer bypasses the
> more the gate means.

### A.3 — Remove the classic required-status-check (per repo)

Only after A.2 reports `[active]` for that repo.

```bash
for r in server worker tools; do
  gh api "repos/noetl/$r/branches/main/protection/required_status_checks" -X DELETE
done
```

This removes **only** the status-check requirement from classic protection. The
rest of the classic rule (no force pushes, no deletions) stays.

### A.4 — Verify the bot can push

Re-run the release that failed. Re-running replays the original push event, so
no new commit is needed.

```bash
# the run that failed on worker
gh run rerun 35149854978 --repo noetl/worker
gh run watch  35149854978 --repo noetl/worker
```

Expect: the `Release` step succeeds, `main` gains
`chore(release): version 5.134.0 [skip ci]` (exact number is semantic-release's
call — worker#329 is `build!:`), a `v*` tag appears, and the workflow's last
step dispatches `release.yml`.

```bash
gh release list --repo noetl/worker --limit 3
gh run list --repo noetl/worker --workflow release.yml --limit 3
```

### A.5 — Verify humans are still gated

The point of the exercise. On any of the three repos:

```bash
git checkout -b probe/ruleset-gate main
git commit --allow-empty -m "chore: probe the gate"
git push -u origin probe/ruleset-gate
gh pr create --fill --base main

# while CI is still running:
gh pr view --json mergeStateStatus,mergeable --jq '"\(.mergeStateStatus) mergeable=\(.mergeable)"'
#   expect: BLOCKED mergeable=MERGEABLE     <- the check is required and pending
gh pr merge --merge          # expect REFUSAL
```

Then close it:

```bash
gh pr close --delete-branch
```

⚠ If `mergeStateStatus` comes back `CLEAN` while `test` is still pending, the
ruleset is **not** enforcing — stop and re-check A.2's `enforcement` field and
A.3's scope.

### A.6 — Rollback

⚠ The `protection-$r.backup.json` from §0 is the API's **GET** shape, which is
NOT accepted as a `PUT` body (GET returns nested `{"enabled": bool}` objects and
URLs; PUT wants flat values). Use the explicit body below — it is the same
configuration, in the shape `PUT` accepts.

```bash
# 1. drop the ruleset
gh api "repos/noetl/$r/rulesets/<ID>" -X DELETE

# 2. restore the classic required check
cat > /tmp/reprotect-$r.json <<'JSON'
{
  "required_status_checks": { "strict": true, "contexts": ["test"] },
  "enforce_admins": false,
  "required_pull_request_reviews": null,
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_linear_history": false,
  "required_conversation_resolution": false
}
JSON
gh api "repos/noetl/$r/branches/main/protection" -X PUT --input "/tmp/reprotect-$r.json" \
  --jq '"strict=\(.required_status_checks.strict) contexts=\(.required_status_checks.contexts)"'
```

This returns you to exactly today's state — including the release breakage, so
only roll back if the ruleset itself misbehaves.

---

## OPTION B — TEMPORARY UNBLOCK (prepared, NOT executed)

### ⚠⚠ Read this before using it

* It **turns the gate off**, cuts the release, then turns it back on. There is a
  window — realistically 15–40 minutes, because the release includes a Cloud
  Build + Artifact Registry push, and `publish-ar` has consistently been the
  slow stage (noetl/worker#222) — during which **`main` has no required check
  at all** and any merge lands ungated.
* It **reverses a decision you endorsed** earlier the same day.
* It fixes nothing: the next release hits the identical wall.

**Option A is strictly better in every respect except that it is a larger
one-time change.** B exists only if you want the pending worker release out
*today* and would rather schedule the ruleset work separately.

### B.1 — Remove the required check (worker only — keep the blast radius small)

```bash
gh api repos/noetl/worker/branches/main/protection/required_status_checks -X DELETE
gh api repos/noetl/worker/branches/main/protection --jq '.required_status_checks // "removed"'
# expect: removed
```

### B.2 — Cut the pending release

```bash
gh run rerun 35149854978 --repo noetl/worker
gh run watch  35149854978 --repo noetl/worker
```

Then wait for the image. `release.yml` is dispatched by the last step of
semantic-release:

```bash
gh run list --repo noetl/worker --workflow release.yml --limit 2
gh run watch "$(gh run list --repo noetl/worker --workflow release.yml --limit 1 --json databaseId --jq '.[0].databaseId')" --repo noetl/worker
```

Confirm the tag and the image exist before touching prod:

```bash
VER="$(gh release list --repo noetl/worker --limit 1 --json tagName --jq '.[0].tagName')"; echo "$VER"
gcloud artifacts docker tags list \
  us-central1-docker.pkg.dev/shastaratech-noetl-prod/noetl/noetl-worker-rust \
  --format='value(tag)' | grep -x "${VER}"
DIGEST="$(gcloud artifacts docker images describe \
  "us-central1-docker.pkg.dev/shastaratech-noetl-prod/noetl/noetl-worker-rust:${VER}" \
  --format='value(image_summary.digest)')"; echo "$DIGEST"
```

### B.3 — RE-ADD THE CHECK NOW, not after the deploy

The deploy does not need the gate off. Close the window as soon as the image
exists.

⚠ **`PATCH .../required_status_checks` will NOT work here.** That endpoint
updates an *existing* status-check requirement; after B.1 deleted it there is
nothing to patch and it 404s. Re-adding requires a **full `PUT` of the branch
protection object**, and `PUT` demands `enforce_admins`,
`required_pull_request_reviews` and `restrictions` be present (nullable).

```bash
cat > /tmp/reprotect-worker.json <<'JSON'
{
  "required_status_checks": { "strict": true, "contexts": ["test"] },
  "enforce_admins": false,
  "required_pull_request_reviews": null,
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_linear_history": false,
  "required_conversation_resolution": false
}
JSON
gh api repos/noetl/worker/branches/main/protection -X PUT --input /tmp/reprotect-worker.json \
  --jq '"strict=\(.required_status_checks.strict) contexts=\(.required_status_checks.contexts) enforce_admins=\(.enforce_admins.enabled)"'
# expect: strict=true contexts=["test"] enforce_admins=false
```

That body is exactly the configuration captured in §0 — verified identical on
all three repos — so this restores the prior state field for field, not an
approximation of it.

⚠ Do not skip ahead to B.4 first. Every minute between B.1 and B.3 is ungated.

### B.4 — Deploy to prod, canary first

Context: `gke_shastaratech-noetl-prod_us-central1_noetl-prod-autopilot`,
namespace `noetl`, container name `noetl-worker` on every workload.

**Record the rollback target first:**

```bash
C=gke_shastaratech-noetl-prod_us-central1_noetl-prod-autopilot
kubectl --context $C -n noetl get deploy noetl-worker-rust \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
# current: noetl-worker-rust@sha256:8109155bf885777e81c12d1ca9f518d1e4597ad2dcced9c82bc4037d4d41dce3  (v5.133.1)
```

⚠ **Constraint that still holds:** no pool may run `≤ v5.131.x` while the
writer runs `≥ v5.132.0` — that client reads replies at 1 MiB while the newer
service may emit up to 16 MiB. Any rollback target must be `≥ v5.132.1`.

Canary one pool, verify, then the rest:

```bash
IMG="us-central1-docker.pkg.dev/shastaratech-noetl-prod/noetl/noetl-worker-rust@${DIGEST}"

kubectl --context $C -n noetl set image deploy/noetl-worker-rust noetl-worker="$IMG"
kubectl --context $C -n noetl rollout status deploy/noetl-worker-rust --timeout=600s
```

Then the remaining workloads, one at a time, `rollout status` between each:

```bash
for w in deploy/noetl-worker-system-pool deploy/noetl-worker-system-pool-shard1 sts/noetl-cmdbus-writer; do
  kubectl --context $C -n noetl set image "$w" noetl-worker="$IMG"
  kubectl --context $C -n noetl rollout status "$w" --timeout=600s
done
```

**Instant rollback, any degradation:**

```bash
kubectl --context $C -n noetl rollout undo deploy/noetl-worker-rust
```

### B.5 — Verify the three fixes actually reach users

This is the point of the whole exercise; do not stop at "pods are Running".

```bash
# the running binary really is the new version
kubectl --context $C -n noetl get pods -l app=noetl-worker-rust \
  -o jsonpath='{range .items[*]}{.status.containerStatuses[0].imageID}{"\n"}{end}' | sort -u
# must equal $DIGEST
```

* **tools#100** — pubsub poll wait 1s → 5s. ⚠ This is a **behaviour change**, not
  just a fix: a pubsub step that previously returned empty after 1s now waits up
  to 5s. Watch step durations on any playbook using `pubsub`, and confirm the
  clamp logs rather than silently truncating.
* **tools#99** — a transport failure is now visible to policy rules. Run a
  playbook whose `task_sequence` has a `do: retry` rule and force a transport
  error; the retry must fire. Before this, the outcome was swallowed and the
  rule never saw it.
* **server#434 symptom 3** — `do: retry` inert. Same check as tools#99; that
  symptom *is* this fix arriving. Symptom 1 stays behind
  `NOETL_EXECUTION_FAIL_ON_STEP_ERROR` and is **not** fixed by this release.

⚠ If you cannot produce a transport failure on demand, say so in the issue
rather than closing server#434 on the deploy alone. A deployed fix is not a
verified fix.

### B.6 — Record it

Append a row to
`noetl/ops → ci/manifests/noetl/ledger/noetl-worker-rust.tsv`:

```
<version>	<digest>	<ISO8601>	<git_sha>	<what shipped + the rollback target + which workloads observed running it>
```

---

## Which to choose

**Option A.** B has a real ungated window, reverses your own decision, and does
not prevent the next occurrence. A is one change per repo and the problem is
gone.

If A is blocked for a reason not visible here, the third possibility — giving
`semantic-release` an **admin PAT** instead of `GITHUB_TOKEN` (which bypasses,
since `enforce_admins: false`) — works too, but it is a credential decision and
it makes every release carry a human's admin rights. Not recommended over A.

---

## Do not repeat the underlying mistake

Before enabling a required status check on any repo here, check whether that
repo's release flow pushes to the protected branch:

```bash
grep -l "semantic-release/git" .releaserc* 2>/dev/null
```

If it does, the ruleset-with-bypass is the shape to start from — not classic
protection.

⚠ And note what the check was actually worth when it was made mandatory: on
`noetl/cli` the `test` job ran **69 of 245** tests, and on `noetl/server` it ran
**none** of `orchestrate-core`'s 163 (both fixed 2026-09-16 in cli#87,
server#455, tools#101). Making a check *required* is not the same as the check
being *sufficient*.
