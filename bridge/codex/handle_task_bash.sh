#!/usr/bin/env bash
# Bash-fallback executor for the bridge — runs commands directly via
# `bash -c` without involving noetl. Used only as a bootstrap recovery
# path when the noetl CLI itself is broken (chicken-and-egg scenarios:
# you need to fix noetl, but you can't run a noetl-backed bridge task
# to fix it because noetl is broken).
#
# Activated when a `.task.json` file has top-level `"executor": "bash"`.
#
# Usage: handle_task_bash.sh <task.json> <approval-status>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bridge_lib.sh
source "$SCRIPT_DIR/bridge_lib.sh"

TASK_FILE="${1:?usage: handle_task_bash.sh <task.json> <approval>}"
APPROVAL="${2:-approved}"

ID="$(task_field "$TASK_FILE" id)"
[ -n "$ID" ] || { log "ERROR: bash-fallback task missing id: $TASK_FILE"; exit 1; }

if ! command -v jq >/dev/null 2>&1; then
  log "ERROR: jq is required for bash-fallback executor"
  exit 1
fi

cmd_count=$(jq '.commands | length' "$TASK_FILE")
results_json="["
overall="ok"

for ((i=0; i<cmd_count; i++)); do
  step_id=$(jq -r ".commands[$i].id // \"step-$i\"" "$TASK_FILE")
  cmd=$(jq -r ".commands[$i].shell" "$TASK_FILE")

  log "  RUN [$step_id] (bash): $cmd"
  start=$(date +%s)

  out_f=$(mktemp); err_f=$(mktemp)
  set +e
  bash -c "$cmd" >"$out_f" 2>"$err_f"
  rc=$?
  set -e
  end=$(date +%s)
  dur=$((end - start))

  step_result=$(jq -n \
    --arg id "$step_id" \
    --argjson rc "$rc" \
    --argjson dur "$dur" \
    --rawfile out "$out_f" \
    --rawfile err "$err_f" \
    '{step_id: $id, exit_code: $rc, duration_seconds: $dur, stdout: $out, stderr: $err}')

  if [ "$i" -gt 0 ]; then results_json="$results_json,"; fi
  results_json="$results_json$step_result"

  log "  RESULT [$step_id]: rc=$rc duration=${dur}s"
  rm -f "$out_f" "$err_f"

  if [ "$rc" -ne 0 ]; then
    overall="failed"
    log "  -> step failed; stopping further commands"
    break
  fi
done

results_json="$results_json]"

# Match the result envelope shape used by the noetl-mode executors
jq -n \
  --arg id "$ID" \
  --arg user "${USER:-unknown}" \
  --arg approval "$APPROVAL" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg overall "$overall" \
  --argjson results "$results_json" \
  '{id: $id, from: "codex", to: "claude-cowork", completed_at: $ts,
    approval_status: $approval, approved_by: $user,
    overall_status: $overall,
    executor: "bash-fallback",
    results: $results}' \
  > "$BRIDGE_OUTBOX/${ID}.result.json"

log "WROTE (bash): $BRIDGE_OUTBOX/${ID}.result.json overall=$overall"
