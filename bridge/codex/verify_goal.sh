#!/usr/bin/env bash
# Run the verify_shell from a goal-directed task and check whether
# the success_pattern matches. Codex calls this after each iteration.
#
# Usage:
#   ./bridge/codex/verify_goal.sh <task.json>
#
# Exits 0 if success_pattern matched, 1 otherwise.

set -euo pipefail

TASK_FILE="${1:?usage: verify_goal.sh <task.json>}"

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required for goal-directed verification" >&2
  exit 2
fi

verify_shell=$(jq -r '.expected_state.verify_shell // empty' "$TASK_FILE")
success_pattern=$(jq -r '.expected_state.success_pattern // empty' "$TASK_FILE")

if [ -z "$verify_shell" ] || [ -z "$success_pattern" ]; then
  echo "ERROR: task missing expected_state.verify_shell or .success_pattern" >&2
  exit 2
fi

echo "==> verify_shell:"
echo "    $verify_shell"
echo

# Run the verify shell, capture output
out_f=$(mktemp); err_f=$(mktemp)
set +e
bash -c "$verify_shell" >"$out_f" 2>"$err_f"
rc=$?
set -e

echo "==> stdout (rc=$rc):"
cat "$out_f"
[ -s "$err_f" ] && { echo "==> stderr:"; cat "$err_f"; }

if grep -qE "$success_pattern" "$out_f"; then
  echo
  echo "MATCH: success_pattern matched. Goal is reached."
  rm -f "$out_f" "$err_f"
  exit 0
else
  echo
  echo "NO MATCH: success_pattern '$success_pattern' did not appear in output."
  rm -f "$out_f" "$err_f"
  exit 1
fi
