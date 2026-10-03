#!/usr/bin/env bash
# Docs sweep over the WIKI submodules (noetl/ai-meta#375).
#
# WHY THIS LIVES HERE: a `*.wiki.git` repository cannot host GitHub Actions. There
# is no runner, so "add CI to the wikis" is not achievable as stated. The closest
# available thing is this: ai-meta clones each wiki and runs the same checks it runs
# on its own markdown. Same rules, one day late instead of pre-merge.
#
# WHAT IT CHECKS: exactly what .github/scripts/check-docs.sh checks — balanced code
# fences, and relative links that resolve. Bare page names are exempt there, which
# matters here: wiki inter-page links are slugs, not paths, and flagging them would
# make this red on arrival.
#
# IT CHECKS THE LIVE WIKI, NOT THE SUBMODULE POINTER. The whole point is to notice a
# wiki that is broken right now; a pointer can be months behind. So it clones each
# wiki's current default branch rather than using `git submodule update`.
#
# The wiki list is DERIVED from .gitmodules, never enumerated: an enumerated list is
# a representation that drifts the moment a wiki is added, and a sweep that silently
# stops covering half the fleet reports the same green as a healthy one.
#
# The clone is anonymous HTTPS (the declared URLs are SSH, which a runner has no key
# for). These are public wikis; no token is required or used.
set -uo pipefail

COMPLETED=0
WORK=""
# ONE exit handler, installed once.  `rc=$?` must be the FIRST statement so it
# captures the script's status -- an earlier version chained
# `trap 'cleanup; on_exit' EXIT`, which made $? the status of `cleanup` (always 0).
# The sweep then printed "RESULT: FAIL" and exited 0, i.e. a gate that reports a
# failure and reads green, because CI looks at the exit code and not the text.
# Caught only because a control asserted the exit code rather than the output.
on_exit() {
  rc=$?
  [ -n "${WORK}" ] && rm -rf "${WORK}"
  if [ "${COMPLETED}" -ne 1 ]; then
    printf '::error::wiki sweep ABORTED before completing (rc=%s) -- treating as FAILURE\n' "$rc"
    exit 1
  fi
  exit "$rc"
}
trap on_exit EXIT

# A sweep that found no wikis to check must be red, not green. 10 is below the
# current 15 so adding or retiring one does not trip it, while a broken .gitmodules
# parse or a bad checkout does.
MIN_WIKIS=10

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECKER="${REPO_ROOT}/.github/scripts/check-docs.sh"
if [ ! -x "$CHECKER" ]; then
  printf '::error::%s is missing or not executable -- nothing to run\n' "$CHECKER"
  exit 1
fi

WORK="$(mktemp -d)"

echo "wiki docs sweep -- deriving the wiki list from .gitmodules"

# path<TAB>https-url for every submodule whose url ends in .wiki.git
MAP="$(python3 - "$REPO_ROOT/.gitmodules" <<'PY'
import re, sys
txt = open(sys.argv[1], encoding="utf-8").read()
pat = re.compile(r'\[submodule "[^"]+"\]\s*\n\s*path\s*=\s*(\S+)\s*\n\s*url\s*=\s*(\S+)')
for path, url in pat.findall(txt):
    if not url.endswith(".wiki.git"):
        continue
    https = re.sub(r"^git@github\.com:", "https://github.com/", url)
    print(f"{path}\t{https}")
PY
)"

declared=$(printf '%s\n' "$MAP" | grep -c . || true)
echo "  wikis declared in .gitmodules: ${declared}   <- the denominator"

checked=0
unreachable=0
total_md=0
total_links=0
fail=0
FAILED_WIKIS=()

while IFS=$'\t' read -r path url; do
  [ -z "${path:-}" ] && continue
  name="$(basename "$path")"
  dest="${WORK}/${name}"
  echo ""
  echo "── ${name}  (${url})"
  if ! GIT_TERMINAL_PROMPT=0 git clone -q --depth 1 "$url" "$dest" 2>/dev/null; then
    # An empty wiki (never initialised) is not a defect; an unreachable one we
    # cannot distinguish from it here, so report and count rather than failing.
    echo "   ! could not clone (wiki may be empty or private) -- not counted as checked"
    unreachable=$((unreachable + 1))
    continue
  fi
  checked=$((checked + 1))
  out="$(cd "$dest" && "$CHECKER" 2>&1)"
  rc=$?
  md=$(printf '%s' "$out" | sed -n 's/.*in scope: \([0-9]*\).*/\1/p' | head -1)
  lk=$(printf '%s' "$out" | sed -n 's/.*relative links checked: \([0-9]*\).*/\1/p' | head -1)
  total_md=$((total_md + ${md:-0}))
  total_links=$((total_links + ${lk:-0}))
  printf '   markdown %s, relative links %s\n' "${md:-0}" "${lk:-0}"
  if [ "$rc" -ne 0 ]; then
    fail=1
    FAILED_WIKIS+=("$name")
    printf '%s\n' "$out" | grep '^::error' | while IFS= read -r line; do
      # re-emit with the wiki name so the annotation is actionable
      printf '::error::%s: %s\n' "$name" "${line#::error*::}"
    done
    printf '%s\n' "$out" | grep -E '^  - ' | sed 's/^/     /'
  else
    echo "   ✓ clean"
  fi
done <<< "$MAP"

echo ""
echo "────────────────────────────────────────────────────────────"
echo "  wikis declared:  ${declared}"
echo "  wikis checked:   ${checked}"
echo "  not cloneable:   ${unreachable}"
echo "  markdown files:  ${total_md}"
echo "  relative links:  ${total_links}"

if [ "$checked" -lt "$MIN_WIKIS" ]; then
  printf '::error::only %s wikis were checked, below the floor of %s -- the sweep did not look at what it claims to cover, so a clean result here would mean nothing\n' "$checked" "$MIN_WIKIS"
  fail=1
fi
if [ "$total_md" -eq 0 ]; then
  printf '::error::0 markdown files examined across %s wikis -- the checker produced no population, so its clean result is vacuous\n' "$checked"
  fail=1
fi

COMPLETED=1
if [ "$fail" -ne 0 ]; then
  echo "RESULT: FAIL${FAILED_WIKIS[0]+ -- wikis with findings: ${FAILED_WIKIS[*]}}"
  exit 1
fi
echo "RESULT: pass"
exit 0
