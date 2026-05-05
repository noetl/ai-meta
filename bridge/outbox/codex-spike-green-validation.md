# NoETL-as-AI-OS Spike Green Validation

## Tag deployed

`v2.35.3`

Images deployed to the local `noetl` namespace:

```text
noetl-server	noetl-server:ghcr.io/noetl/noetl:v2.35.3 policy=Always
noetl-worker	worker:ghcr.io/noetl/noetl:v2.35.3 policy=Always
ollama-bridge	ollama-bridge:ghcr.io/noetl/noetl:v2.35.3 policy=IfNotPresent
```

CLI rebuilt from `repos/cli`:

```text
noetl 2.14.1
ntl 2.14.1
```

Latest releases observed:

```text
v2.35.3	Latest	v2.35.3	2026-05-05T15:12:07Z
v2.35.2		v2.35.2	2026-05-05T03:54:25Z
v2.35.1		v2.35.1	2026-05-04T15:49:22Z
```

## Verdict

RED

The previous `started` envelope timing issue changed after deploying `v2.35.3`: the agent step now waits for the child playbook and returns a proper failed NoETL agent envelope, but the parent playbook is marked `FAILED` before the `extract_envelope` step can run. Because `extract_envelope` did not surface `smoke_status: ok`, the assertion script failed.

Spike execution:

```text
620149205507506657
```

Parent execution summary:

```json
{
  "execution_id": "620149205507506657",
  "status": "FAILED",
  "path": "tests/spike/spike_e2e_test",
  "error": "sub-playbook returned non-success status",
  "progress": 100,
  "result": null,
  "events": 16
}
```

Child failing subflow:

```json
{
  "execution_id": "620149265737712109",
  "status": "FAILED",
  "path": "tests/spike/spike_failing_subflow",
  "error": "Request error: [Errno -2] Name or service not known",
  "events": 15
}
```

Relevant parent events:

```text
command.failed	trigger_failure	FAILED	sub-playbook returned non-success status
step.exit	trigger_failure	COMPLETED	sub-playbook returned non-success status
call.error	trigger_failure	FAILED	sub-playbook returned non-success status
command.issued	extract_envelope	PENDING
```

The `trigger_failure` envelope now includes the expected agent shape:

```json
{
  "error": {
    "code": "PLAYBOOK_FAILED",
    "kind": "agent.execution",
    "message": "sub-playbook returned non-success status",
    "retryable": false
  },
  "status": "error",
  "framework": "noetl",
  "entrypoint": "tests/spike/spike_failing_subflow",
  "execution_id": "620149265737712109"
}
```

## Diagnosis source if attached

None attached.

The parent execution failed before `extract_envelope` could run, and the agent error envelope did not include `error.diagnosis`.

## Last 15 lines of assert output

```text
[PASS] result is a dict — got dict
[FAIL] smoke_status == 'ok' (extract_envelope step ran) — got None
[INFO] agent_envelope not surfaced at result level (noetl-server may have filtered nested dicts; checking diagnosis directly)
```

Follow-up on 2026-05-05: PR noetl/noetl#412 was merged and released as v2.35.4, then deployed to the local NoETL cluster for noetl-server and noetl-worker. After refreshing the local spike/troubleshoot catalog definitions to use the in-cluster NoETL service URL and the installed Ollama model, the spike e2e smoke reached GREEN. The final verification command reported `GOAL: GAP1_CARVEOUT_GREEN` with diagnosis source `ollama`, category `unknown`, and confidence `0.0`, superseding the earlier v2.35.3 RED report.

Follow-up on 2026-05-05: Gap 4.1 follow-up PRs were merged across ops, e2e, and noetl, with additional runtime fixes for the Ollama MCP endpoint, stateless JSON-RPC MCP servers, inferred diagnostic completion, and the terminal-status/persisted-event race. The local NoETL cluster is now on `v2.35.8` for server, worker, and ollama-bridge, and the spike e2e smoke is GREEN. The final run attached the actual diagnosis dict from `error.diagnosis` on first arrival (`diagnosis_lookup.attempts=0`), so the tactical fixture poll is no longer load-bearing.
