#!/usr/bin/env bash
# Docs sanity gate for ai-meta.
#
# SCOPE IS DELIBERATELY NARROW — changed markdown only, two deterministic checks:
#   1. relative links resolve to a file that exists;
#   2. code fences are balanced.
#
# WHY NOT A FULL MARKDOWN LINTER: this repo holds thousands of markdown files,
# including years of memory archives written to no single style. A strict linter over
# all of them would fail on arrival, and a gate that is red on day one teaches people
# to ignore it — the same reason a red baseline makes every mutant in a mutation
# battery read as "caught". So: changed files only, and only rules whose violation is
# unambiguously a defect.
#
# WHY NO EXTERNAL LINK CHECKING: network-dependent, therefore flaky by nature. A gate
# that fails because a third-party site is slow is worse than no gate.
set -uo pipefail

COMPLETED=0
on_exit() {
  rc=$?
  if [ "${COMPLETED}" -ne 1 ]; then
    printf '::error::docs checker ABORTED before completing (rc=%s) — treating as FAILURE\n' "$rc"
    exit 1
  fi
  exit "$rc"
}
trap on_exit EXIT

BASE="${1:-}"
fail=0
FAILURES=()
FILES=()
problem() { printf '::error file=%s::%s\n' "$1" "$2"; FAILURES+=("$1: $2"); fail=1; }

if [ -n "$BASE" ] && git rev-parse --verify -q "$BASE" >/dev/null 2>&1; then
  while IFS= read -r f; do [ -n "$f" ] && FILES+=("$f"); done \
    < <(git diff --name-only --diff-filter=ACMR "${BASE}"..HEAD -- '*.md' 2>/dev/null)
  echo "  mode: markdown changed against ${BASE:0:12}"
else
  while IFS= read -r f; do [ -n "$f" ] && FILES+=("$f"); done < <(git ls-files '*.md')
  echo "  mode: all tracked markdown (no usable base)"
fi

echo "  markdown files in scope: ${#FILES[@]}   <- the denominator"
if [ "${#FILES[@]}" -eq 0 ]; then
  COMPLETED=1
  echo "RESULT: pass (no markdown changed)"
  exit 0
fi

links_checked=0
for f in "${FILES[@]}"; do
  [ -f "$f" ] || continue

  fences=$(grep -c '^[[:space:]]*```' "$f" 2>/dev/null || true)
  if [ $(( ${fences:-0} % 2 )) -ne 0 ]; then
    problem "$f" "odd number of code-fence markers (${fences}) — an unclosed fence swallows the rest of the document"
  fi

  while IFS= read -r target; do
    [ -z "$target" ] && continue
    case "$target" in
      http*|mailto:*|\#*|'<'*|*REPLACE*|*'{{'*) continue ;;
    esac
    links_checked=$((links_checked+1))
    base="${target%%#*}"
    [ -z "$base" ] && continue
    cand="$(dirname "$f")/${base}"
    if [ ! -e "$cand" ] && [ ! -e "$base" ]; then
      # A bare page name with no slash/extension is a legitimate inter-wiki link in
      # this repo's conventions; only flag targets that look like real paths.
      case "$base" in
        */*|*.md|*.sh|*.yaml|*.yml|*.toml|*.rs|*.py)
          problem "$f" "broken relative link -> ${target} (resolved to ${cand})" ;;
      esac
    fi
  done < <(grep -oE '\]\([^)]+\)' "$f" 2>/dev/null | sed 's/^](//; s/)$//')
done

COMPLETED=1
echo ""
echo "  relative links checked: ${links_checked}"
echo "RESULT: $([ "$fail" -eq 0 ] && echo pass || echo FAIL) (files=${#FILES[@]}, links=${links_checked}, ${#FAILURES[@]} problem(s))"
for f in ${FAILURES[@]+"${FAILURES[@]}"}; do echo "  - $f"; done
exit "$fail"
