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
    for pair in "server:ghcr.io/noetl/server" "worker:ghcr.io/noetl/worker"; do
      name="${pair%%:*}"; ref="${pair#*:}"
      tag=$(crane ls "$ref" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | tail -1)
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
    for f in $(cd "$d" && git ls-tree -r --name-only origin/main ci/manifests/noetl/ 2>/dev/null | grep -E '\.ya?ml$'); do
      # Deployment/StatefulSet metadata.name declared in this file
      names=$(cd "$d" && git show "origin/main:$f" 2>/dev/null | python3 -c '
import sys, yaml
try:
    for doc in yaml.safe_load_all(sys.stdin):
        if isinstance(doc, dict) and doc.get("kind") in ("Deployment","StatefulSet"):
            n=(doc.get("metadata") or {}).get("name")
            if n: print(n)
except Exception:
    pass' 2>/dev/null)
      for n in $names; do
        if ! printf '%s\n' "$live" | grep -qx "$n"; then
          # "Declared but not running" has THREE causes and only one is drift:
          #   dead legacy      — the Python-era server/worker (#97)
          #   gated feature    — deployed only when enabled (flightsql, subscription pool)
          #   kind-only fixture— never intended for prod (spool-downstream-echo)
          # A check that cannot tell them apart gets ignored, so this reports
          # the fact and names the question rather than asserting drift.
          drift "$f declares $n — not running in prod; is it dead legacy, a gated feature, or kind-only? (noetl/ai-meta#97)"
          missing=$((missing+1))
        fi
      done
    done
    if [ "$missing" -eq 0 ]; then
      ok "every declared Deployment/StatefulSet exists in prod"
    else
      echo "         NOTE: $missing declared workload(s) are not running. Confirmed DEAD so far:"
      echo "               server-deployment.yaml (image is the placeholder 'image_name:image_tag'),"
      echo "               worker-deployment.yaml — both Python-era, superseded by the -rust workloads."
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
  for r in worker server tools cli; do
    d="$ROOT/repos/$r"
    [ -d "$d" ] || continue
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
    ok "no orphaned test-shaped functions in worker/server/tools/cli"
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
    miss=$( (cd "$d" && git grep -ohE '(env::var(_os)?|env_[a-z0-9_]+)\(\s*"(NOETL|RUST)_[A-Z0-9_]*"' "$ref" -- src 2>/dev/null) \
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
    n=$(printf "$out" | grep -c . || true)
    if [ "${n:-0}" -eq 0 ]; then
      ok "$repo: every metric-mutating recorder in metrics.rs is called from src/"
    else
      drift "$repo: $n metric recorder(s) mutate a metric but have NO caller — what they set can never move"
      printf "$out" | head -10 | sed 's/^/         /'
      echo "         Confirm on a live pod: the metric is absent from /metrics while"
      echo "         its siblings are present.  Then check no ALERT records off it."
    fi
  done
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
