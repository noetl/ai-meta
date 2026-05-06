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

Follow-up on 2026-05-05 (regression sweep): a v2.35.8 regression-test pass (8 buckets across smokes, cluster health, spike stability x3, MCP JSON-RPC, idempotent bump_image, auto-troubleshoot contract, catalog re-register, and persisted event-envelope shape) caught a subtle bug invisible at the assertion layer. The spike's `extract_envelope` step read `error.diagnosis` correctly from the live agent response, so the spike was GREEN — but the worker's event-projection layer was stripping the nested diagnosis dict before persisting `trigger_failure`'s terminal event. So `result.context.error.diagnosis` survived `kind/code/message/retryable` (scalars) but lost the diagnosis dict in the durable event stream, breaking any post-hoc consumer (GUI event browser, audit replay, downstream consumers reading events instead of the live response). Fixed in [noetl/noetl#417](https://github.com/noetl/noetl/pull/417), released as `v2.35.9`, and deployed across server/worker/ollama-bridge. Three consecutive v2.35.9 spike runs returned GREEN with `diagnosis_lookup.attempts=0`, and bucket 8 now confirms `result.context.error.diagnosis` carries the full `{category, confidence, root_cause, suggested_action, source, execution_id, escalated}` dict in the persisted events. One operational note: the initial v2.35.9 rollout hit a transient GHCR-availability race (the bump_image lifecycle began before GHCR exposed the new tag); idempotent re-runs of the same playbook converged cleanly. Verdict for the sweep was AMBER (regressions found and fixed in-flight per task rules); the deployed state is GREEN.

Follow-up on 2026-05-06 (GKE Vertex AI production validation): the GKE stack in `noetl-cluster` (`us-central1`, project `noetl-demo-19700101`) is validated with noetl `v2.35.9` on server/worker, gateway `v2.10.0`, and GUI `v1.7.0`; `https://gateway.mestumre.dev` returned health `ok` and `https://mestumre.dev` returned HTTP 200. The triage backend is `mcp/vertex-ai` with `gemini-2.5-flash` rather than `gemini-2.0-flash`, because this project returned Vertex AI HTTP 404 for `gemini-2.0-flash` and `gemini-2.0-flash-001` as documented in the Vertex AI model-availability section. The six-run GKE sweep completed GREEN functionally: all six spike executions attached a diagnosis with `source=vertex-ai` and `model=gemini-2.5-flash`; 4/6 runs had `diagnosis_lookup.attempts <= 1`, while 2/6 needed attempts 2-3 (`620875219263030195` and `620877265538122480`), which is documented as expected cloud-latency variance in docs#34 rather than a runtime regression. Workload Identity to Vertex AI is confirmed, token usage telemetry was captured, and `mcp/gcp/gke` observability returned 15 tools. Frontend gateway quickstart docs landed in docs#32, cloud-latency reconciliation landed in docs#34, and the remaining future work is captured in `sync/issues/2026-05-06-noetl-retry-budget-cloud-aware.md`.

Follow-up on 2026-05-06 (worker triage key forwarding): noetl/noetl#418 landed the worker-side auto-troubleshoot forwarding generalisation so canonical `triage_*` workload keys propagate without the spike fixture's deprecated `ollama_*` compatibility mirror. Semantic release cut `v2.36.0` (the task expected `v2.35.10`, but the merged `feat(worker)` PR correctly produced a minor release), and the GKE `noetl-server` and `noetl-worker` deployments in `noetl-cluster` (`noetl-demo-19700101`) were updated to `ghcr.io/noetl/noetl:v2.36.0` through the bump_image lifecycle playbook. noetl/e2e#10 removed every `ollama_model` / `ollama_mcp_server` mirror from `tests/spike/spike_e2e_test`; three triage-only GKE spike runs with `triage_mcp_server=mcp/vertex-ai` and `triage_model=gemini-2.5-flash` completed GREEN functionally: executions `620994605177111106`, `620995237736874768`, and `620995649835631584` all returned `source=vertex-ai`, `model=gemini-2.5-flash`, and `smoke_status=ok` with `diagnosis_lookup.attempts` `0, 0, 3`. The new `scripts/worker_workload_forwarding_smoke.py` passed `OK 8/8`, and the existing carve-out, Gap 4.1, auto-troubleshoot, optional-AI, and live-vs-persisted parity smokes remained green. Next handoffs remain alias removal and cloud-aware retry-budget tuning.
