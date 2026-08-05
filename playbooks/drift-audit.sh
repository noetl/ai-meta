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

# ---------------------------------------------------------------------------
# 1. Manifests naming a project/registry the cluster does not use.
#    Found noetl/ai-meta#234: 8 files still pinning `noetl-demo-19700101`
#    after the migration to `shastaratech-noetl-prod`, including all three
#    prod deployment manifests.
# ---------------------------------------------------------------------------
if run manifests; then
  hdr "manifests: stale project / registry references"
  OLD_PROJECT="noetl-demo-19700101"
  if [ -d "$ROOT/repos/ops" ]; then
    n=$(cd "$ROOT/repos/ops" && git grep -l "$OLD_PROJECT" origin/main -- 'ci/' 'automation/' 2>/dev/null | wc -l | tr -d ' ')
    if [ "${n:-0}" -gt 0 ]; then
      drift "$n file(s) in repos/ops reference the pre-migration project '$OLD_PROJECT' (noetl/ai-meta#234)"
      (cd "$ROOT/repos/ops" && git grep -l "$OLD_PROJECT" origin/main -- 'ci/' 'automation/' 2>/dev/null | sed 's#origin/main:#         #')
    else
      ok "no references to '$OLD_PROJECT'"
    fi
  else
    skip "repos/ops not checked out"
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
    for n in $(gh issue list --repo noetl/ai-meta --state open --label ai-task \
                 --limit 60 --json number -q '.[].number' 2>/dev/null); do
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
