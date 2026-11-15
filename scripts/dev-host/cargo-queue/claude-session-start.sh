#!/bin/sh
# Claude Code SessionStart hook: Claude Code's shell snapshot re-exports the PATH
# the app was launched with, overriding ~/.zshenv. Lines written to
# $CLAUDE_ENV_FILE are sourced before every Bash command, after the snapshot,
# so the cargo-queue wrapper ends up first on PATH in every agent shell.
if [ -n "$CLAUDE_ENV_FILE" ]; then
  echo '[ -f "$HOME/.cargo-queue/env.sh" ] && . "$HOME/.cargo-queue/env.sh"  # cargo-queue' >> "$CLAUDE_ENV_FILE"
fi
exit 0
