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

Follow-up on 2026-05-06 (deprecated Ollama alias removal): noetl/ops#42 removed the deprecated `ollama_mcp_server` / `ollama_model` workload aliases from `automation/agents/troubleshoot/diagnose_execution.yaml`, `runtime.yaml`, and `README.md`; canonical `triage_model` and `triage_mcp_server` are now the only backend input names. This was safe because noetl/noetl#418 in `v2.36.0` made worker auto-troubleshoot forwarding generic for `triage_*` keys. The updated diagnose playbook was re-registered locally as catalog version `14` and on GKE as version `3`. Three GKE validation runs were GREEN: canonical Vertex payload `621076778177527989` returned `source=vertex-ai`, `model=gemini-2.5-flash`, `attempts=0`; bare payload `621077111373037955` and legacy `ollama_*` payload `621077418630971948` both silently ignored removed alias inputs and fell through to the intentionally unchanged registered default `mcp/ollama` / `gemma3:4b`, returning `source=ollama`, `model=gemma3:4b`, `attempts=0`. The only remaining GKE-arc follow-up is cloud-aware retry-budget tuning.

Follow-up on 2026-05-07 (retry-budget tuning, AMBER + arc closure with new sync issue): noetl/noetl#419 made the diagnosis-fetch retry budget explicit and extended it from the previously-implicit 10s window to 12s, with a regression test proving an 11s persisted-diagnosis flush is now covered. Released as `v2.36.1` and deployed via `bump_image` lifecycle to GKE noetl-server + noetl-worker. **Important architectural finding from this round**: my prior task spec assumed the budget was ~600ms; it was already 10s (bumped without my knowing in an earlier round). The 12s tuning is correct as far as static budgets go — but the 3-run GKE acceptance sweep returned `attempts=16, 0, 0`, with the first run hitting a tail-latency outlier (~30+ seconds end-to-end on the diagnose sub-execution, suspicious cold-start signature: subsequent runs reused warm Vertex state at attempts=0). **A static budget cannot reliably absorb 30s tail latency.** This is the architectural limit of option (a) from `sync/issues/2026-05-06-noetl-retry-budget-cloud-aware.md`. Option (c) — adaptive backoff (start short ~3s, exponential extension up to ~60s cap) — is filed as the proper fix at `sync/issues/2026-05-07-noetl-adaptive-retry-backoff-tail-latency.md`. The GKE Vertex AI arc is closed AMBER for this round but the deployed stack is production-validated: tested workload paths perform correctly, tail-latency events fall through to the spike fixture's belt-and-suspenders polling and complete cleanly. Three rounds shipped: (1) worker key-forwarding generalisation [noetl#418/v2.36.0], (2) deprecated alias removal [ops#42], (3) static-budget retry tuning [noetl#419/v2.36.1] — adaptive backoff is queued as the architectural follow-up when tail latency becomes a real operational concern.

Follow-up on 2026-05-07 (adaptive diagnosis fetch + recursive projection closure): noetl/noetl#420 shipped adaptive diagnosis-fetch backoff in `v2.37.0` (0.5s initial sleep, 1.5x multiplier, 4s max sleep, 60s deadline) and noetl/noetl#421 shipped the recursive `error.diagnosis` event-projection carve-out in `v2.37.1`, making the new telemetry actually visible in persisted events. GKE `noetl-server` and `noetl-worker` in `noetl-cluster` (`noetl-demo-19700101`) are deployed at `ghcr.io/noetl/noetl:v2.37.1`. A fresh triage-only Vertex AI spike, execution `621262477380026909`, completed GREEN with `source=vertex-ai` and `model=gemini-2.5-flash`; persisted events now expose the canonical path `events[15].result.context.error.diagnosis._meta.diagnosis_fetch` with `{poll_count: 1, elapsed_seconds: 0.064, deadline_seconds: 60.0, hit_deadline: false}`. The live-vs-persisted parity smoke was extended from `2/2` to `3/3` with a v2.37.0 regression fixture that detects `NESTED_DICT_LOSS at result.context.error.diagnosis._meta`, closing the loop on the May 6 event-projection audit: the audit predicted this nested-control-contract failure mode, the projection carve-out was extended, and the parity smoke now catches it before release. Docs#35 records that operators should monitor `_meta.diagnosis_fetch.elapsed_seconds` and `poll_count` rather than relying on the spike fixture's `diagnosis_lookup.attempts` as the primary latency signal. The architectural ceiling of static-budget tuning has been removed; cold-start tail latency is now absorbed at the noetl side, and the spike fixture's polling layer is regression detection rather than load-bearing absorption.

Follow-up on 2026-05-08 (AI-OS widget renderer round 2 GREEN): noetl/noetl#423 fixed the worker event-projection gap that stripped nested `render.args` while preserving only `render.type`; semantic release cut `v2.37.2`, and local kind (`kind-noetl`) now runs `noetl-server` and `noetl-worker` at `ghcr.io/noetl/noetl:v2.37.2` with GUI `ghcr.io/noetl/gui:v1.8.0`. The round-2 widget smokes are GREEN: primary execution `622415858869994280` persisted the full `app:column.args.children[]` tree (`app:alert`, `app:markdown`, `app:button`) and rendered it in the terminal-style NoETL prompt; clicking the button re-ran `report 622415858869994280` and appended a second report entry. Unsupported-widget execution `622415859574637357` persisted `{hello: world, nested.deeper: true}` and rendered the expected `unsupported widget: app:nonexistent` JSON preview. This flips the prior round-2 RED report to GREEN: widgets remain GUI/data-plane render descriptors, no Widget catalog kind was added, and NoETL uses terminal prompt semantics rather than chat-thread semantics. The linked Confluence widget pages are Atlassian-auth protected from Codex and should be reconciled from an authenticated export in a future docs polish pass.

Follow-up on 2026-05-08 (AI-OS docs text pass GREEN): docs#44 landed the missing `docs/gui/catalog-ux.md` page, restored the widgets-to-Catalog UX cross-link, and aligned the AI-OS GUI, architecture, and tutorial docs around NoETL's terminal-style prompt/output language rather than chat terminology. The pass documents the post-round-2 reality: `noetl v2.37.2` preserves nested `render.args`, `gui v1.8.0` renders widget descriptors in the prompt, canonical `triage_*` workload knobs replace stale `ollama_*` examples, and frontend/browser traffic routes through the gateway rather than directly to `noetl-server`. `npm run build` in `repos/docs` completed cleanly, `/docs/gui/catalog-ux` is generated, and `docs/gui/widgets.md` links to it.

Follow-up on 2026-05-09 (GUI LAN + prompt auto-render UX cleanup GREEN): gui#27 shipped runtime LAN correction for helm-baked `VITE_API_BASE_URL=http://localhost:8082` plus a NoetlPrompt `run` watcher that auto-appends widget output when the execution completes; smoke then found a prompt-run catalog-version 422, fixed in gui#28, so local kind is deployed on `ghcr.io/noetl/gui:v1.9.1`. The GUI was loaded from `http://192.168.1.240:30081/catalog` while `/env-config.js` still reported `VITE_API_BASE_URL=http://localhost:8082`; prompt/catalog API calls succeeded with no Network Error, proving the LAN host rewrite path. Widget execution `622695138808038281` auto-rendered `Widget all-types coverage` in the terminal-style prompt within about four seconds without typing `report`, the button callback emitted `echo widget-button-command`, and non-render probe `622695484049589148` completed without prompt pollution. The bridge result is `bridge/outbox/20260509-030314-gui-lan-rewrite-and-run-auto-render.result.json`; deferred UX follow-ups remain empty API-base chart defaults and form/customform payload submission semantics.

Follow-up on 2026-05-09 (travel canvas widget rerun GREEN): the travel flagship GUI arc is now closed on local kind with `ghcr.io/noetl/gui:v1.10.4`. gui#31 fixed native form-submit navigation from `/travel` and report summaries now show `render=app:column`; gui#32 preserved the originating `sourcePrompt` on canvas assistant messages and maps widget `command` events such as `rerun <execution_id>` back to the original travel query; gui#33 made `AppButton` consume DOM clicks before emitting widget events so parent routed surfaces cannot treat widget clicks as navigation/form activity. Final browser smoke on `/travel?final-rerun=v1104-1778341683024` submitted `flights from SFO to JFK on 2026-07-15 for 2 adults`, rendered the friendly-error app:column widget, clicked the scoped canvas `rerun this search` button, stayed on `/travel`, and produced fresh rerun execution `623060323385213862`; widget count increased, the original query remained visible, and loading cleared. One operational note: the release-triggered `v1.10.4` image workflow stalled in Docker build/push and was cancelled; rerunning the same versioned image build via workflow_dispatch succeeded, and explicit rollout/pod-image checks confirmed the deployment is on `v1.10.4`.
