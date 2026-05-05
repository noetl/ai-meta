#!/usr/bin/env bash
# Process a single bridge task file.
#
# Task formats supported (auto-detected by file extension + content):
#
#   1. `{id}.task.yaml` — file IS a noetl playbook, run via:
#         noetl exec --runtime local <file> --json
#      The playbook's return envelope becomes the bridge result.
#
#   2. `{id}.task.json` with top-level `playbook` (file path or
#      catalog ref; `playbook_path` accepted as legacy alias) —
#         noetl exec --runtime local <playbook> --payload <workload> --json
#      For local runtime, file paths resolve directly with no
#      catalog registration needed. Use repo-relative paths like
#      `repos/ops/automation/agents/bridge/run_commands.yaml`.
#
#   3. `{id}.task.json` with top-level `commands` (bare list) —
#      Wrapped through repos/ops/automation/agents/bridge/run_commands.yaml.
#      This is the legacy v0 format; still works.
#
#   4. `{id}.task.json` with top-level `executor: "bash"` —
#      Bootstrap fallback: runs commands via raw `bash -c` without
#      involving noetl. Use this only when the noetl CLI itself is
#      broken (chicken-and-egg recovery scenario).
#
# All formats: respect `approval` ("required" / "auto" / "denied"),
# enforce the denylist before approval, write a result envelope to
# bridge/outbox/{id}.result.json.
#
# Usage:
#   handle_task.sh <path-to-task.{yaml,json}>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bridge_lib.sh
source "$SCRIPT_DIR/bridge_lib.sh"

TASK_FILE="${1:?usage: handle_task.sh <task.{yaml,json}>}"
[ -f "$TASK_FILE" ] || { log "ERROR: task file not found: $TASK_FILE"; exit 1; }

# ---------------------------------------------------------------------------
# Detect format + extract id
# ---------------------------------------------------------------------------

ext="${TASK_FILE##*.}"
case "$ext" in
  yaml|yml) FORMAT="yaml" ;;
  json)     FORMAT="json" ;;
  *)
    log "ERROR: unsupported extension '.$ext' on $TASK_FILE (expected .yaml or .json)"
    exit 1
    ;;
esac

ID=""
APPROVAL_MODE="required"
EXECUTOR="noetl"  # default executor mode

if [ "$FORMAT" = "yaml" ]; then
  # For yaml tasks, the playbook IS the task. id is derived from
  # the filename (basename minus `.task.yaml`).
  base="$(basename "$TASK_FILE")"
  ID="${base%.task.yaml}"
  ID="${ID%.task.yml}"
  EXECUTOR="noetl-yaml"
  # Approval defaults to required for yaml tasks (they're free-form
  # playbooks; can do anything). Operator can pre-approve a class
  # by adding a `# bridge-approval: auto` comment line at the top.
  if head -10 "$TASK_FILE" | grep -qE '^#\s*bridge-approval:\s*auto'; then
    APPROVAL_MODE="auto"
  fi
elif [ "$FORMAT" = "json" ]; then
  ID="$(task_field "$TASK_FILE" id)"
  APPROVAL_MODE="$(task_field "$TASK_FILE" approval)"
  APPROVAL_MODE="${APPROVAL_MODE:-required}"

  if command -v jq >/dev/null 2>&1; then
    json_executor=$(jq -r '.executor // ""' "$TASK_FILE")
    # Accept either `playbook` (canonical, works for any ref noetl
    # exec accepts: file path, catalog path, catalog:// URI) or the
    # legacy `playbook_path` alias. Local runtime resolves file paths
    # directly without catalog registration; distributed runtime can
    # resolve catalog refs via the server.
    json_playbook=$(jq -r '.playbook // .playbook_path // ""' "$TASK_FILE")
    json_has_commands=$(jq -e '.commands' "$TASK_FILE" >/dev/null 2>&1 && echo true || echo false)
    if [ "$json_executor" = "bash" ]; then
      EXECUTOR="bash"
    elif [ -n "$json_playbook" ]; then
      EXECUTOR="noetl-json-playbook"
    elif [ "$json_has_commands" = "true" ]; then
      EXECUTOR="noetl-json-commands"
    else
      log "ERROR: $TASK_FILE has no playbook reference and no commands"
      exit 1
    fi
  else
    log "ERROR: jq is required to parse .task.json files"
    exit 1
  fi
fi

[ -n "$ID" ] || { log "ERROR: couldn't derive id from $TASK_FILE"; exit 1; }

# Skip if already processed (restart-safe)
if [ -f "$BRIDGE_OUTBOX/${ID}.result.json" ]; then
  log "SKIP (already processed): $ID"
  exit 0
fi

TITLE="$(task_field "$TASK_FILE" title 2>/dev/null || echo "")"
log "TASK: id=$ID format=$FORMAT executor=$EXECUTOR approval=$APPROVAL_MODE title='$TITLE'"

# ---------------------------------------------------------------------------
# Pre-flight denylist check
# ---------------------------------------------------------------------------

scan_denylist() {
  # For YAML tasks, scan the whole file for `shell:` and `cmd:` lines.
  # For JSON tasks with commands, walk the commands array.
  local f="$1" fmt="$2"
  case "$fmt" in
    yaml)
      grep -E '^\s*(shell|cmd):' "$f" | while read -r line; do
        cmd="${line#*:}"
        if ! is_command_safe "$cmd"; then
          return 1
        fi
      done
      ;;
    json)
      if command -v jq >/dev/null 2>&1 && jq -e '.commands' "$f" >/dev/null 2>&1; then
        local n
        n=$(jq '.commands | length' "$f")
        for ((i=0; i<n; i++)); do
          local cmd
          cmd=$(jq -r ".commands[$i].shell // \"\"" "$f")
          if ! is_command_safe "$cmd"; then
            return 1
          fi
        done
      fi
      ;;
  esac
  return 0
}

if ! scan_denylist "$TASK_FILE" "$FORMAT"; then
  log "PRE-FLIGHT DENY: $ID has a command matching the denylist"
  write_result "$ID" "denied" "denied" \
    '[{"step_id": "pre-flight", "exit_code": 1, "error": "command matched denylist"}]'
  mv "$TASK_FILE" "$BRIDGE_ARCHIVE/" 2>/dev/null || true
  cp "$BRIDGE_OUTBOX/${ID}.result.json" "$BRIDGE_ARCHIVE/" 2>/dev/null || true
  exit 0
fi

# ---------------------------------------------------------------------------
# Approval gate
# ---------------------------------------------------------------------------

APPROVAL=$(prompt_approval "$TASK_FILE" "$APPROVAL_MODE")
log "APPROVAL: $ID -> $APPROVAL"

if [ "$APPROVAL" = "denied" ]; then
  write_result "$ID" "denied" "denied" "[]"
  mv "$TASK_FILE" "$BRIDGE_ARCHIVE/" 2>/dev/null || true
  cp "$BRIDGE_OUTBOX/${ID}.result.json" "$BRIDGE_ARCHIVE/" 2>/dev/null || true
  exit 0
fi
if [ "$APPROVAL" = "skipped" ]; then
  log "SKIP: $ID without writing a result"
  mv "$TASK_FILE" "$BRIDGE_ARCHIVE/" 2>/dev/null || true
  exit 0
fi

# ---------------------------------------------------------------------------
# Dispatch to the right executor
# ---------------------------------------------------------------------------

# All noetl-mode dispatches go through this helper. Captures the
# JSON envelope from `noetl exec --json` and turns it into the
# bridge's result.json shape.
run_noetl_local() {
  local target="$1" payload_arg="${2:-}"
  local out_f err_f rc
  out_f=$(mktemp); err_f=$(mktemp)

  local cmd=(noetl exec "$target" --runtime local --json)
  if [ -n "$payload_arg" ]; then
    cmd+=(--payload "$payload_arg")
  fi

  log "  RUN: ${cmd[*]}"
  set +e
  "${cmd[@]}" >"$out_f" 2>"$err_f"
  rc=$?
  set -e

  if [ "$rc" -eq 0 ] && [ -s "$out_f" ]; then
    # The noetl envelope IS our result data. Wrap with bridge metadata.
    if command -v jq >/dev/null 2>&1; then
      jq -n \
        --arg id "$ID" \
        --arg user "${USER:-unknown}" \
        --arg approval "$APPROVAL" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --slurpfile env "$out_f" \
        '{id: $id, from: "codex", to: "claude-cowork", completed_at: $ts,
          approval_status: $approval, approved_by: $user,
          overall_status: "ok",
          executor: "noetl-local",
          envelope: $env[0]}' \
        > "$BRIDGE_OUTBOX/${ID}.result.json"
      overall="ok"
    else
      cp "$out_f" "$BRIDGE_OUTBOX/${ID}.result.json"
      overall="ok"
    fi
  else
    overall="failed"
    if command -v jq >/dev/null 2>&1; then
      jq -n \
        --arg id "$ID" \
        --arg user "${USER:-unknown}" \
        --arg approval "$APPROVAL" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --argjson rc "$rc" \
        --rawfile stdout "$out_f" \
        --rawfile stderr "$err_f" \
        '{id: $id, from: "codex", to: "claude-cowork", completed_at: $ts,
          approval_status: $approval, approved_by: $user,
          overall_status: "failed",
          executor: "noetl-local",
          exit_code: $rc,
          stdout: $stdout, stderr: $stderr}' \
        > "$BRIDGE_OUTBOX/${ID}.result.json"
    fi
  fi

  rm -f "$out_f" "$err_f"
  log "  noetl exit=$rc overall=$overall"
}

# Bash fallback executor (legacy v0 path) — used when explicitly
# requested via `executor: bash` in the task. The full implementation
# lives in handle_task_bash.sh to keep this dispatcher readable.
run_bash_executor() {
  "$SCRIPT_DIR/handle_task_bash.sh" "$TASK_FILE" "$APPROVAL"
}

case "$EXECUTOR" in
  noetl-yaml)
    # The YAML file IS the playbook
    run_noetl_local "$TASK_FILE"
    ;;
  noetl-json-playbook)
    # JSON envelope with playbook (file path or catalog ref) + workload.
    # Local runtime resolves file paths directly (no catalog needed);
    # catalog refs work too when noetl is configured to resolve them.
    if command -v jq >/dev/null 2>&1; then
      pb_ref=$(jq -r '.playbook // .playbook_path' "$TASK_FILE")
      payload=$(jq -c '.workload // {}' "$TASK_FILE")
      run_noetl_local "$pb_ref" "$payload"
    else
      log "ERROR: jq required for noetl-json-playbook executor"
      exit 1
    fi
    ;;
  noetl-json-commands)
    # Bare {commands: [...]} — wrap through the bridge run_commands
    # playbook on disk. Path is repo-relative; the watcher's CWD when
    # invoked is the ai-meta root (per the run-watcher instructions).
    if command -v jq >/dev/null 2>&1; then
      payload=$(jq -c '{commands: .commands, stop_on_error: (.stop_on_error // true)}' "$TASK_FILE")
      run_noetl_local "$BRIDGE_ROOT/../repos/ops/automation/agents/bridge/run_commands.yaml" "$payload"
    fi
    ;;
  bash)
    run_bash_executor
    ;;
  *)
    log "ERROR: unknown executor '$EXECUTOR'"
    exit 1
    ;;
esac

# ---------------------------------------------------------------------------
# Archive
# ---------------------------------------------------------------------------

mv "$TASK_FILE" "$BRIDGE_ARCHIVE/" 2>/dev/null || true
cp "$BRIDGE_OUTBOX/${ID}.result.json" "$BRIDGE_ARCHIVE/" 2>/dev/null || true

log "DONE: $ID"
