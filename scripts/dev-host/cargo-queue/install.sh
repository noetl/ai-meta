#!/usr/bin/env bash
# Install the machine-wide cargo build queue on a dev host (idempotent).
# See playbooks/dev-host-build-queue.md. Dev host only -- never prod/CI.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
q="$HOME/.cargo-queue"
mkdir -p "$q/bin" "$q/locks"
install -m 0755 "$here/cargo" "$q/bin/cargo"
ln -sf cargo "$q/bin/cargo-queue"
install -m 0755 "$here/gcb-build" "$q/bin/gcb-build"
install -m 0644 "$here/env.sh" "$q/env.sh"
install -m 0755 "$here/claude-session-start.sh" "$q/claude-session-start.sh"
[ -f "$q/slots" ] || echo "${CARGO_QUEUE_SLOTS:-2}" > "$q/slots"
line='[ -f "$HOME/.cargo-queue/env.sh" ] && . "$HOME/.cargo-queue/env.sh"  # cargo-queue (machine-wide build queue)'
for f in "$HOME/.zshenv" "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.profile"; do
  [ -f "$f" ] || continue
  grep -q 'cargo-queue/env.sh' "$f" || { cp -p "$f" "$f.bak-cargoqueue-$(date +%Y%m%d-%H%M%S)"; printf '\n%s\n' "$line" >> "$f"; }
done
# Claude Code: its shell snapshot re-exports the PATH the app was launched with,
# which overrides ~/.zshenv. A user-level SessionStart hook writes the env.sh
# line into $CLAUDE_ENV_FILE, which is sourced before every Bash command.
cs="$HOME/.claude/settings.json"
if command -v jq >/dev/null && [ -f "$cs" ] && ! grep -q 'claude-session-start.sh' "$cs"; then
  cp -p "$cs" "$cs.bak-cargoqueue-$(date +%Y%m%d-%H%M%S)"
  jq '.hooks.SessionStart = ((.hooks.SessionStart // []) + [{"hooks":[{"type":"command","command":"$HOME/.cargo-queue/claude-session-start.sh","timeout":10}]}])' "$cs" > "$cs.tmp" && mv "$cs.tmp" "$cs"
fi
# Sessions already running: each Bash call re-sources its snapshot, so append the line there too.
for f in "$HOME"/.claude/shell-snapshots/snapshot-*.sh; do
  [ -f "$f" ] && ! grep -q 'cargo-queue/env.sh' "$f" && printf '\n%s\n' "$line" >> "$f"
done
# jobs cap in every CARGO_HOME in use (merge: only add if no [build] jobs yet)
for h in "$HOME/.cargo" ${CARGO_HOME:+"$CARGO_HOME"}; do
  c="$h/config.toml"; mkdir -p "$h"
  if [ -f "$c" ] && grep -qE '^\s*jobs\s*=' "$c"; then echo "keep existing jobs in $c"; continue; fi
  if [ -f "$c" ] && grep -q '^\[build\]' "$c"; then
    echo "NOTE: $c has [build] without jobs; add 'jobs = 2' under it by hand"; continue
  fi
  printf '\n# Dev-host memory guard: at most 2 rustc jobs per cargo (see ai-meta playbooks/dev-host-build-queue.md)\n[build]\njobs = 2\n' >> "$c"
done
echo "installed; open a new shell (or new agent session), then: cargo-queue status"
