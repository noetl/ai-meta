# RUNBOOK — unblock the release pipeline on `noetl/server`, `noetl/worker`, `noetl/tools`

**Status: OWNER ACTION REQUIRED. Nothing in this file has been executed.**
Both paths below are repo-**security** changes. They were deliberately not made
by the agent; option A was attempted and correctly refused by the safety
classifier.

Written 2026-09-16.

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
