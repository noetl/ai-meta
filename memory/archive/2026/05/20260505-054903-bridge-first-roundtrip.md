# 2026-05-04 — Claude ↔ Codex bridge: first round-trip

The agent-to-agent bridge in `bridge/` is now functional end-to-end.

## What just happened

1. Claude (Cowork mode, sandboxed) writes a task file to
   `bridge/inbox/<id>.task.yaml` via its Write tool. Task files are
   noetl playbooks (Shape 1) or JSON envelopes referencing playbook
   files (Shape 2/3).
2. The bash watcher in `bridge/codex/watcher.sh` polls the inbox,
   detects the task, applies the denylist, prompts for approval at
   the operator's terminal (or auto-approves on `# bridge-approval:
   auto` opt-in), and dispatches via `noetl exec --runtime local`.
3. Noetl 2.14.0's local Rust runtime parses the playbook, runs each
   step, emits a structured `RunOutcome` JSON envelope on stdout
   (progress on stderr, suppressed in `--json` mode). Envelope
   carries status / playbook_name / executed_steps / step_results /
   duration.
4. Watcher wraps the noetl envelope with bridge metadata
   (id / from / to / completed_at / approval_status / approved_by /
   overall_status / executor) and writes
   `bridge/outbox/<id>.result.json`.
5. Claude reads the file, parses JSON, decides next action.

## Bugs fixed during bring-up (chronological)

- Watcher only globbed `*.task.json` (missed `.task.yaml`). Fixed
  to scan both extensions, sort by mtime via portable shell+stat.
- `task_field` used jq on every file regardless of extension; jq
  parse-errored on YAML and killed watcher. Fixed: returns "" on
  parse failure.
- Brace-expansion bug in `${1:?usage: ... <task.{yaml,json}>}` —
  bash's parameter-expansion parser treated `{...}` as nested,
  appended `>}` to `$1`. Plain ASCII usage string fixes it.
- noetl's `--json` flag was a no-op for local runtime: progress to
  stdout, no structured envelope. Cli#8 (PR merged) added
  `RunOutcome` struct + routed all progress to stderr + serialized
  envelope to stdout when `--json` set. Wired through to PlaybookRunner
  via `with_quiet(json)` + `with_emit_json(json)`.
- pretty_task in bridge_lib.sh ran jq on the YAML task during the
  approval prompt — parse error leaked into the operator's terminal.
  Fixed: detect file format by extension; YAML uses cat, JSON uses jq.
- prompt_approval echoed UI to stdout; `$(...)` capture slurped the
  entire prompt banner as approval_status. Fixed: UI block to
  `/dev/tty`, decision-only on stdout.
- `head -10` scan for `# bridge-approval: auto` missed line-11
  occurrences. Bumped to `head -30`.

## Architectural takeaways

- Local Rust runtime currently supports a subset of tool kinds
  (shell, http, playbook, duckdb, auth, sink). NOT python /
  postgres / iterator. Bridge tasks must use the supported subset
  or fall back to distributed runtime.
- Step-result capture in the local runner: shell tools execute but
  don't (yet) populate `step_results.<step>` with their stdout.
  Tracked as a follow-up CLI enhancement.
- Forward-compatible with future MCP-tool exposure: when an
  authenticated network path exists between Claude and noetl-server,
  the bridge becomes redundant (Claude calls
  `/api/mcp/playbook/<path>/jsonrpc` directly). The file-bus is the
  workaround for the current sandbox isolation.

## What this unlocks

- Claude writes tasks autonomously; user only types `y` for
  mutating tasks. No copy-paste of commands.
- The bridge becomes the demo for the noetl-as-AI-OS spike: every
  agent-to-agent interaction goes through noetl playbooks.
- Tutorial doc lives at `playbooks/agent_bridge_tutorial.md`. Will
  be promoted to `repos/docs` once the demo is fully polished
  (post follow-up: shell-step result capture).

## Follow-ups

- noetl/cli: capture `kind: shell` stdout into `step_results.<step>`
  in PlaybookRunner. Currently empty string. Estimated 20 LOC change.
- noetl/cli: add `--quiet` as a top-level CLI flag (currently
  exposed only via the library builder).
- ai-meta: tutorial polish + screencast for the demo.
- The `say()` helper added to PlaybookRunner in cli#8 is dead code
  (inlining was simpler). Cleanup PR.
