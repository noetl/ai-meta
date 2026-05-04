# Playbook: NoETL-as-AI-OS Spike E2E Smoke

End-to-end validation that all five gaps of the NoETL-as-AI-OS
architecture spike work together on a real cluster. This is the
capstone proof for the spike — once it passes, the whole stack is
known-good.

## What this exercises

| Component                        | How                                                           |
|----------------------------------|---------------------------------------------------------------|
| Gap 1 — `tool: agent framework=noetl` | `spike_e2e_test` calls `spike_failing_subflow` via the agent dispatcher |
| Gap 2 — playbook-as-MCP-server   | Separate curl against `/api/mcp/playbook/.../jsonrpc`        |
| Gap 3 — typed `exposes_as_mcp`   | Both fixtures have the field; catalog register validates     |
| Gap 4 — self-troubleshoot agent  | Auto-invoked by the executor against the failed sub-execution |
| Gap 4.1 — auto-dispatch on failure | `on_failure.troubleshoot: true` on the agent step           |
| Gap 5 — mcp/ollama bridge        | Troubleshoot agent's first-pass call lands on the bridge      |

## Prerequisites

Before running:

1. **Optional-dependency contract holds** — verified by
   `scripts/optional_ai_smoke.py` (locks in the no-crash guarantee
   when AI subsystems are missing). Run this once per environment
   before enabling the AI features.

2. **Cluster reachable**:

   ```bash
   kubectl get pods -n noetl   # noetl-server + noetl-worker should be Running
   noetl context use local      # or whichever context targets this cluster
   ```

3. **Helm values include `ollamaBridge.enabled: true`**:

   ```bash
   helm get values noetl -n noetl | grep -A 4 ollamaBridge
   # Expect: enabled: true
   ```

4. **Ollama backend is reachable from the bridge** and at least one
   model is pulled:

   ```bash
   kubectl exec -n noetl deploy/ollama-bridge -- \
     curl -s http://ollama.noetl.svc.cluster.local:11434/api/tags \
     | jq '.models[].name'
   # Expect at least: gemma2:2b
   ```

5. **Test fixtures registered** (if not, see the registration step
   below):

   ```bash
   noetl catalog list Playbook --json | jq '.[] | select(.path | startswith("tests/spike/")) | .path'
   # Expect:
   #   "tests/spike/spike_e2e_test"
   #   "tests/spike/spike_failing_subflow"
   ```

6. **Self-troubleshoot agent registered** (from `repos/ops`):

   ```bash
   noetl catalog list Playbook --json | jq '.[] | select(.path | startswith("automation/agents/troubleshoot/")) | .path'
   # Expect:
   #   "automation/agents/troubleshoot/diagnose_execution"
   #   "automation/agents/troubleshoot/runtime"
   ```

7. **`mcp/ollama` Mcp resource registered** (from `repos/noetl`):

   ```bash
   noetl catalog list Mcp --json | jq '.[] | select(.path == "mcp/ollama")'
   # Expect a single entry; if empty, register it (next section).
   ```

## One-time registration (skip if already done)

The `noetl catalog register` command takes a single positional file
argument. The resource kind is inferred from the file's `kind:`
field (Playbook, Agent, Mcp, etc.) — no `--type` flag.

```bash
# Spike test fixtures
noetl catalog register \
  /Volumes/X10/projects/noetl/ai-meta/repos/e2e/fixtures/playbooks/spike/spike_failing_subflow.yaml

noetl catalog register \
  /Volumes/X10/projects/noetl/ai-meta/repos/e2e/fixtures/playbooks/spike/spike_e2e_test.yaml

# Troubleshoot agent (if not already registered as part of ops bring-up)
noetl catalog register \
  /Volumes/X10/projects/noetl/ai-meta/repos/ops/automation/agents/troubleshoot/diagnose_execution.yaml

noetl catalog register \
  /Volumes/X10/projects/noetl/ai-meta/repos/ops/automation/agents/troubleshoot/runtime.yaml

# mcp/ollama Mcp catalog entry
noetl catalog register \
  /Volumes/X10/projects/noetl/ai-meta/repos/noetl/noetl/tools/ollama_bridge/catalog_template.yaml
```

## Run the smoke

### Step 1 — Trigger the run

```bash
EXEC_ID=$(noetl exec tests/spike/spike_e2e_test \
  --runtime distributed \
  --payload '{"escalate_to":"none"}' \
  --json | jq -r '.execution_id')
echo "execution_id: $EXEC_ID"
```

`--runtime distributed` routes through the noetl-server (so
the executor's Gap 4.1 hook actually runs in the worker pool —
the local rust runtime has its own dispatcher). `escalate_to: none`
keeps the smoke fast and free — Ollama-only classification, no
upstream API calls. To exercise the OpenAI or Claude paths
separately, rerun with `--payload '{"escalate_to":"openai"}'` or
`'{"escalate_to":"claude"}'` (and ensure the corresponding API
key is in the keychain).

### Step 2 — Wait for completion

```bash
# Poll until terminal status (~3–8s on a warm cluster). The
# `noetl status` command returns top-level `completed` / `failed`
# bools so we can branch on them.
while true; do
  STATUS=$(noetl status "$EXEC_ID" --json | jq -r '"\(.completed) \(.failed)"')
  echo "  $(date +%H:%M:%S) status: $STATUS"
  case "$STATUS" in
    "true false"|"false true") break;;
  esac
  sleep 1
done
```

### Step 3 — Fetch the result and assert

The CLI doesn't have a dedicated `result` subcommand; the playbook's
return value lands in the execution detail endpoint. Two paths
depending on what your noetl-server build supports:

```bash
# Path A — via the CLI's --json status (works on most builds; the
# result body may be embedded under .result or .latest_event.context)
noetl status "$EXEC_ID" --json \
  | python3 /Volumes/X10/projects/noetl/ai-meta/scripts/spike_e2e_assert.py -

# Path B — direct API call to /api/executions/{id} for the full doc
# (use this if Path A reports "smoke_status missing")
NOETL_BASE="http://localhost:8082"   # adjust for your gateway / port-forward
curl -s "$NOETL_BASE/api/executions/$EXEC_ID" \
  | python3 /Volumes/X10/projects/noetl/ai-meta/scripts/spike_e2e_assert.py -
```

The assertion script tolerates a few wrapper shapes (raw / `.data`
/ `.result` / `.output`); if neither path lands the result body
where the script can find it, share the JSON output of one of the
above commands and we'll add the right wrapper unwrapping.

Expected output:

```text
[PASS] result is a dict — got dict
[PASS] smoke_status == 'ok' — got 'ok'
[PASS] agent_envelope is a dict — got dict
[PASS] agent_envelope.status == 'error' (sub-playbook should have failed) — got 'error'
[PASS] agent_envelope.framework == 'noetl' (Gap 1) — got 'noetl'
[PASS] agent_envelope.error is a dict — got dict
[PASS] agent_envelope.error.kind == 'agent.execution' — got 'agent.execution'
[PASS] diagnosis attached (Gap 4.1 auto-dispatch) — got dict
[PASS] diagnosis.category present
[PASS] diagnosis.confidence present
[PASS] diagnosis.root_cause present
[PASS] diagnosis.suggested_action present
[PASS] diagnosis.source present
[PASS] diagnosis.confidence is numeric in [0.0, 1.0]
[PASS] diagnosis.category is from documented set
[PASS] diagnosis.source is from documented set

============================================================
All checks passed. NoETL-as-AI-OS spike e2e smoke is GREEN.
  Diagnosis source:      ollama
  Diagnosis category:    infra
  Diagnosis confidence:  0.78
  Root cause:            DNS resolution failed for non-routable hostname
============================================================
```

Exit code `0` on green, `1` on red.

## Step 4 — Verify Gap 2 (playbook-as-MCP-server) separately

The MCP-protocol surface is an external contract, not a sub-flow
callable, so it gets its own check. From any host that can reach
the noetl server (port-forward if needed):

```bash
NOETL_BASE="http://localhost:8082"   # or your gateway URL

# initialize handshake
curl -s -X POST "$NOETL_BASE/api/mcp/playbook/tests/spike/spike_e2e_test/jsonrpc" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}' \
  | jq

# Expect:
# {
#   "jsonrpc": "2.0",
#   "id": 1,
#   "result": {
#     "protocolVersion": "2024-11-05",
#     "capabilities": { "tools": { "listChanged": false } },
#     "serverInfo": { "name": "noetl-playbook-mcp", "version": "1.0" }
#   }
# }

# tools/list — should advertise the test playbook as a tool
curl -s -X POST "$NOETL_BASE/api/mcp/playbook/tests/spike/spike_e2e_test/jsonrpc" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  | jq '.result.tools[0] | {name, description, inputSchema}'

# Expect: a tool entry with name="spike_e2e_test", inputSchema derived
# from the workload form
```

## Cleanup (optional)

The test fixtures are harmless to leave registered (they only run
when invoked) but if you want to remove them:

```bash
noetl catalog deregister --path tests/spike/spike_e2e_test
noetl catalog deregister --path tests/spike/spike_failing_subflow
```

## Troubleshooting

If the smoke fails:

| Symptom                                                  | Likely cause                                    | Fix                                                          |
|----------------------------------------------------------|-------------------------------------------------|--------------------------------------------------------------|
| `diagnosis attached` FAIL                                | Auto-dispatch hook didn't fire                  | Check that `repos/noetl` PR #408 (Gap 4.1) is in your image  |
| `diagnosis.source` is `ollama` but confidence is 0.0     | Ollama returned malformed JSON                  | Check bridge logs; consider raising to qwen2.5:7b            |
| `agent_envelope.framework != 'noetl'`                    | The agent step routed to a different framework  | Check `spike_e2e_test.yaml` `tool.framework` field           |
| `agent_envelope.status != 'error'`                       | Sub-playbook didn't fail                        | Check `spike_failing_subflow` URL is still non-routable      |
| `[FAIL] result is a dict` with extraction error          | noetl execution result wrapper changed shape    | Pipe the raw JSON to `jq` to inspect; assertion script tolerates several wrappers |

If diagnosis arrives but with low quality (vague root_cause, generic
suggested_action), that's a model-tier issue rather than a wiring
issue — the smoke verifies the *plumbing*, not the diagnostic
quality. Tune `confidence_threshold` and `escalate_to` to push
through to OpenAI / Claude for the cases that matter.

## Refs

- [Architecture spike issue](../sync/issues/2026-05-03-noetl-as-ai-os-architecture-spike.md)
- noetl/noetl#407 (Gap 1, 2, 5), noetl/noetl#408 (Gap 4.1), noetl/noetl#409 (optional-deps hardening)
- noetl/ops#15 (Phase 3 lifecycle agents), noetl/ops#30 (Helm sidecar), noetl/ops#31 (Claude escalation)
- noetl/docs#22, noetl/docs#23, noetl/docs#24, noetl/docs#25, noetl/docs#26 (architecture + operations docs)
