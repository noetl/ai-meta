#!/usr/bin/env bash
# Bridge watcher: polls inbox/ for new task files and processes them.
#
# Usage:
#   ./bridge/codex/watcher.sh                # foreground, infinite loop
#   ./bridge/codex/watcher.sh --once         # process pending tasks once + exit
#   ./bridge/codex/watcher.sh --interval=2   # poll every 2s instead of 1s

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bridge_lib.sh
source "$SCRIPT_DIR/bridge_lib.sh"

INTERVAL=1
ONCE=false
for arg in "$@"; do
  case "$arg" in
    --once) ONCE=true ;;
    --interval=*) INTERVAL="${arg#--interval=}" ;;
    --help|-h)
      sed -n '/^# Usage/,/^$/p' "$0" | sed 's/^# \?//'
      exit 0 ;;
    *) log "WARN: unknown flag '$arg'" ;;
  esac
done

log "WATCHER STARTED: inbox=$BRIDGE_INBOX interval=${INTERVAL}s once=$ONCE"
log "  user=${USER:-unknown} pwd=$(pwd)"
log "  jq: $(command -v jq || echo MISSING)"
log "  kubectl: $(command -v kubectl || echo MISSING)"
log "  noetl: $(command -v noetl || echo MISSING)"
echo

trap 'log "WATCHER STOPPING"; exit 0' INT TERM

while true; do
  # Find pending task files. Globs both .task.json AND .task.yaml /
  # .task.yml (Shape 1 inline-playbook tasks), sorted by mtime so
  # we process oldest first. Route by `kind`:
  # - "procedural" (default) — sequential command execution via handle_task.sh
  # - "goal-directed" — hand to handle_goal_task.sh which prints the task for
  #   Codex to read + iterate. The watcher does NOT auto-execute goal-directed
  #   tasks; Codex's intelligence is the executor.
  #
  # `find` with `-newer` semantics + sort gives us a stable ordering
  # across both extensions. macOS `stat -f` and GNU `stat -c` differ;
  # using `find -printf` would be cleaner but isn't on macOS find.
  # Instead we list+stat via shell, which works everywhere bash does.
  shopt -s nullglob
  task_files=()
  for f in "$BRIDGE_INBOX"/*.task.json \
           "$BRIDGE_INBOX"/*.task.yaml \
           "$BRIDGE_INBOX"/*.task.yml; do
    [ -f "$f" ] && task_files+=("$f")
  done
  shopt -u nullglob

  # Sort by mtime ascending. macOS stat: -f '%m'; Linux stat: -c '%Y'.
  if [ "${#task_files[@]}" -gt 0 ]; then
    if stat -f '%m' "${task_files[0]}" >/dev/null 2>&1; then
      stat_fmt="-f %m"
    else
      stat_fmt="-c %Y"
    fi
    sorted=$(for f in "${task_files[@]}"; do
      mtime=$(stat $stat_fmt "$f" 2>/dev/null || echo 0)
      printf '%s\t%s\n' "$mtime" "$f"
    done | sort -n | cut -f2-)
    while IFS= read -r task_file; do
      [ -z "$task_file" ] && continue

      # Only JSON tasks can be goal-directed (the kind field is part
      # of the JSON envelope schema). YAML tasks are noetl playbooks
      # whose top-level structure is `apiVersion / kind / metadata
      # / workflow` — that `kind` is "Playbook", not the bridge's
      # task kind, and trying to parse a YAML file with jq would
      # crash the watcher. Probe for the bridge kind only when the
      # extension is .json.
      task_ext="${task_file##*.}"
      bridge_kind=""
      if [ "$task_ext" = "json" ]; then
        bridge_kind="$(task_field "$task_file" kind)"
      fi

      if [ "$bridge_kind" = "goal-directed" ]; then
        log "ROUTE: $task_file -> handle_goal_task.sh (Codex orchestrates)"
        "$SCRIPT_DIR/handle_goal_task.sh" "$task_file" || \
          log "ERROR: handle_goal_task.sh failed for $task_file"
        # Goal-directed tasks intentionally exit without writing a result —
        # Codex writes it. Move the task into a "delegated/" sub-directory
        # so the watcher doesn't re-print it on the next poll.
        mkdir -p "$BRIDGE_INBOX/delegated"
        mv "$task_file" "$BRIDGE_INBOX/delegated/" || true
      else
        "$SCRIPT_DIR/handle_task.sh" "$task_file" || \
          log "ERROR: handle_task.sh failed for $task_file (rc=$?); continuing"
      fi
    done <<< "$sorted"
  fi

  if $ONCE; then
    log "WATCHER (--once) DONE"
    break
  fi
  sleep "$INTERVAL"
done
