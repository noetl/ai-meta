# 2026-05-05 — Autonomous Codex deploy + spike smoke (AMBER outcome, 6 findings)

First true autonomous run via the bridge: Claude wrote a prompt,
Codex executed against the cluster, wrote a structured report.
Result: AMBER, with 6 real bugs surfaced. Full report at
bridge/outbox/codex-deploy-report.md.

## What worked

- Codex independently rebuilt CLI to v2.14.1
- Bumped server/worker/bridge to v2.35.2 (lifecycle agent failed → kubectl fallback used)
- Pulled gemma3:4b (3.3GB) + qwen3:32b (20GB) — 23GB local model store
- Creative workaround: PVC resize blocked by storage class → created
  new 40Gi PVC and re-mounted Ollama deployment
- Verified bridge JSON-RPC tools/list end-to-end

## The blocking bug for GREEN

`tool: agent framework=noetl` returns `{status: "started", ...}`
instead of waiting for the sub-execution to terminate. The parent
spike playbook extracts the agent envelope BEFORE the child has
reached terminal status, so:

  - Auto-troubleshoot hook (Gap 4.1) never fires (it triggers on
    status: "error")
  - Spike assertion sees status: "started" not status: "error"
  - Diagnosis never attaches

Root cause: `_invoke_noetl_playbook` in `noetl/tools/agent/executor.py`
calls `execute_playbook_task` which dispatches asynchronously and
returns the started-state envelope. Need to either poll for terminal
status, or use a synchronously-waiting plugin.

## Tomorrow's punch list

1. noetl/noetl: fix _invoke_noetl_playbook to wait for terminal
2. noetl/e2e: parameterize spike_e2e_test ollama_model (default gemma3:4b)
3. noetl/ops: bump_image lifecycle agent surfaces real error
4. noetl/ops: ai_os/lifecycle/deploy reachability check is wrong
5. noetl/ops: Ollama PVC default 40Gi when multi-model
6. noetl/noetl: catalog cleanup (242 entries, 171 unique)

## Architectural insight

The autonomous pattern (Claude-prompts-Codex via bridge) genuinely
works. We surfaced more real bugs in one Codex run than we'd have
found in 4-5 hours of Claude-driven copy-paste iteration. Codex's
agency on the host (kubectl, helm, cargo, git, model pulls) lets it
explore the failure surface and apply workarounds Claude can't.

For next session: drive the follow-ups via Codex prompts too —
"open PR #N to fix bug X with these characteristics" reads like a
spec Codex can execute from start to finish.

Tags: codex, bridge, autonomous, ai-os, spike, amber
