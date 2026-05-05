#!/usr/bin/env bash
# Shared helpers for the bridge watcher + task handler.
# Source this — don't run directly.

set -euo pipefail

BRIDGE_ROOT="${BRIDGE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
BRIDGE_INBOX="$BRIDGE_ROOT/inbox"
BRIDGE_OUTBOX="$BRIDGE_ROOT/outbox"
BRIDGE_ARCHIVE="$BRIDGE_ROOT/archive"
BRIDGE_LOG="$BRIDGE_ROOT/codex/watcher.log"

mkdir -p "$BRIDGE_INBOX" "$BRIDGE_OUTBOX" "$BRIDGE_ARCHIVE"

log() {
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '[%s] %s\n' "$ts" "$*" | tee -a "$BRIDGE_LOG"
}

# Pretty-print a task file to stdout for the approval prompt.
#
# Detects format by extension + jq availability:
# - JSON files (.json or detected by leading `{`/`[`) get jq's
#   syntax-coloured pretty-print.
# - YAML files just get `cat` — they're already human-readable, and
#   running jq against them fails with a parse error that pollutes
#   the approval prompt.
pretty_task() {
  local f="$1"
  # Missing file: silent return 0 (no spurious cat-failed exit under set -e)
  [ -f "$f" ] || return 0
  local ext="${f##*.}"
  case "$ext" in
    yaml|yml)
      cat "$f"
      ;;
    json)
      if command -v jq >/dev/null 2>&1; then
        jq . "$f" 2>/dev/null || cat "$f"
      else
        cat "$f"
      fi
      ;;
    *)
      # Unknown extension — sniff the first non-blank, non-comment
      # character. If it's `{` or `[`, treat as JSON; otherwise dump
      # raw.
      local first
      first=$(grep -v '^\s*#' "$f" | grep -v '^\s*$' | head -1 \
              | sed -E 's/^[[:space:]]*//' | head -c 1)
      if [ "$first" = "{" ] || [ "$first" = "[" ]; then
        if command -v jq >/dev/null 2>&1; then
          jq . "$f" 2>/dev/null || cat "$f"
        else
          cat "$f"
        fi
      else
        cat "$f"
      fi
      ;;
  esac
}

# Extract a top-level field from a task JSON file.
#
# Designed to be safe to call on non-JSON files (e.g. YAML) — returns
# empty string instead of failing. The watcher uses this to probe for
# optional fields (kind, approval, etc.) without knowing the file
# format up-front; a failed parse should not kill the script.
#
# Usage: task_field <file> <field>
task_field() {
  local f="$1" key="$2"
  [ -f "$f" ] || { echo ""; return 0; }
  if command -v jq >/dev/null 2>&1; then
    # 2>/dev/null suppresses jq's "parse error" stderr when the file
    # isn't JSON. `|| echo ""` keeps the function exit-code clean
    # under `set -e`. Both together mean YAML files return empty
    # for every requested field — which is the correct behaviour.
    jq -r ".${key} // \"\"" "$f" 2>/dev/null || echo ""
  else
    # crude fallback: grep+sed for simple top-level string fields
    grep -oE "\"${key}\"\s*:\s*\"[^\"]*\"" "$f" 2>/dev/null \
      | head -1 \
      | sed -E "s/.*\"${key}\"\s*:\s*\"([^\"]*)\".*/\1/" 2>/dev/null \
      || echo ""
  fi
}

# Safety: deny commands that could publish, delete persistently,
# or rm-rf outside known-safe areas. Returns 0 if safe, 1 if denied.
# This is a defence-in-depth check — the primary safety gate is the
# approval prompt — but it catches obviously-destructive commands
# even if the user mis-clicks "y".
is_command_safe() {
  local cmd="$1"
  local denylist=(
    'git\s+push'                          # no autonomous push
    'helm\s+uninstall'                    # no helm release deletion
    'kubectl\s+delete\s+namespace'        # no namespace deletion
    'kubectl\s+delete\s+ns'               # short form
    'kubectl\s+delete\s+clusterrole'      # cluster-scoped delete
    'rm\s+-rf?\s+/[^t]'                   # rm -rf / anything not /tmp/...
    'rm\s+-rf?\s+~'                       # rm -rf ~
    'mkfs'                                # no filesystem nukes
    'dd\s+if=.*of=/dev/'                  # no raw disk writes
    ':\(\)\s*\{'                          # fork bomb
  )
  for pattern in "${denylist[@]}"; do
    if echo "$cmd" | grep -qE "$pattern"; then
      log "DENIED: command matches denylist pattern '$pattern'"
      return 1
    fi
  done
  return 0
}

# Read approval from the user's terminal.
# Echoes ONLY the decision ("approved" / "denied" / "skipped") to stdout
# so the caller's $(...) capture gets just the decision string.
#
# All UI (banner, task pretty-print, prompt) goes to /dev/tty so the
# operator sees it interactively. Without this redirection, the
# captured string included the entire approval banner — visible in
# the early-pre-fix bridge result file as a multi-line approval_status
# value.
prompt_approval() {
  local task_file="$1" mode="${2:-required}"

  if [ "$mode" = "auto" ]; then
    echo "approved"
    return 0
  fi
  if [ "$mode" = "denied" ]; then
    echo "denied"
    return 0
  fi

  # All UI to /dev/tty. The block below produces zero output on stdout
  # so the caller's `$(...)` capture sees only the final `echo` of
  # the decision string at the end of this function.
  {
    echo
    echo "============================================================"
    echo "BRIDGE: new task awaiting approval"
    echo "============================================================"
    pretty_task "$task_file"
    echo "============================================================"
    echo "Approve? (y = run, n = deny, s = skip-without-result, e = edit)"
  } >/dev/tty 2>&1

  local choice
  read -r -p "[y/n/s/e]: " choice </dev/tty
  case "$choice" in
    y|Y) echo "approved" ;;
    n|N) echo "denied" ;;
    s|S) echo "skipped" ;;
    e|E)
      # Edit-then-rerun loop. Editor stays on /dev/tty for both
      # input and output (already explicitly redirected).
      local editor="${EDITOR:-vi}"
      "$editor" "$task_file" </dev/tty >/dev/tty 2>&1
      # Recurse — the recursive call's output stays on stdout
      # because read+UI redirections inside the recursion are
      # local to that invocation.
      prompt_approval "$task_file" "$mode"
      ;;
    *)   echo "denied" ;;
  esac
}

# Write a result file in the outbox. Args:
#   $1 = task id
#   $2 = approval status (approved|denied|skipped)
#   $3 = overall status (ok|failed|denied|skipped)
#   $4 = JSON array of results (per-step)
write_result() {
  local id="$1" approval="$2" overall="$3" results_json="$4"
  local out="$BRIDGE_OUTBOX/${id}.result.json"

  cat > "$out" <<EOF
{
  "id": "$id",
  "from": "codex",
  "to": "claude-cowork",
  "completed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "approval_status": "$approval",
  "approved_by": "${USER:-unknown}",
  "overall_status": "$overall",
  "results": $results_json
}
EOF
  log "WROTE: $out"
}
