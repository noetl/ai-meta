#!/usr/bin/env bash
# Gate for ai-meta submodule pointer bumps.
#
# WHY THIS EXISTS: ai-meta had zero workflow files, so noetl/ai-meta#370 — five
# submodule pointer bumps — merged with no automated gate at all. A pointer is a
# 40-hex string and git validates nothing about it, so a typo or a bump to a
# never-pushed commit yields a repository that cannot be cloned. That is the failure
# class this checks for.
#
# Design notes:
#  * Only CHANGED pointers are examined on a PR, so the job stays fast.
#  * Fetches are TREELESS (--filter=blob:none): the full commit graph, no file
#    contents. Ancestry needs the graph; it does not need blobs.
#  * Deterministic and offline apart from the submodule remotes. No external actions.
#  * Prints its DENOMINATOR. A clean result over zero pointers reads exactly like a
#    clean result over five, and this repo has been bitten by that before.
#  * `mapfile` is avoided (bash 4+ only; macOS ships 3.2) so this runs locally too.
set -uo pipefail

COMPLETED=0
cleanup_work() { [ -n "${WORK:-}" ] && rm -rf "$WORK"; }
on_exit() {
  rc=$?
  cleanup_work
  # ⚠ An abort must FAIL, never pass silently. The first version of this script
  # printed unbound-variable errors and still exited 0 — a vacuous pass in the very
  # gate that exists to prevent vacuous passes.
  if [ "${COMPLETED}" -ne 1 ]; then
    printf '::error::pointer checker ABORTED before completing (rc=%s) — treating as FAILURE\n' "$rc"
    exit 1
  fi
  exit "$rc"
}
trap on_exit EXIT

BASE="${1:-}"      # base sha to diff against; empty => sweep ALL pointers
MODE="changed"; [ -z "$BASE" ] && MODE="sweep"
fail=0
examined=0
# Per-check tallies. Published at the end: a check that silently examined nothing
# reads identically to one that passed, so each check states how many pointers it
# actually reached. (An earlier harness grepped "on main" for this and undercounted
# the two wiki submodules, which track `master` — hence the script owning its counts.)
n_real=0
n_anc_ok=0
n_anc_skipped=0
n_ff_ok=0
n_ff_unprovable=0
n_no_access=0
n_warn_only=0
WARNINGS=()
FAILURES=()
PATHS=()

note()    { printf '  %s\n' "$*"; }
problem() { printf '::error::%s\n' "$*"; FAILURES+=("$*"); fail=1; }
# A finding that must NOT fail the job. Two cases need this, and conflating either
# with a real defect would make the gate cry wolf — which is worse than no gate:
#  * a pre-existing pointer this change did not touch (SWEEP mode), and
#  * third-party refs under references/, which we do not control.
warn()    { printf '::warning::%s\n' "$*"; WARNINGS+=("$*"); }
# In SWEEP mode (no BASE) nothing here was changed by the push, so legacy drift is
# reported, not blocking. Changed pointers are gated by the PR job and by the
# changed-pointer step that runs alongside this one.
report()  { case "$MODE" in sweep) warn "$@" ;; *) case "$1" in references/*) warn "$@" ;; *) problem "$@" ;; esac ;; esac; }
url_for() { git config -f .gitmodules --get "submodule.$1.url" 2>/dev/null; }

# The branch a submodule tracks: explicit `branch =`, else main, else master.
tracked_branch() {
  local path="$1" url="$2" b cand
  b="$(git config -f .gitmodules --get "submodule.${path}.branch" 2>/dev/null || true)"
  if [ -n "$b" ]; then printf '%s' "$b"; return; fi
  for cand in main master; do
    if git ls-remote --exit-code --heads "$url" "$cand" >/dev/null 2>&1; then
      printf '%s' "$cand"; return
    fi
  done
  printf '%s' ''
}

total_declared=$(git config -f .gitmodules --get-regexp '^submodule\..*\.path$' 2>/dev/null | wc -l | tr -d ' ')

if [ -n "$BASE" ]; then
  # A submodule path whose mode is no longer 160000 means a submodule was replaced by
  # a real file or directory — a corrupted tree, not a bump.
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    newmode="$(printf '%s' "$line" | awk '{print $2}')"
    path="$(printf '%s' "$line" | awk '{print $NF}')"
    if git config -f .gitmodules --get "submodule.${path}.url" >/dev/null 2>&1; then
      if [ "$newmode" != "160000" ] && [ "$newmode" != "000000" ]; then
        problem "${path}: submodule path changed to mode ${newmode} (expected 160000) — replaced by a file or directory"
      fi
    fi
  done < <(git diff --raw "${BASE}"..HEAD -- . 2>/dev/null)
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if git config -f .gitmodules --get "submodule.${p}.url" >/dev/null 2>&1; then PATHS+=("$p"); fi
  done < <(git diff --name-only "${BASE}"..HEAD -- . 2>/dev/null)
  note "mode: PR — examining pointers changed against ${BASE:0:12}"
else
  while IFS= read -r p; do
    [ -n "$p" ] && PATHS+=("$p")
  done < <(git config -f .gitmodules --get-regexp '^submodule\..*\.path$' | awk '{print $2}')
  note "mode: push — sweeping ALL declared pointers (no ancestry check without a base)"
fi

note "submodules declared in .gitmodules: ${total_declared}"
note "pointers to examine: ${#PATHS[@]}"

if [ "${#PATHS[@]}" -eq 0 ]; then
  note "no submodule pointers in scope — nothing to validate"
  COMPLETED=1
  echo "RESULT: pass (examined=0 of ${total_declared} declared)"
  echo "  no check executed — this pass measured nothing"
  exit 0
fi

WORK="$(mktemp -d)"

for path in "${PATHS[@]}"; do
  [ -z "$path" ] && continue
  new="$(git rev-parse "HEAD:${path}" 2>/dev/null || true)"
  if [ -z "$new" ]; then note "${path}: removed in this change — skipping"; continue; fi
  url="$(url_for "$path")"
  if [ -z "$url" ]; then problem "${path}: no url in .gitmodules"; continue; fi
  # The workflow checkout has no ssh key; read over https.
  furl="${url/git@github.com:/https://github.com/}"
  examined=$((examined+1))
  note ""
  note "── ${path}"
  note "   new pointer: ${new}"

  repo="${WORK}/${path//\//_}"
  git init -q --bare "$repo"

  # CHECK 0 — can CI reach this remote AT ALL? `noetl/noetl.io` is a PRIVATE repo, so
  # an unauthenticated runner cannot fetch any SHA from it, and the first version of
  # this gate reported that as "dangling, unpushed, or wrong SHA" — a confident wrong
  # cause. Proving access FIRST makes the CHECK 1 failure mean what it says.
  if ! git ls-remote --quiet --exit-code "$furl" HEAD >/dev/null 2>&1; then
    n_no_access=$((n_no_access+1))
    note "   ⚠ remote not reachable from CI (private, renamed, or no credentials) — pointer UNVERIFIABLE here, not a failure"
    continue
  fi

  # CHECK 1 — the pointer must name a commit FETCHABLE from the remote. A dangling or
  # never-pushed SHA fails here; that is the core bug class. Reached only when CHECK 0
  # has proved the remote is readable, so this cannot be an access artefact.
  fetched=0
  if git -C "$repo" fetch -q --filter=blob:none --no-tags "$furl" "$new" 2>/dev/null; then
    fetched=1
  else
    # A server may REFUSE to serve an arbitrary SHA even when the commit exists and is
    # public (`uploadpack.allowReachableSHA1InWant` disabled). Treating that refusal as
    # a dangling pointer is a false alarm, so fall back to fetching the refs and looking
    # the commit up. Only "absent from every ref" is a real defect.
    git -C "$repo" fetch -q --filter=blob:none --tags "$furl" '+refs/heads/*:refs/remotes/a/*' 2>/dev/null || true
    if git -C "$repo" cat-file -e "${new}^{commit}" 2>/dev/null; then
      fetched=1
      note "   (direct SHA fetch refused by the server; resolved via refs instead)"
    fi
  fi
  if [ "$fetched" -ne 1 ]; then
    report "${path}: pointer ${new} is reachable from NO ref on ${url} — dangling, unpushed, or wrong SHA"
    continue
  fi
  if ! git -C "$repo" cat-file -e "${new}^{commit}" 2>/dev/null; then
    report "${path}: ${new} fetched but is not a commit object"
    continue
  fi
  n_real=$((n_real+1))
  note "   ✓ resolves and is a commit"

  branch="$(tracked_branch "$path" "$furl")"
  if [ -z "$branch" ]; then
    n_anc_skipped=$((n_anc_skipped+1))
    note "   ⚠ no main/master on the remote — ancestry checks skipped (no tip to compare)"
    continue
  fi
  git -C "$repo" fetch -q --filter=blob:none --no-tags "$furl" "+refs/heads/${branch}:refs/remotes/t/${branch}" 2>/dev/null || true
  tip="$(git -C "$repo" rev-parse "refs/remotes/t/${branch}" 2>/dev/null || true)"

  # CHECK 2 — the pointer should sit on the tracked branch's history: already merged
  # (ancestor of tip) or ahead of it (tip is its ancestor). Neither means a DETACHED
  # bump onto a side branch that may never merge, so a future clone resolves to code
  # nobody ships.
  if [ -n "$tip" ]; then
    if git -C "$repo" merge-base --is-ancestor "$new" "$tip" 2>/dev/null; then
      n_anc_ok=$((n_anc_ok+1))
      note "   ✓ on ${branch} (ancestor of tip ${tip:0:12})"
    elif git -C "$repo" merge-base --is-ancestor "$tip" "$new" 2>/dev/null; then
      n_anc_ok=$((n_anc_ok+1))
      note "   ✓ ahead of ${branch} tip ${tip:0:12} (not yet merged — allowed)"
    else
      report "${path}: ${new} is NEITHER an ancestor NOR a descendant of ${branch} tip ${tip:0:12} — detached bump onto a side branch"
    fi
  else
    n_anc_skipped=$((n_anc_skipped+1))
    note "   ⚠ could not read ${branch} tip — ancestry unverified"
  fi

  # CHECK 3 — a bump must not REGRESS or rewrite the submodule.
  if [ -n "$BASE" ]; then
    old="$(git rev-parse "${BASE}:${path}" 2>/dev/null || true)"
    if [ -n "$old" ] && [ "$old" != "$new" ]; then
      git -C "$repo" fetch -q --filter=blob:none --no-tags "$furl" "$old" 2>/dev/null || true
      if git -C "$repo" cat-file -e "${old}^{commit}" 2>/dev/null; then
        if git -C "$repo" merge-base --is-ancestor "$old" "$new" 2>/dev/null; then
          n_ff_ok=$((n_ff_ok+1))
          note "   ✓ fast-forward from ${old:0:12}"
        else
          report "${path}: ${old:0:12} -> ${new:0:12} is NOT a fast-forward — this REGRESSES or rewrites the submodule"
        fi
      else
        n_ff_unprovable=$((n_ff_unprovable+1))
        note "   ⚠ old pointer ${old:0:12} not fetchable; fast-forward unprovable (pre-existing, not this change)"
      fi
    fi
  fi
done

COMPLETED=1
echo ""
echo "RESULT: $([ "$fail" -eq 0 ] && echo pass || echo FAIL) (examined=${examined} of ${total_declared} declared, ${#FAILURES[@]} problem(s))"
# Each check reports the population it reached. A pass over examined=0 is a pass that
# measured nothing, and it must be readable as such from this line alone.
echo "  check 1 fetchable+is-commit : ${n_real}/${examined} confirmed"
echo "  check 2 ancestry vs tip     : ${n_anc_ok}/${examined} confirmed, ${n_anc_skipped} skipped (no tip)"
echo "  check 3 fast-forward        : ${n_ff_ok}/${examined} confirmed, ${n_ff_unprovable} unprovable (old pointer gone)"
echo "  unverifiable (no CI access) : ${n_no_access}  <- NOT counted as pass or fail"
echo "  mode                        : ${MODE} ($([ "$MODE" = sweep ] && echo 'legacy drift reported, non-blocking' || echo 'changed pointers, BLOCKING'))"
if [ "${#WARNINGS[@]}" -gt 0 ]; then
  echo "  warnings (non-blocking): ${#WARNINGS[@]}"
  for w in ${WARNINGS[@]+"${WARNINGS[@]}"}; do echo "  ~ $w"; done
fi
for f in ${FAILURES[@]+"${FAILURES[@]}"}; do echo "  - $f"; done
exit "$fail"
