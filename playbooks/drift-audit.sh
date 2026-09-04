#!/usr/bin/env bash
# Representation-drift audit — the checks that found seven instances in one
# session (2026-08-04/05).  See `agents/rules/representation-drift.md`.
#
# A representation is anything claiming to describe the running system: a
# manifest, a version pin, an image tag, a status column, a pipeline's
# reported state.  Each is a copy, true only while something forces it to
# agree with the original.  Nothing here forces that, so this script asks
# the rule's two questions mechanically:
#
#   1. what forces this to agree with reality?
#   2. if it disagreed, how would anyone find out?
#
# READ-ONLY.  Every check reads; none writes, deploys, or grants.
#
# Each check prints DRIFT / OK / SKIP and, on DRIFT, the evidence — not a
# verdict to be trusted but the numbers to look at.
#
# Usage:  ./playbooks/drift-audit.sh            (all checks)
#         ./playbooks/drift-audit.sh manifests  (one check)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ONLY="${1:-all}"
DRIFT=0

hdr() { printf "\n\033[1m== %s ==\033[0m\n" "$1"; }
drift() { DRIFT=$((DRIFT+1)); printf "  \033[31mDRIFT\033[0m  %s\n" "$1"; }
ok()   { printf "  \033[32mOK\033[0m     %s\n" "$1"; }
skip() { printf "  SKIP   %s\n" "$1"; }

# Fetch a code submodule's origin/main once per run, before any check reads that
# ref.  Three checks (inert tests, env-var-vs-wiki, orphan metric recorders) read
# `origin/main` from a submodule checkout.  None of them fetched it, so each was
# really measuring "whatever was last fetched locally" — and a clean result was
# indistinguishable from a stale ref.
#
# Measured 2026-08-10: NOETL_PROVIDER_ERROR_TERMINATES shipped in worker v5.109.0
# while repos/worker sat 25 commits behind origin/main.  The env-var check reported
# "worker: every env var it reads is named somewhere in noetl-worker-wiki" — a
# confident OK about code it could not see.  The wiki side of that same check had
# already learned this lesson and fetched; the code side had not.
FETCHED_REPOS=""
fetch_repo_once() {
  case " $FETCHED_REPOS " in *" $1 "*) return 0 ;; esac
  FETCHED_REPOS="$FETCHED_REPOS $1"
  ( cd "$1" && git fetch origin main --quiet 2>/dev/null ) || true
}
# A finding that has been investigated and deliberately left as-is.  Still
# printed, still visible, but not counted as drift — a check that reports the
# same decided item on every run trains the reader to skim it, which is the
# same failure as a check that never fires.  Every HOLD must name where the
# decision is recorded, so it can be re-opened rather than merely tolerated.
hold() { printf "  \033[33mHOLD\033[0m   %s\n" "$1"; }
run()  { [ "$ONLY" = "all" ] || [ "$ONLY" = "$1" ]; }

# Top-level, not inside a check: every check must be runnable standalone, and
# under `set -u` a variable scoped to another block makes the check ABORT while
# the script still prints "No drift found".  That happened — the catalog check
# died on an unbound OLD_PROJECT and reported clean.
OLD_PROJECT="noetl-demo-19700101"

# ---------------------------------------------------------------------------
# 1. Manifests naming a project/registry the cluster does not use.
#    Found noetl/ai-meta#234: 8 files still pinning `noetl-demo-19700101`
#    after the migration to `shastaratech-noetl-prod`, including all three
#    prod deployment manifests.
# ---------------------------------------------------------------------------
if run manifests; then
  hdr "manifests: stale project / registry references"
  # Scoped per repo because the SEVERITY differs and a single count hides that.
  # In ops it is mostly description; in travel it reaches the deploy workflow
  # and the planner that runs in prod (noetl/ai-meta#234, third widening).
  for repo in ops travel; do
    d="$ROOT/repos/$repo"
    [ -d "$d" ] || { skip "repos/$repo not checked out"; continue; }
    n=$(cd "$d" && git grep -l "$OLD_PROJECT" origin/main 2>/dev/null | wc -l | tr -d ' ')
    if [ "${n:-0}" -gt 0 ]; then
      drift "$n file(s) in repos/$repo reference the pre-migration project '$OLD_PROJECT' (noetl/ai-meta#234)"
      (cd "$d" && git grep -l "$OLD_PROJECT" origin/main 2>/dev/null | sed 's#origin/main:#         #' | head -8)
      # The live paths, called out separately — these are not documentation.
      (cd "$d" && git grep -l "$OLD_PROJECT" origin/main -- '.github/workflows/' 'playbooks/' 2>/dev/null \
        | sed 's#origin/main:#         !! LIVE PATH: #')
    else
      ok "repos/$repo: no references to '$OLD_PROJECT'"
    fi
  done
fi

# ---------------------------------------------------------------------------
# 1b. The stale project inside the CATALOG — i.e. inside a playbook that is
#     registered and executing in prod, not merely committed to a repo.
#     Found 2026-08-05: the live muno planner (v67) carries
#     `gcp_project: noetl-demo-19700101` in 7 places.  Correcting it means
#     registering a new playbook version, which is a release rather than a
#     sweep — so this reports and never edits.
# ---------------------------------------------------------------------------
if run catalog; then
  hdr "catalog: registered playbooks naming the pre-migration project"
  if command -v psql >/dev/null 2>&1 && [ -n "${PGPASSWORD:-}" ]; then
    # NOT `psql | while` — that runs the loop in a subshell, so drift()
    # increments a discarded copy of DRIFT and the exit summary under-reports.
    rows=$(psql -h 127.0.0.1 -p "${PGPORT_FWD:-15432}" -U noetl -d noetl -At -F'|' -c \
      "select path, max(version) from noetl.catalog
       where content like '%${OLD_PROJECT}%' group by 1 order by 1;" 2>/dev/null)
    if [ -z "$rows" ]; then
      ok "no registered playbook names '$OLD_PROJECT'"
    else
      while IFS='|' read -r path ver; do
        [ -n "$path" ] && drift "catalog $path (latest v$ver) names '$OLD_PROJECT' — a playbook REGISTERED and executing in prod (noetl/ai-meta#234)"
      done <<< "$rows"
    fi
  else
    skip "no psql / PGPASSWORD+port-forward — run with a pgbouncer forward on :15432 to include this"
  fi
fi

# ---------------------------------------------------------------------------
# 2. A caret range silently dropping a capability.
#    Found noetl/ai-meta#185: worker pinned `noetl-tools = "3.19.1"`, the
#    lockfile resolved to 3.26.1 (past the release that made duckdb
#    optional), the feature was never enabled, and libduckdb-sys vanished
#    from every shipped image.  Nobody edited the pin.
#
#    The general check: a crate whose Dockerfile enables a feature must
#    still have that feature's dependency in the lockfile.
# ---------------------------------------------------------------------------
if run features; then
  hdr "cargo: features a Dockerfile enables vs what the lockfile resolves"
  for repo in worker cli server tools; do
    d="$ROOT/repos/$repo"
    [ -d "$d" ] || { skip "repos/$repo not checked out"; continue; }
    df=$(cd "$d" && git show origin/main:Dockerfile 2>/dev/null || true)
    [ -n "$df" ] || { skip "$repo: no Dockerfile"; continue; }
    feats=$(printf '%s' "$df" | grep -oE '\-\-features [a-z0-9,\-]+' | awk '{print $2}' | tr ',' '\n' | sort -u)
    if [ -z "$feats" ]; then ok "$repo: Dockerfile enables no explicit features"; continue; fi
    for f in $feats; do
      # duckdb-integration is the known instance; the marker crate it must pull.
      case "$f" in
        duckdb-integration) marker="libduckdb-sys" ;;
        *) marker="" ;;
      esac
      [ -n "$marker" ] || { ok "$repo: feature '$f' (no marker crate registered to check)"; continue; }
      c=$(cd "$d" && git show origin/main:Cargo.lock 2>/dev/null | grep -c "name = \"$marker\"" || true)
      if [ "${c:-0}" -eq 0 ]; then
        drift "$repo: Dockerfile enables '$f' but '$marker' is absent from Cargo.lock — the shipped image would lack the capability (noetl/ai-meta#185)"
      else
        ok "$repo: '$f' -> '$marker' present in Cargo.lock"
      fi
    done
  done
fi

# ---------------------------------------------------------------------------
# 3. Published image architectures vs where they must run.
#    Found noetl/ai-meta#236: noetl/server is amd64-only while the kind
#    validation cluster is arm64, so a RELEASED server image can never run
#    there and every validation used a hand-built image no release produced.
# ---------------------------------------------------------------------------
if run images; then
  hdr "images: published architectures"
  if command -v crane >/dev/null 2>&1; then
    want_arch=$(kubectl --context kind-noetl get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}' 2>/dev/null || echo "")
    [ -n "$want_arch" ] && echo "         kind node architecture: $want_arch"
    # The gateway was NOT in this list until 2026-08-05, which is why its
    # amd64-only images went unnoticed: it cannot run on the arm64 validation
    # cluster at all, so "kind-validate the gateway" was silently impossible.
    # Its tags carry a `v` prefix; server and worker's do not.
    for pair in "server:ghcr.io/noetl/server" "worker:ghcr.io/noetl/worker" "gateway:ghcr.io/noetl/gateway"; do
      name="${pair%%:*}"; ref="${pair#*:}"
      tag=$(crane ls "$ref" 2>/dev/null | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' | tail -1)
      [ -n "$tag" ] || { skip "$name: no semver tag readable (auth?)"; continue; }
      arches=$(crane manifest "$ref:$tag" 2>/dev/null | python3 -c '
import json,sys
try:
    m=json.load(sys.stdin)
    a=[x["platform"]["architecture"] for x in m.get("manifests",[]) if x.get("platform",{}).get("architecture") not in (None,"unknown")]
    print(",".join(sorted(set(a))) or "single-arch")
except Exception: print("?")')
      if [ -n "$want_arch" ] && ! printf '%s' "$arches" | grep -q "$want_arch"; then
        drift "$name:$tag publishes [$arches] but the validation cluster is $want_arch (noetl/ai-meta#236)"
      else
        ok "$name:$tag -> [$arches]"
      fi
    done
  else
    skip "crane not installed"
  fi
fi

# ---------------------------------------------------------------------------
# 4. A release job that is reported as working and is not.
#    Found noetl/ai-meta#204 vs #211: #204 records publish-ar as LIVE while
#    it has failed on every release, each one needing a manual crane copy.
# ---------------------------------------------------------------------------
if run pipeline; then
  hdr "pipeline: publish-ar outcomes on the most recent releases"
  if command -v gh >/dev/null 2>&1; then
    for repo in server worker; do
      ids=$(gh run list --repo "noetl/$repo" --limit 8 --json databaseId,name \
             -q '.[]|select(.name|startswith("release-"))|.databaseId' 2>/dev/null | head -3)
      [ -n "$ids" ] || { skip "$repo: no release runs readable"; continue; }
      fails=0; total=0
      for id in $ids; do
        c=$(gh run view "$id" --repo "noetl/$repo" --json jobs \
             -q '.jobs[]|select(.name=="publish-ar")|.conclusion' 2>/dev/null)
        [ -n "$c" ] || continue
        total=$((total+1)); [ "$c" = "failure" ] && fails=$((fails+1))
      done
      if [ "$total" -eq 0 ]; then skip "$repo: no publish-ar job in recent releases"
      elif [ "$fails" -gt 0 ]; then
        drift "$repo: publish-ar failed $fails/$total recent releases — every image reached AR by manual crane copy (noetl/ai-meta#211)"
      else
        ok "$repo: publish-ar green $total/$total"
      fi
    done
  else
    skip "gh not installed"
  fi
fi

# ---------------------------------------------------------------------------
# 5. A denormalized table nothing writes.
#    Found noetl/ai-meta#235: noetl.execution.status froze at the Python
#    retirement and still reads as authoritative — it made a prod drain look
#    ineffective while it was working.  Static check only: does the live
#    control plane reference the table at all?
# ---------------------------------------------------------------------------
if run tables; then
  hdr "schema: tables the live control plane never touches"
  d="$ROOT/repos/server"
  if [ -d "$d" ]; then
    hits=$(cd "$d" && git grep -nE "(FROM|INTO|UPDATE)[[:space:]]+noetl\.execution\b" origin/main -- src 2>/dev/null | wc -l | tr -d ' ')
    if [ "${hits:-0}" -eq 0 ]; then
      drift "noetl.execution is never read or written by the Rust server — its status column is frozen and reads as authoritative (noetl/ai-meta#235)"
      echo "         status is derived instead by db::queries::event::get_execution_status"
    else
      ok "noetl.execution referenced by the server in $hits place(s)"
    fi
  else
    skip "repos/server not checked out"
  fi
fi

# ---------------------------------------------------------------------------
# 6. Open issues whose acceptance is fully ticked.
#    The judgement-heavy class this script said it could not catch — partly
#    automatable after all.  An OPEN issue with >=1 checkbox and ZERO unticked
#    is a strong signal the work landed and the record did not follow.
#    Would have caught #165 (all boxes ticked, planner seven versions past its
#    target) and #222 (last box blocked on a resolved blocker).
#
#    Reports candidates, never closes: "all boxes ticked" is evidence, not a
#    verdict — #223 has five of six phases genuinely run and should still NOT
#    be ticked, because two did not follow the sequence the issue exists to
#    hold.
# ---------------------------------------------------------------------------
if run issues; then
  hdr "issues: open, but every acceptance box is ticked"
  if command -v gh >/dev/null 2>&1; then
    found=0
    # --limit is a CAP, not a page size: `gh issue list --limit 60` silently
    # returns at most 60 and looks exactly like a total.  Reporting that number
    # as the open count is a mistake already made in this session's status
    # reports.  Ask for more than the queue can plausibly hold, and verify the
    # result is stable across two limits before trusting it as a total.
    listed=$(gh issue list --repo noetl/ai-meta --state open --label ai-task \
               --limit 200 --json number -q '.[].number' 2>/dev/null)
    n_listed=$(printf '%s\n' "$listed" | grep -c . || true)
    n_check=$(gh issue list --repo noetl/ai-meta --state open --label ai-task \
               --limit 400 --json number -q 'length' 2>/dev/null)
    if [ -n "$n_check" ] && [ "$n_listed" != "$n_check" ]; then
      drift "issue enumeration is TRUNCATED ($n_listed at limit 200 vs $n_check at 400) — counts below are not totals"
    fi
    echo "         scanning $n_listed open ai-task issues"
    for n in $listed; do
      body=$(gh issue view "$n" --repo noetl/ai-meta --json body -q .body 2>/dev/null)
      [ -n "$body" ] || continue
      done_n=$(printf '%s' "$body" | grep -cE '^[[:space:]]*-[[:space:]]*\[x\]' || true)
      todo_n=$(printf '%s' "$body" | grep -cE '^[[:space:]]*-[[:space:]]*\[ \]' || true)
      if [ "${done_n:-0}" -ge 1 ] && [ "${todo_n:-0}" -eq 0 ]; then
        title=$(gh issue view "$n" --repo noetl/ai-meta --json title -q .title 2>/dev/null)
        drift "#$n is OPEN with $done_n/$done_n boxes ticked — ${title:0:60}"
        found=1
      fi
    done
    [ "$found" -eq 0 ] && ok "no open ai-task issue has a fully-ticked acceptance list"
  else
    skip "gh not installed"
  fi
fi

# ---------------------------------------------------------------------------
# 7. Manifests declaring workloads that do not exist in the cluster.
#    The "dead install path" variant — worse than a stale description, because
#    the person who trips over it is doing a disaster-recovery rebuild.
#    Three instances found 2026-08-05:
#      ci/manifests/noetl/{server,worker}-deployment.yaml  (#97, Python-era,
#        and its image is the unsubstituted placeholder `image_name:image_tag`)
#      ci/manifests/nats/                                  (NATS deleted in T5)
#      automation/helm/.../outbox-publisher-deployment.yaml (#201)
#
#    Compares Deployment/StatefulSet NAMES declared under ci/manifests against
#    what the cluster actually runs.  Helm templates are skipped — their names
#    are templated and cannot be compared without rendering.
# ---------------------------------------------------------------------------
if run workloads; then
  hdr "manifests: declared workloads that do not exist in the cluster"
  d="$ROOT/repos/ops"
  if [ ! -d "$d" ]; then
    skip "repos/ops not checked out"
  elif ! kubectl --context "${PROD_CTX:-gke_shastaratech-noetl-prod_us-central1_noetl-prod-autopilot}" \
         get ns noetl >/dev/null 2>&1; then
    skip "prod context unreachable — cannot compare declared vs running"
  else
    live=$(kubectl --context "${PROD_CTX:-gke_shastaratech-noetl-prod_us-central1_noetl-prod-autopilot}" \
             -n noetl get deploy,sts -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
    missing=0
    notprod=""
    fixtures=""
    for f in $(cd "$d" && git ls-tree -r --name-only origin/main ci/manifests/noetl/ 2>/dev/null | grep -E '\.ya?ml$'); do
      # Deployment/StatefulSet metadata.name declared in this file
      names=$(cd "$d" && git show "origin/main:$f" 2>/dev/null | python3 -c '
import sys, yaml
try:
    for doc in yaml.safe_load_all(sys.stdin):
        if isinstance(doc, dict) and doc.get("kind") in ("Deployment","StatefulSet"):
            n=(doc.get("metadata") or {}).get("name")
            if not n: continue
            spec=((doc.get("spec") or {}).get("template") or {}).get("spec") or {}
            imgs=[c.get("image","") for c in spec.get("containers",[])]
            kind_only=any(i.startswith("localhost/") for i in imgs)
            template=any(("image_name" in i) or ("image_tag" in i) for i in imgs)
            tag="kind-only" if kind_only else ("template" if template else "prod-shaped")
            print(n+chr(9)+tag)
except Exception:
    pass' 2>/dev/null)
      while IFS=$'\t' read -r n tag; do
        [ -z "$n" ] && continue
        if ! printf '%s\n' "$live" | grep -qx "$n"; then
          # Only a prod-shaped manifest makes a claim about prod.  A localhost/
          # image cannot be pulled by GKE and a placeholder tag is not a spec,
          # so neither is drift — reporting them as such made 6 of 6 findings
          # here wrong, which is how a check teaches its reader to skim it.
          if [ "$tag" != "prod-shaped" ]; then
            notprod="${notprod}${f} ($n, $tag)\n"
            continue
          fi
          # "Declared but not running" has THREE causes and only one is drift:
          #   dead legacy      — the Python-era server/worker (#97)
          #   gated feature    — deployed only when enabled (flightsql, subscription pool)
          #   kind-only fixture— never intended for prod (spool-downstream-echo)
          # A check that cannot tell them apart gets ignored, so this reports
          # the fact and names the question rather than asserting drift.
          # A manifest may answer the question itself.  `# drift-audit: kind-only`
          # in the file means "never meant to run in prod", and the intent then
          # lives WITH THE ARTIFACT rather than in a list inside this checker — an
          # exception list here would be a second representation of the manifests
          # and would drift exactly like everything else this script watches.
          # ⚠ Read the marker from the SAME source the names came from
          # (`git show origin/main:$f`).  A plain `grep "$f"` resolves the path
          # against this script's cwd, not the ops checkout, so it silently finds
          # nothing and every marked fixture still reports as drift — which is
          # exactly what happened on the first attempt.
          if (cd "$d" && git show "origin/main:$f" 2>/dev/null) \
               | grep -q '^# drift-audit: kind-only'; then
            fixtures="${fixtures}${f} ($n)\n"
            continue
          fi
          drift "$f declares $n — not running in prod; is it dead legacy, a gated feature, or kind-only? (noetl/ai-meta#97)"
          missing=$((missing+1))
        fi
      done <<< "$names"
    done
    if [ -n "$notprod" ]; then
      hold "$(printf "$notprod" | grep -c .) manifest(s) declare workloads absent from prod BY DESIGN — kind-only or a template, not a claim about prod"
      printf "$notprod" | sed 's/^/         /'
    fi
    if [ -n "$fixtures" ]; then
      printf "         accounted kind-only fixtures (marked in-file, not drift):\n"
      printf "$fixtures" | sed 's/^/           /'
    fi
    if [ "$missing" -eq 0 ]; then
      ok "every declared Deployment/StatefulSet exists in prod"
    else
        echo "         NOTE: $missing prod-shaped manifest(s) declare a workload prod is not"
        echo "               running.  The kind-only and template ones are separated out above,"
        echo "               so what is left here is genuinely ambiguous: dead legacy, a gated"
        echo "               feature, or a fixture that happens to use a public image."
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 8. Live pods that no APPLIED PodMonitoring selects.
#
# The inverse of check 7.  Check 7 asks "is what we declared running?"; this
# asks "is what is running being watched?".  Found 2026-08-05: ns noetl had
# exactly one PodMonitoring (the cmdbus writer), so the server and all four
# worker pods were unscraped — and separately, the unapplied worker
# PodMonitoring enumerated `app` names and had missed the #166 Phase 5 shard,
# so applying it would have covered half the system pool while looking green.
#
# An enumerated selector is a copy of the workload set. Nothing forces it to
# agree, and partial coverage produces no signal at all — which is why this is
# a drift check and not a monitoring alert.
# ---------------------------------------------------------------------------
if run scrape; then
  hdr "cluster: running pods that no applied PodMonitoring selects"
  CTX="${PROD_CTX:-gke_shastaratech-noetl-prod_us-central1_noetl-prod-autopilot}"
  if ! kubectl --context "$CTX" get ns noetl >/dev/null 2>&1; then
    skip "prod context unreachable — cannot compare pods against scrapes"
  else
    # Every selector of every APPLIED PodMonitoring in ns noetl, as a label
    # query.  matchLabels -> k=v,k=v ; matchExpressions Exists -> k ; In -> k in (…)
    sels=$(kubectl --context "$CTX" -n noetl get podmonitoring -o json 2>/dev/null | python3 -c '
import sys, json
try: items = json.load(sys.stdin).get("items", [])
except Exception: sys.exit(0)
for it in items:
    sel = (it.get("spec") or {}).get("selector") or {}
    parts = [f"{k}={v}" for k, v in (sel.get("matchLabels") or {}).items()]
    for e in sel.get("matchExpressions") or []:
        op, key = e.get("operator"), e.get("key")
        if op == "Exists":
            parts.append(key)
        elif op == "In":
            vals = ",".join(e.get("values") or [])
            parts.append(key + " in (" + vals + ")")
    if parts: print(",".join(parts))
' 2>/dev/null)

    covered=""
    if [ -n "$sels" ]; then
      while IFS= read -r s; do
        [ -z "$s" ] && continue
        hits=$(kubectl --context "$CTX" -n noetl get pods -l "$s" \
                 -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
        covered=$(printf '%s\n%s' "$covered" "$hits")
      done <<< "$sels"
    fi

    # Pods owned by a Deployment/StatefulSet — CronJob pods are short-lived and
    # not expected to be scraped, so they are excluded rather than reported.
    allpods=$(kubectl --context "$CTX" -n noetl get pods \
                -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.ownerReferences[0].kind}{"\n"}{end}' 2>/dev/null \
              | awk '$2=="ReplicaSet" || $2=="StatefulSet" {print $1}')

    unscraped=0
    while IFS= read -r p; do
      [ -z "$p" ] && continue
      if ! printf '%s\n' "$covered" | grep -qxF "$p"; then
        drift "pod $p is selected by NO applied PodMonitoring — its /metrics reaches nothing"
        unscraped=$((unscraped + 1))
      fi
    done <<< "$allpods"

    n_pm=$(printf '%s\n' "$sels" | grep -c . || true)
    if [ "$unscraped" -eq 0 ]; then
      ok "every long-lived pod in ns noetl is selected by one of $n_pm applied PodMonitoring selector(s)"
    else
      echo "         $n_pm PodMonitoring selector(s) applied. A metric nothing scrapes cannot"
      echo "         alert, and produces no error — the gap is silent by construction."
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 9. Tests that are compiled but never run.
#
# A `fn` inside `mod tests` with no `#[test]` attribute and no caller is dead
# code wearing a test's name.  Found 2026-08-05 in two repos at once:
#
#   worker  command_completed_context_marks_a_parked_step   (noetl/worker#226)
#   server  test_issue_89_scalar_renders_unaffected         (noetl/server#305)
#
# Both had the same cause: a later test was inserted between an earlier test's
# doc comment and its `fn`, so the newcomer absorbed the `#[test]` (harmless
# warning) and the original was orphaned.  Both passed once enabled — the
# invariants held, they were simply unguarded.  The worker one guards #227's
# parked-step marker, whose whole job is to stop the non-convergence sweep
# terminating healthy work.
#
# `cargo check --all-targets` reports both halves, but neither server nor
# worker runs PR-level CI, so nothing surfaces them at review time.  This is
# the static equivalent and needs no build.
# ---------------------------------------------------------------------------
if run inert-tests; then
  hdr "rust: test-shaped functions that carry no #[test] and have no caller"
  found=0
  for r in worker server tools cli ehdb gateway; do
    d="$ROOT/repos/$r"
    [ -d "$d" ] || continue
    fetch_repo_once "$d"
    ref=$(cd "$d" && git rev-parse --verify -q origin/main 2>/dev/null)
    [ -z "$ref" ] && continue
    out=$(cd "$d" && git ls-tree -r --name-only "$ref" 2>/dev/null | grep '\.rs$' | while IFS= read -r f; do
      git show "$ref:$f" 2>/dev/null | python3 -c '
import sys, re
path = sys.argv[1]
L = sys.stdin.read().split("\n")
if not any(re.search(r"\bmod tests\b", l) for l in L): raise SystemExit

# Mark the line ranges that are inside a `mod tests` block, by brace depth.
inside = [False] * len(L)
depth = 0; active = False
for i, l in enumerate(L):
    if not active and re.search(r"\bmod tests\b", l):
        active = True; depth = 0
    if active:
        depth += l.count("{") - l.count("}")
        inside[i] = True
        if depth <= 0 and "{" in "".join(L[:i+1][-1:]) or (depth <= 0 and i > 0):
            if depth <= 0: active = False

def is_comment(x):
    t = x.strip()
    return t.startswith("//") or t.startswith("*") or t.startswith("/*")

for i, l in enumerate(L):
    if not inside[i]: continue
    m = re.match(r"\s*(?:pub )?(?:async )?fn (\w+)\s*\(\s*\)", l)
    if not m: continue
    name = m.group(1)
    j, has = i - 1, False
    while j >= 0:
        t = L[j].strip()
        if t.startswith("//"): j -= 1; continue
        if t.startswith("#["):
            if re.search(r"#\[\s*(tokio::)?test", t): has = True
            j -= 1; continue
        break
    if has: continue
    if "assert" not in "\n".join(L[i:i+40]): continue
    # A helper is CALLED. Comments that merely name it are not calls.
    calls = 0
    for k, x in enumerate(L):
        if name not in x: continue
        if re.match(rf"\s*(?:pub )?(?:async )?fn {name}\s*\(", x): continue
        if is_comment(x): continue
        calls += 1
    if calls == 0:
        print(f"{path}:{i+1}:{name}")
' "$f"
    done)
    if [ -n "$out" ]; then
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        drift "$r: ${line} — asserts, but carries no #[test] and nothing calls it"
        found=$((found + 1))
      done <<< "$out"
    fi
  done
  if [ "$found" -eq 0 ]; then
    ok "no orphaned test-shaped functions in worker/server/tools/cli/ehdb/gateway"
  else
    echo "         Confirm with: cargo check --all-targets (reports dead_code +"
    echo "         duplicate_macro_attributes for exactly this shape).  Enable the"
    echo "         attribute and RUN it before assuming the invariant holds."
  fi
fi

# ---------------------------------------------------------------------------
# 10. Env vars the binary reads that its deployment-spec page never names.
#
# wiki-maintenance.md Rule 2a makes each component's `deployment-specification`
# page the source of truth for its env vars.  Nothing forces that to agree with
# the code.  Measured 2026-08-05: 18 literal `env::var("NOETL_*")` reads in
# server@main and 25 in worker@main were absent from their pages, and ELEVEN of
# them were set in production at that moment — including the whole post-T5
# events-bus wiring and the #166 chain-index bounds whose absence had already
# caused an OOM wedge.
#
# Only the literal-read direction is reported.  The reverse (documented but not
# read) is dominated by false positives: `envy::prefixed("NOETL_")` derives vars
# from struct field names, and pages legitimately mention a sibling component's
# variables.
# ---------------------------------------------------------------------------
if run env-docs; then
  hdr "wiki: env vars the binary reads that its deployment-spec page omits"
  # gateway has no deployment-specification.md; configuration.md is its equivalent
  # (Rule 2a names the page, but the substance is what matters).
  for pair in "server:noetl-server-wiki:deployment-specification.md" \
              "worker:noetl-worker-wiki:deployment-specification.md" \
              "gateway:noetl-gateway-wiki:configuration.md"; do
    repo="${pair%%:*}"; rest="${pair#*:}"; wiki="${rest%%:*}"; pagename="${rest#*:}"
    d="$ROOT/repos/$repo"; page="$ROOT/repos/$wiki/$pagename"
    [ -d "$d" ] || { skip "repos/$repo not checked out"; continue; }
    [ -f "$page" ] || { skip "$wiki has no $pagename"; continue; }
    fetch_repo_once "$d"
    ref=$(cd "$d" && git rev-parse --verify -q origin/main 2>/dev/null)
    [ -z "$ref" ] && { skip "$repo: no origin/main"; continue; }
    # Fetch the WIKI first.  A stale local wiki checkout makes variables that are
    # documented at the true tip read as missing — that happened, and produced a
    # duplicate section on a page that already had the row.
    ( cd "$ROOT/repos/$wiki" && git fetch origin --quiet 2>/dev/null ) || true
    wref=$(cd "$ROOT/repos/$wiki" && (git rev-parse --verify -q origin/master 2>/dev/null \
             || git rev-parse --verify -q origin/main 2>/dev/null))
    [ -z "$wref" ] && wref=HEAD
    # Compare against EVERY page, not just deployment-specification.md: a var
    # documented on a sibling page is documented.  Rule 2a still wants it on the
    # spec page, but that is an editorial call, not drift.
    corpus=$(cd "$ROOT/repos/$wiki" && git grep -h -oE '(NOETL|RUST)_[A-Z0-9_]+' "$wref" -- '*.md' 2>/dev/null | sort -u)
    # Match helper reads too, not just env::var.  The worker wraps every typed
    # read in env_bool / env_u32 / env_u64 / env_addr / env_millis / env_truthy,
    # and an env::var-only pattern missed 55 of its 107 variables — including
    # NOETL_STATE_AFFINITY_ROUTE, which is set in prod and read by nothing.
    # Three read idioms, all of which have bitten:
    #   env::var("NOETL_X")            — the obvious one
    #   env_bool("NOETL_X", …)         — typed helpers; 55 of the worker's vars
    #   const X_ENV: &str = "NOETL_X"  — then env::var(X_ENV); 44 more, incl.
    #                                    the whole NOETL_EHDB_* tier family
    miss=$( (cd "$d" && git grep -ohE '((env::var(_os)?|env_[a-z0-9_]+)\(\s*|const [A-Z_]+ *: *&str *= *)"(NOETL|RUST)_[A-Z0-9_]*"' "$ref" -- src 2>/dev/null) \
            | grep -oE '"(NOETL|RUST)_[A-Z0-9_]*"' | tr -d '"' | sort -u \
            | while IFS= read -r v; do
                printf '%s\n' "$corpus" | grep -qx "$v" || printf '%s\n' "$v"
              done )
    n=$(printf '%s\n' "$miss" | grep -c . || true)
    if [ "${n:-0}" -eq 0 ]; then
      ok "$repo: every env var it reads is named somewhere in $wiki"
    else
      drift "$repo: $n env var(s) read by the binary are absent from $wiki/$pagename (Rule 2a)"
      printf '%s\n' "$miss" | head -12 | sed 's/^/         /'
      echo "         Cross-check which are LIVE:  kubectl -n noetl get deploy -o json | grep -o '\"NOETL_[A-Z_]*\"'"
      echo "         NOTE: reads inside a #[cfg(test)] module are NOT filtered here."
      echo "         The gateway's NOETL_LIVE_OIDC_* trio is read only by an #[ignore]d"
      echo "         live-validation test and does not belong on a config page — confirm"
      echo "         a var is runtime before writing it up."
    fi
  done
fi

# ---------------------------------------------------------------------------
# 11. Metric recorders nothing calls.
#
# A metric can be declared, registered, exported in /metrics HELP output — and
# still never carry a value, because the function that sets it has no caller.
# Prometheus shows nothing, which is indistinguishable from "healthy zero".
#
# Found 2026-08-05: `record_nats_consumer_lag` sets
# noetl_worker_nats_consumer_pending{stream,consumer}.  Its doc says "called by
# the periodic lag poller after fetching consumer info from JetStream"; that
# poller went with NATS at T5, and the function now has no caller.  Three
# alerts in rules-materializer-lag.yaml recorded off that gauge, so they could
# never fire — guarding the component whose stall stops the durable log.
#
# An EARLIER sweep asked "does a recorder exist for each metric" and reported
# zero orphans.  It does exist.  The right question is whether it is REACHED.
# ---------------------------------------------------------------------------
if run dead-recorders; then
  hdr "rust: metric recorders with no caller"
  for repo in worker server; do
    d="$ROOT/repos/$repo"
    [ -d "$d" ] || { skip "repos/$repo not checked out"; continue; }
    fetch_repo_once "$d"
    ref=$(cd "$d" && git rev-parse --verify -q origin/main 2>/dev/null)
    [ -z "$ref" ] && { skip "$repo: no origin/main"; continue; }
    # Only functions that actually MUTATE a metric count.  metrics.rs is full of
    # lazy accessors (`auth_jwt_verify_total()` returning the handle) called only
    # from the record_* wrappers in the same file; flagging those made a first
    # cut report 51 of the server's 66 as orphans.
    muts=$(cd "$d" && git show "$ref:src/metrics.rs" 2>/dev/null | python3 "$ROOT/playbooks/lib/mutating_recorders.py")
    out=""
    while IFS= read -r fn; do
      [ -z "$fn" ] && continue
      n=$(cd "$d" && git grep -l "$fn" "$ref" -- src 2>/dev/null | grep -cv 'src/metrics.rs' || true)
      [ "${n:-0}" -eq 0 ] && out="${out}${fn}\n"
    done <<< "$muts"
    # Recorders investigated under noetl/ai-meta#242 and deliberately kept.
    # `record_affinity_decision` is downstream of an INERT FEATURE, not an
    # unwired measurement: AffinityConfig::from_env has no non-test caller, so
    # no AffinityDecision is ever constructed.  Deleting it would strip the
    # instrumentation while leaving the feature, so switching affinity routing
    # on later would come up silently unmeasured — the exact defect this check
    # exists to catch.  Resolve it when #116 / #172 resolve, not here.
    held="record_affinity_decision"
    kept="" ; flagged=""
    while IFS= read -r fn; do
      [ -z "$fn" ] && continue
      case " $held " in
        *" $fn "*) kept="${kept}${fn}\n" ;;
        *)         flagged="${flagged}${fn}\n" ;;
      esac
    done <<< "$(printf "$out")"
    n=$(printf "$flagged" | grep -c . || true)
    h=$(printf "$kept" | grep -c . || true)
    if [ "${n:-0}" -eq 0 ]; then
      ok "$repo: every metric-mutating recorder in metrics.rs is called from src/"
    else
      drift "$repo: $n metric recorder(s) mutate a metric but have NO caller — what they set can never move"
      printf "$flagged" | head -10 | sed 's/^/         /'
      echo "         Confirm on a live pod: the metric is absent from /metrics while"
      echo "         its siblings are present.  Then check no ALERT records off it."
    fi
    if [ "${h:-0}" -gt 0 ]; then
      hold "$repo: $h recorder(s) knowingly unwired — see noetl/ai-meta#242"
      printf "$kept" | head -10 | sed 's/^/         /'
    fi
  done
fi

if run pinned-sets; then
  hdr "metrics: pinned label sets vs the literals actually recorded"
  # A labelled metric is ABSENT from /metrics until incremented, so known label
  # values are pinned at 0 to make "healthy" distinguishable from "this binary
  # does not have the metric".  A pinned set that OMITS one value reintroduces
  # exactly the bug it was meant to fix, on the omitted value only, while the
  # rest read 0 and look complete.
  #
  # That happened: `record_result_tier_gc` has 8 outcomes; a same-line grep saw
  # 6 (one literal wraps to the next line) and reading the file saw 7 (there are
  # two call blocks).  The Rust guards catch it — but noetl/ai-meta#232 records
  # that NO cargo test runs in CI on any Rust repo, so nothing executes them
  # unless a human does.  This is their runner.
  if command -v python3 >/dev/null 2>&1; then
    out=$(python3 "$ROOT/playbooks/lib/pinned_sets.py" "$ROOT" 2>/dev/null)
    res=$(printf '%s\n' "$out" | tail -1)
    n_short=$(printf '%s' "$res" | awk '{print $2+0}')
    n_noguard=$(printf '%s' "$res" | awk '{print $3+0}')
    if [ "${n_short:-0}" -gt 0 ]; then
      drift "$n_short pinned label set(s) omit a value the code records — the omitted series stays ABSENT while the rest read 0"
      printf '%s\n' "$out" | grep '^SHORT' | sed 's/^/         /'
    fi
    if [ "${n_noguard:-0}" -gt 0 ]; then
      drift "$n_noguard pinned set(s) are unverifiable — a const with no registry entry, or a recorder that was renamed"
      printf '%s\n' "$out" | grep '^NO-GUARD' | sed 's/^/         /'
    fi
    if [ "${n_short:-0}" -eq 0 ] && [ "${n_noguard:-0}" -eq 0 ]; then
      ok "every pinned set matches its call-site literals ($(printf '%s\n' "$out" | grep -c '^OK') set(s) checked)"
    fi
  else
    skip "no python3 — cannot compare pinned sets against call sites"
  fi
fi

if run worktrees; then
  hdr "git: submodule worktrees that resolve to the git dir"
  # A worktree whose `core.worktree` resolves to the module directory reports
  # `--is-inside-work-tree=false`, and every `status` / `diff` / `add` in it
  # then describes the GIT DIRECTORY instead of the checkout.  Nothing errors:
  # the diff simply looks plausible and is of the wrong thing, and a commit
  # there writes the wrong tree.
  #
  # Cause: `core.worktree` sits in the SHARED config while
  # `extensions.worktreeConfig` is on, so its relative path — correct from the
  # primary's gitdir — lands back on the module directory from a secondary's
  # gitdir, two levels deeper.  It does not fire uniformly: repos/ops,
  # repos/e2e and repos/cli were all fine on the day repos/noetl was not,
  # which is exactly what makes the broken one read as a repo problem.
  #
  # This is per-clone, not per-repo: `.git/modules/<path>/config` is not
  # version-controlled, so a fresh clone starts broken again.  That is why
  # this check exists rather than only the fix (noetl/ai-meta#239).
  found=0
  for sm in $(cd "$ROOT" && git config -f .gitmodules --get-regexp '^submodule\..*\.path$' 2>/dev/null | awk '{print $2}'); do
    d="$ROOT/$sm"
    [ -d "$d" ] || continue
    (cd "$d" && git rev-parse --git-dir >/dev/null 2>&1) || continue
    shared=$(cd "$d" && git config --local --get core.worktree 2>/dev/null || true)
    [ -z "$shared" ] && continue
    wtcfg=$(cd "$d" && git config --get extensions.worktreeConfig 2>/dev/null || true)
    [ "$wtcfg" = "true" ] || continue
    bad=0; total=0
    while IFS= read -r wt; do
      [ -z "$wt" ] && continue
      total=$((total+1))
      r=$(git -C "$wt" rev-parse --is-inside-work-tree 2>/dev/null || true)
      [ "$r" = "true" ] || bad=$((bad+1))
    done <<< "$(cd "$d" && git worktree list 2>/dev/null | awk '{print $1}')"
    if [ "$bad" -gt 1 ]; then
      found=1
      drift "$sm: $bad of $total worktrees resolve to the git dir, not their checkout — status/diff/add there describe the wrong tree"
      echo "         core.worktree is in the SHARED config with extensions.worktreeConfig=true."
      echo "         Fix, from the primary (reversible, and repairs existing worktrees):"
      echo "           git -C $sm config --worktree core.worktree \"\$(pwd)/$sm\""
      echo "           git -C $sm config --local  --unset core.worktree"
    fi
  done
  [ "$found" -eq 0 ] && ok "no submodule keeps core.worktree in the shared config alongside worktreeConfig"
fi

# ---------------------------------------------------------------- provider-inline
# noetl/ai-meta#295.  The HotelBeds provider dispatch code exists in TWO places:
# inlined in the travel planner (AUTHORITATIVE, and what production runs) and in
# the standalone MCP playbooks under noetl/ops (a mirror, still used by
# muno/playbooks/hotel-cards).  Nothing forces them to agree.
#
# This is not hypothetical.  On 2026-08-24 each copy held something the other
# lacked: the ops mirror carried the #175 "do not leak the raw provider body to
# the user" fix for activities+transfers that had NEVER been registered, while
# the registered/live copy carried the prod project name the mirror still got
# wrong (it named the retired noetl-demo-19700101).  Both looked fine in
# isolation; the disagreement was only visible by comparing them.
if run provider-inline; then
  hdr "provider-inline — planner inline code vs the ops MCP mirror (#295)"
  PL="$ROOT/repos/travel/playbooks/itinerary-planner.yaml"
  if [ ! -f "$PL" ]; then
    skip "repos/travel not checked out"
  elif ! command -v python3 >/dev/null 2>&1; then
    skip "python3 unavailable"
  else
    out=$(python3 - "$ROOT" <<'PYEOF'
import sys, os
try:
    import yaml
except Exception:
    print("SKIP|pyyaml unavailable"); raise SystemExit
root = sys.argv[1]
PAIRS = {
    "call_hotelbeds_hotels":     "hotelbeds",
    "call_hotelbeds_book":       "hotelbeds",
    "call_hotelbeds_activities": "hotelbeds-activities",
    "call_hotelbeds_transfers":  "hotelbeds-transfers",
}
def dispatch_code(path):
    with open(path, encoding="utf-8") as fh:
        doc = yaml.safe_load(fh)
    for st in doc.get("workflow") or []:
        tool = st.get("tool") or {}
        if tool.get("kind") == "python" and tool.get("code"):
            return tool["code"]
    return None
try:
    planner = yaml.safe_load(open(os.path.join(root, "repos/travel/playbooks/itinerary-planner.yaml"), encoding="utf-8"))
except Exception as exc:
    print(f"SKIP|planner unreadable: {exc}"); raise SystemExit
inline = {}
for st in planner.get("workflow") or []:
    tool = st.get("tool") or {}
    if st.get("step") in PAIRS:
        if tool.get("kind") != "python":
            print(f"DRIFT|{st['step']} is kind={tool.get('kind')}, not the inlined python the decision requires")
        inline[st["step"]] = tool.get("code") or ""
for step, prov in PAIRS.items():
    mirror = os.path.join(root, "repos/ops/automation/agents/mcp", prov + ".yaml")
    if step not in inline:
        print(f"DRIFT|{step} missing from the planner — the authoritative copy is gone"); continue
    if not os.path.exists(mirror):
        print(f"SKIP|{prov}: ops mirror not checked out"); continue
    try:
        mcode = dispatch_code(mirror)
    except Exception as exc:
        print(f"SKIP|{prov}: mirror unparseable ({exc})"); continue
    if mcode is None:
        print(f"DRIFT|{prov}: mirror has no python dispatch step"); continue
    if mcode.strip() == inline[step].strip():
        print(f"OK|{step} == {prov} mirror")
    else:
        a, b = inline[step], mcode
        print(f"DRIFT|{step} differs from the {prov} mirror "
              f"(planner {len(a)} chars vs mirror {len(b)}); "
              f"175fix planner={'user_message' in a} mirror={'user_message' in b}; "
              f"retired-project planner={'noetl-demo-19700101' in a} mirror={'noetl-demo-19700101' in b}")
PYEOF
    )
    if [ -z "$out" ]; then
      skip "no provider steps compared"
    else
      while IFS='|' read -r verdict msg; do
        [ -z "$verdict" ] && continue
        case "$verdict" in
          OK)    ok "$msg" ;;
          SKIP)  skip "$msg" ;;
          DRIFT) drift "$msg"
                 echo "         Authoritative copy is the PLANNER INLINE code (noetl/ai-meta#295)."
                 echo "         Fix in the planner first, then mirror into repos/ops in the same change set." ;;
        esac
      done <<< "$out"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 12. The platform schema exists in TWO repos and nothing forces them to agree.
#
# The Rust server does not create its own schema; it expects one to be
# provisioned, and its query modules describe these columns as owned by
# schema_ddl.sql.  That file historically lived only in noetl/noetl (the legacy
# Python repo being retired), so repos/server now carries the destination copy
# at db/ddl/postgres/schema_ddl.sql.
#
# Ownership has NOT transferred: every deploy path still loads noetl/noetl's
# copy, because no ops playbook defines a server_repo_dir.  So there are two
# copies of a 1,060-line schema, and the deploy uses the one the server does NOT
# ship.  If they diverge, the cluster gets a schema the running binary was not
# built against -- and nothing anywhere would say so.
#
# This check IS the forcing function.  It compares content only, ignoring the
# transitional header on the server copy and trailing whitespace.
# ---------------------------------------------------------------------------
if run volumes; then
  hdr "cluster: writer volume headroom, and whether a full one would be visible"
  CTX="${PROD_CTX:-gke_shastaratech-noetl-prod_us-central1_noetl-prod-autopilot}"
  if ! kubectl --context "$CTX" get ns noetl >/dev/null 2>&1; then
    skip "prod context unreachable — cannot read writer volumes"
  else
    # Why this check exists.  On 2026-09-01 /data/cmdbus reached 100% full and
    # every POST /api/execute returned 500 for hours, while the writer pod
    # reported Ready, restarts=0, all nine listeners bound, and ZERO ERROR or
    # WARN lines.  serve_ingest answered append_batch failure with a bare
    # `return`, discarding the error (noetl/ehdb#345), so a full volume and a
    # serde-incompatible record produced byte-identical symptoms and no signal.
    #
    # A full volume is not a representation drifting from reality — it IS the
    # reality.  It belongs here because the thing that drifted was the
    # REPORTED health: `Ready` claimed to describe a writer that could not
    # accept a single write.
    WPOD="${WRITER_POD:-noetl-cmdbus-writer-0}"
    if ! kubectl --context "$CTX" -n noetl get pod "$WPOD" >/dev/null 2>&1; then
      skip "$WPOD not found — set WRITER_POD= to override"
    else
      df_out=$(kubectl --context "$CTX" -n noetl exec "$WPOD" -- df -P /data/cmdbus /data/eventbus /data/eventkv 2>/dev/null | tail -n +2)
      if [ -z "$df_out" ]; then
        skip "could not read df from $WPOD"
      else
        worst=0
        while IFS= read -r line; do
          [ -z "$line" ] && continue
          pct=$(printf '%s' "$line" | awk '{gsub(/%/,"",$5); print $5}')
          mnt=$(printf '%s' "$line" | awk '{print $6}')
          avail=$(printf '%s' "$line" | awk '{print $4}')
          case "$pct" in ''|*[!0-9]*) continue ;; esac
          [ "$pct" -gt "$worst" ] && worst=$pct
          if [ "$pct" -ge 80 ]; then
            drift "$mnt is ${pct}% full (${avail}K avail) on $WPOD"
            echo "         At 100% every append fails and the ingest face drops each publish."
            echo "         Before noetl/ehdb#345 that was silent: no log, no metric, pod still Ready."
          fi
        done <<< "$df_out"
        [ "$worst" -lt 80 ] && ok "writer volumes below 80% (worst ${worst}%)"

        # The quadratic-growth signature (noetl/ehdb#344).  ehdb-l0 wrote a FULL
        # manifest snapshot per version and pruned none; snapshot size grows with
        # part count while snapshot count grows with write count.  Prod reached
        # 6,770 snapshots / 19.4 GB behind 71.8 MB of real data.  Manifest bytes
        # far exceeding part bytes is that signature, and it shows up long before
        # the volume is full.
        for base in /data/cmdbus /data/eventbus; do
          mb=$(kubectl --context "$CTX" -n noetl exec "$WPOD" -- du -sk "$base/manifest" 2>/dev/null | awk '{print $1}')
          pb=$(kubectl --context "$CTX" -n noetl exec "$WPOD" -- du -sk "$base/parts" 2>/dev/null | awk '{print $1}')
          case "${mb:-x}${pb:-x}" in *[!0-9]*) continue ;; esac
          [ "${pb:-0}" -lt 1 ] && continue
          ratio=$(( mb / (pb > 0 ? pb : 1) ))
          if [ "$ratio" -ge 5 ]; then
            drift "$base manifest is ${ratio}x the size of its parts (${mb}K vs ${pb}K)"
            echo "         That is the unbounded-retention signature. Confirm the running binary"
            echo "         carries noetl/ehdb#344 — check ehdb_l0_manifest_versions_retained below."
          else
            ok "$base manifest/parts ratio ${ratio}x (${mb}K vs ${pb}K)"
          fi
        done

        # Is a failing writer even observable on this binary?  ABSENT is not ZERO:
        # a build predating noetl/ehdb#345 serves no such series at all, which
        # reads exactly like a healthy one.  Say which it is rather than printing
        # a reassuring nothing.
        m=$(kubectl --context "$CTX" -n noetl exec "$WPOD" -- wget -qO- --timeout=8 http://127.0.0.1:9102/metrics 2>/dev/null)
        if [ -z "$m" ]; then
          skip "writer :9102/metrics unreadable — cannot tell a healthy writer from a refusing one"
        elif ! printf '%s' "$m" | grep -q "ehdb_l0_ingest_append_failed"; then
          drift "the running writer does not expose ehdb_l0_ingest_append_failed"
          echo "         This binary predates noetl/ehdb#345 + noetl/worker#304, so a writer"
          echo "         refusing every append is INDISTINGUISHABLE from a healthy one."
          echo "         Absence here is a coverage gap, not a clean bill of health."
        else
          af=$(printf '%s' "$m" | awk '/^ehdb_l0_ingest_append_failed /{print $2}')
          df_=$(printf '%s' "$m" | awk '/^ehdb_l0_ingest_decode_failed /{print $2}')
          if [ "${af:-0}" != "0" ]; then
            drift "writer refused ${af} append(s) — check volume headroom first"
          elif [ "${df_:-0}" != "0" ]; then
            drift "writer rejected ${df_} frame(s) as undecodable — publisher/writer version skew, NOT a disk problem"
          else
            ok "ingest failure counters present and 0 (present, so 0 means healthy)"
          fi
        fi
      fi
    fi
  fi
fi


if run system-pool-scaling; then
  hdr "cluster: system-pool autoscaling vs durable-backend shard ownership"
  CTX="${PROD_CTX:-gke_shastaratech-noetl-prod_us-central1_noetl-prod-autopilot}"
  if ! kubectl --context "$CTX" get ns noetl >/dev/null 2>&1; then
    skip "prod context unreachable"
  else
    # noetl/ai-meta#318. Autoscaling the system pool is safe ONLY while the
    # durable event-log backend is unselected.
    #
    # Adding replicas is fine today because `ClaimCoordinator::claim_next`
    # guarantees "members sharing a filter compete exactly-once", and the pool's
    # members already share one subject filter. `NOETL_SHARD_INDEX` is inert for
    # exclusivity: the command consumer filters by SUBJECT and the state
    # materializer keys on `NOETL_RESULT_SHARD_COUNT`.
    #
    # ⚠⚠ But `NOETL_SHARD_INDEX` IS load-bearing for the DURABLE backend
    # (`ownership_from_env` -> `ShardOwnership`). Selecting it via
    # `NOETL_EHDB_EVENTLOG_BACKEND=durable` while replicas > 1 makes two pods
    # owners of one shard. These are two numbers that must agree, and nothing in
    # Kubernetes couples them — so the disagreement is checked here rather than
    # discovered as corruption.
    #
    # TEST HOOK: set SYSTEM_POOL_BACKEND_OVERRIDE to exercise the failing branch
    # without touching prod.
    pools=$(kubectl --context "$CTX" -n noetl get deploy -o json 2>/dev/null | python3 -c '
import sys, json
try: items = json.load(sys.stdin).get("items", [])
except Exception: sys.exit(0)
for it in items:
    n = it["metadata"]["name"]
    if "system-pool" not in n: continue
    env = {e["name"]: e.get("value") for e in it["spec"]["template"]["spec"]["containers"][0].get("env", [])}
    print("%s|%s|%s" % (n, env.get("NOETL_EHDB_EVENTLOG_BACKEND", ""), it["spec"].get("replicas", 1)))
' 2>/dev/null)

    if [ -z "$pools" ]; then
      skip "no system-pool deployments found"
    else
      unsafe=0
      # ⚠ '|' not tab: tab is IFS-WHITESPACE in bash, so consecutive tabs collapse
      # into one delimiter and an empty middle field silently vanishes -- which
      # shifted `replicas` into `backend` and made the guard read a healthy
      # 'unset' as the string '1'. A guard that misparses reports OK for the
      # wrong reason.
      while IFS='|' read -r name backend replicas; do
        [ -z "$name" ] && continue
        [ -n "${SYSTEM_POOL_BACKEND_OVERRIDE:-}" ] && backend="$SYSTEM_POOL_BACKEND_OVERRIDE"
        scaled=$(kubectl --context "$CTX" -n noetl get scaledobject -o json 2>/dev/null | python3 -c "
import sys, json
try: items = json.load(sys.stdin).get('items', [])
except Exception: sys.exit(0)
print(sum(1 for i in items if (i.get('spec') or {}).get('scaleTargetRef',{}).get('name') == '$name'))
" 2>/dev/null)
        scaled="${scaled:-0}"
        multi=0
        [ "${replicas:-1}" -gt 1 ] 2>/dev/null && multi=1
        [ "$scaled" -gt 0 ] 2>/dev/null && multi=1
        if [ "$backend" = "durable" ] && [ "$multi" = "1" ]; then
          unsafe=$((unsafe+1))
          drift "$name: NOETL_EHDB_EVENTLOG_BACKEND=durable WITH autoscaling/replicas>1"
          echo "         NOETL_SHARD_INDEX becomes load-bearing under the durable backend"
          echo "         (ownership_from_env -> ShardOwnership). Replicas sharing an index are"
          echo "         TWO OWNERS OF ONE SHARD. Remove the ScaledObject, or give each replica"
          echo "         its own shard index before enabling that backend."
        else
          ok "$name: backend='${backend:-unset->LocalReference}' scaledobjects=$scaled replicas=${replicas:-1}"
        fi
      done <<< "$pools"
      [ "$unsafe" -eq 0 ] && ok "system-pool autoscaling and shard ownership agree"
    fi
  fi
fi


if run schema-copies; then
  hdr "schema: the two platform-DDL copies"
  A="$ROOT/repos/noetl/noetl/database/ddl/postgres/schema_ddl.sql"
  B="$ROOT/repos/server/db/ddl/postgres/schema_ddl.sql"
  if [ ! -f "$A" ]; then
    skip "noetl/noetl copy not checked out"
  elif [ ! -f "$B" ]; then
    skip "repos/server copy not present (ownership move not started)"
  else
    # Drop the leading '-- ' header block from the server copy: everything up to
    # and including the provenance line.  Compare the SQL bodies.
    strip() { sed 's/[[:space:]]*$//' "$1"; }
    body_b=$(awk 'f{print} /^-- +noetl\/database\/ddl\/postgres\/schema_ddl\.sql$/{f=1}' "$B" | sed 's/[[:space:]]*$//')
    body_a=$(strip "$A")
    if [ -z "$body_b" ]; then
      drift "server copy header marker missing — cannot compare bodies"
      echo "         Expected the provenance line naming the source path."
    elif [ "$body_a" = "$body_b" ]; then
      ok "the two schema_ddl.sql copies agree ($(printf '%s' "$body_a" | wc -l | tr -d ' ') lines)"
    else
      drift "schema_ddl.sql differs between noetl/noetl and repos/server"
      echo "         $(diff <(printf '%s' "$body_a") <(printf '%s' "$body_b") | grep -c '^[<>]') differing line(s)."
      echo "         The DEPLOY uses noetl/noetl's copy; the server was built against its own."
      echo "         Edit both in the same change set until ops repoints (ai-meta#201)."
    fi
  fi
fi


# ------------------------------------------------------------- knob-observability
# noetl/ai-meta#320.  A tuning env var that changes runtime behaviour but whose
# VALUE is published nowhere.
#
# This is the defect the #320 mitigation shipped with.
# `NOETL_EHDB_EVENTLOG_MIRROR_DRAIN_CONCURRENCY=1` was applied to production to
# stop a 99% mirror failure rate, and nothing on the running process reported it:
# the knob is read per drain pass rather than at startup, and the ARMED log line
# carried the other three knobs but not that one.  The only way to check was the
# Deployment spec — a different representation, and one that can disagree with
# the process.
#
# A rollback knob whose engagement cannot be observed is the same defect class as
# the incident it mitigates, so it gets a check rather than a note.
#
# The rule: every `*_ENV` constant in the mirror-queue modules must appear either
# as a field on that module's startup `info!` or in a `crate::metrics::` call.
if run knob-observability; then
  hdr "knob-observability — tuning env vars whose value is published nowhere (#320)"
  found=0
  for m in ehdb_eventlog_mirror_queue ehdb_projection_mirror_queue; do
    f="$ROOT/repos/server/src/handlers/$m.rs"
    [ -f "$f" ] || continue
    knobs=$(grep -oE '^pub const [A-Z_]+_ENV' "$f" | awk '{print $3}')
    [ -n "$knobs" ] || continue
    # Everything that could publish a value: the startup log's field list and any
    # metrics call (a gauge's NAME carries the knob's stem, e.g. ASYNC_ENV ->
    # `..._async_enabled`).  Matching the stem as a SUBSTRING of these is what
    # makes `enqueue_timeout` match the field `enqueue_timeout_ms` and `async`
    # match the gauge accessor.
    #
    # ⚠ The first version of this check compared the stem to whole field names and
    # reported 5 false positives out of 6.  A check that cries wolf is worse than
    # no check — it teaches people to skim past real drift.
    surface=$(grep -E "info!|crate::metrics::|metrics::" -A 8 "$f" | tr 'A-Z' 'a-z')
    for k in $knobs; do
      stem=$(printf '%s' "$k" | sed 's/_ENV$//' | tr 'A-Z' 'a-z')
      if printf '%s' "$surface" | grep -q "$stem"; then
        :
      else
        found=$((found+1))
        drift "$m: $k is read but its value is published nowhere"
        echo "         Absent from the startup log's fields and from every metrics call."
        echo "         An operator cannot tell what the running process uses; the"
        echo "         Deployment spec is a different representation (#320)."
      fi
    done
  done
  [ "$found" -eq 0 ] && ok "every mirror-queue tuning knob publishes its value (log field or gauge)"
fi

# --------------------------------------------------------------- spec-env-currency
# noetl/ai-meta#241.  wiki-maintenance Rule 2a makes each component's
# deployment-specification page the source of truth for its env vars, and nothing
# forces that page to agree with the code.
#
# It has now drifted TWICE.  The August fix documented the eleven then-live vars;
# by 2026-09-04 twelve were live and undocumented again, ten of them differing
# from their default — so the page did not merely omit them, it implied the
# default was what runs.  Two had been added to prod *after* the fix, which
# confirms the mechanism: a flag ships, gets set, the page is not touched.
#
# ⚠ Only the vars that are BOTH read and SET ON PROD are reported as drift. The
# latent ones (read but set nowhere) are counted and printed, not failed — a
# check that reports 28 findings nobody will act on trains people to skim past
# the 12 that matter.  That lesson is from knob-observability's first draft,
# which cried wolf on 5 of 6.
if run spec-env-currency; then
  hdr "spec-env-currency — env vars live on prod but absent from the deployment spec (#241)"
  PAGE="$ROOT/repos/noetl-server-wiki/deployment-specification.md"
  if [ ! -f "$PAGE" ]; then
    skip "repos/noetl-server-wiki not checked out"
  elif [ ! -d "$ROOT/repos/server/src" ]; then
    skip "repos/server not checked out"
  elif ! command -v kubectl >/dev/null 2>&1; then
    skip "kubectl unavailable — the live half needs the cluster"
  else
    out=$(python3 - "$ROOT" <<'PYEOF'
import re, subprocess, sys, os, json
root = sys.argv[1]

def strip_test_modules(src):
    """Remove every `#[cfg(test)] mod ... { ... }` block, by brace matching.

    ⚠ Denominator discipline.  Without this the read-set counts names that exist
    only to prove a DEFAULT fires when the variable is absent — e.g.
    NOETL_TEST_ABSENT_CAPACITY_155.  Those are test fixtures, not deployment
    config; counting them inflates `read` and manufactures findings nobody
    should act on.

    Brace matching rather than a `NOETL_TEST_` prefix filter: the prefix is a
    naming convention, not a guarantee, and a fixture not following it would
    slip straight through.
    """
    out, i = [], 0
    while True:
        m = re.search(r"#\[cfg\(test\)\]\s*mod\s+\w+\s*\{", src[i:])
        if not m:
            out.append(src[i:]); break
        start = i + m.start()
        out.append(src[i:start])
        j, depth = i + m.end(), 1
        while j < len(src) and depth:
            if src[j] == "{": depth += 1
            elif src[j] == "}": depth -= 1
            j += 1
        i = j
    return "".join(out)

# ⚠ Denominator discipline (agents/rules/representation-drift.md): each component
# declares WHICH read idioms its scan covers, because a read-set that misses an
# idiom reports a false clean.  The server's August measurement missed `envy`
# and undercounted 152 as 56.
COMPONENTS = [
    # (repo, wiki, workloads, uses_envy_config_struct)
    ("repos/server", "repos/noetl-server-wiki",
     [("deploy", "noetl-server-rust")], True),
    ("repos/worker", "repos/noetl-worker-wiki",
     [("deploy", "noetl-worker-rust"), ("deploy", "noetl-worker-system-pool"),
      ("statefulset", "noetl-cmdbus-writer")], False),
]

for repo, wiki, workloads, uses_envy in COMPONENTS:
    rp, wp = os.path.join(root, repo), os.path.join(root, wiki)
    if not os.path.isdir(os.path.join(rp, "src")) or not os.path.isdir(wp):
        print("MISS|%s|not checked out" % repo); continue
    files = subprocess.run(["git","-C",rp,"ls-files","src/**/*.rs","src/*.rs"],
                           capture_output=True, text=True).stdout.split()
    src = "".join(open(os.path.join(rp,f), errors="ignore").read() for f in files)
    src = strip_test_modules(src)
    read = set(re.findall(r'"(NOETL_[A-Z0-9_]+)"', src))
    if uses_envy:
        # envy maps struct FIELDS to env names; no literal ever appears.
        try:
            cfg = open(os.path.join(rp,"src/config/app.rs")).read()
            body = cfg[cfg.index("pub struct AppConfig"):]
            body = body[:body.index("\n}")]
            read |= {"NOETL_"+f.upper() for f in re.findall(r"^\s*pub ([a-z0-9_]+)\s*:", body, re.M)}
        except Exception:
            print("MISS|%s|could not parse AppConfig for the envy field set" % repo); continue
    page = None
    for cand in ("deployment-specification.md",):
        fp = os.path.join(wp, cand)
        if os.path.exists(fp): page = open(fp).read()
    if page is None:
        print("MISS|%s|no deployment-specification.md" % repo); continue
    documented = set(re.findall(r"NOETL_[A-Z0-9_]+", page))
    envs = set()
    reachable = False
    for kind, name in workloads:
        try:
            j = subprocess.run(["kubectl","-n","noetl","get",kind,name,"-o","json"],
                               capture_output=True, text=True, timeout=40)
            if j.returncode != 0: continue
            envs |= {e["name"] for e in json.loads(j.stdout)["spec"]["template"]["spec"]["containers"][0].get("env",[])}
            reachable = True
        except Exception:
            continue
    if not reachable:
        print("MISS|%s|no workload reachable" % repo); continue
    live = sorted((read - documented) & envs)
    print("COUNTS|%s|%d|%d|%d|%d" % (repo, len(read), len(documented), len(envs),
                                     len(read - documented - envs)))
    for v in live:
        print("LIVE|%s|%s" % (repo, v))
PYEOF
)
    # ⚠ A crashed scan must not read as "no findings".  This check reported OK
    # through a Python NameError once; a guard that cannot fail is
    # indistinguishable from one that passes.  No COUNTS line == no measurement.
    if ! printf '%s' "$out" | grep -q '^COUNTS|'; then
      drift "spec-env-currency produced NO measurement — the scan itself failed"
      printf '%s' "$out" | head -12 | sed 's/^/           /'
    fi
    printf '%s' "$out" | sed -n 's/^MISS|/         skipped: /p'
    nlive=$(printf '%s' "$out" | grep -c '^LIVE|' || true)
    if [ "$nlive" -gt 0 ]; then
      drift "$nlive env var(s) are set on a prod workload and absent from its deployment spec"
      printf '%s' "$out" | awk -F'|' '/^LIVE\|/ {printf "           %-22s %s\n", $2, $3}'
      echo "         Rule 2a makes the page the source of truth; it is not."
    fi
    # Denominators, always — a finding count is only readable beside the population.
    printf '%s' "$out" | awk -F'|' '/^COUNTS\|/ {printf "         %-14s read=%s documented=%s set-on-prod=%s latent-undocumented=%s\n", $2, $3, $4, $5, $6}'
    if [ "$nlive" -eq 0 ] && printf '%s' "$out" | grep -q '^COUNTS|'; then
      ok "every env var set on a prod workload is documented"
    fi
  fi
fi

printf "\n"
if [ "$DRIFT" -gt 0 ]; then
  printf "\033[31m%d drift finding(s).\033[0m Each is a representation disagreeing with the system.\n" "$DRIFT"
  printf "Read the evidence before acting — several of these have a stale ISSUE as well as a stale artifact.\n"
else
  printf "\033[32mNo drift found by these checks.\033[0m\n"
fi
printf "These checks are not exhaustive: they cover the classes already SEEN.\n"
printf "Check 6 catches only the FULLY-ticked case.  Partially-ticked issues whose\n"
printf "work has shipped (#194, ehdb#241, #201, #223) still need the issue read\n"
printf "against the cluster — that part is judgement, not grep.\n"
exit 0
