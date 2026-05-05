#!/usr/bin/env bash
# Goal-directed task handler. The watcher's handle_task.sh only runs
# tasks of `kind: procedural` (the default). For `kind: "goal-directed"`,
# the watcher should hand off to *Codex itself* — let Codex's
# intelligence orchestrate iterations against the cluster.
#
# This wrapper:
#   1. Reads the goal task
#   2. Prints it for the user / Codex session
#   3. Codex (running in the same terminal or piped) takes over and
#      iterates until expected_state is reached
#   4. Codex writes the result file when done
#
# Usage:
#   ./bridge/codex/handle_goal_task.sh <task.json>
#
# This script doesn't *execute* the task — it formats it for Codex
# consumption + provides the verify_shell helper Codex can call after
# each iteration.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bridge_lib.sh
source "$SCRIPT_DIR/bridge_lib.sh"

TASK_FILE="${1:?usage: handle_goal_task.sh <task.json>}"
[ -f "$TASK_FILE" ] || { log "ERROR: not found: $TASK_FILE"; exit 1; }

ID="$(task_field "$TASK_FILE" id)"
TITLE="$(task_field "$TASK_FILE" title)"

cat <<EOF

============================================================
GOAL-DIRECTED TASK FROM CLAUDE
============================================================
ID:     $ID
Title:  $TITLE
File:   $TASK_FILE

This task asks YOU (Codex) to iterate until the expected state is
reached. Read the task file in full, then drive the cluster toward
the goal using the tools listed in 'preferred_tools'. After each
significant action, run the verify_shell and check whether
success_pattern matches.

When you're done (success OR max_iterations exhausted), write the
result file:

  bridge/outbox/${ID}.result.json

with this shape:

  {
    "id": "${ID}",
    "from": "codex",
    "to": "claude-cowork",
    "completed_at": "<UTC ISO timestamp>",
    "approval_status": "approved",
    "approved_by": "${USER:-unknown}",
    "overall_status": "ok" | "max_iterations_exceeded" | "failed",
    "iterations": [
      {
        "n": 1,
        "action_summary": "<what you tried>",
        "commands_run": ["..."],
        "verify_output": "<output of verify_shell>",
        "matched_success_pattern": false
      },
      ...
    ],
    "final_state": "<one-paragraph summary of where the cluster ended up>"
  }

The full task spec follows. Read it carefully:

============================================================
EOF

cat "$TASK_FILE"

echo
echo "============================================================"
echo "VERIFY HELPER"
echo "============================================================"
echo "After each iteration, run:"
echo
echo "  $SCRIPT_DIR/verify_goal.sh $TASK_FILE"
echo
echo "It executes verify_shell and prints whether success_pattern"
echo "matched. Use this to decide whether to keep iterating or hand"
echo "back to Claude."
echo
echo "ARCHIVE WHEN DONE"
echo "============================================================"
echo "After writing the result file, archive both files:"
echo
echo "  mv $TASK_FILE $BRIDGE_ARCHIVE/"
echo "  cp $BRIDGE_OUTBOX/${ID}.result.json $BRIDGE_ARCHIVE/"
echo
