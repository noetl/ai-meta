# NoETL-as-AI-OS Deployment Report

## Goal

Deploy the NoETL-as-AI-OS stack on the local `kind-noetl` cluster, refresh the Rust NoETL CLI, register the spike and AI-OS catalog resources, bump NoETL components to `v2.35.2`, deploy/verify Ollama plus the Ollama bridge, pull the requested models, and run the spike e2e smoke.

## Outcome

- Final spike verdict: AMBER
- Spike execution: `619911519249105323`
- Failing subflow execution: `619911523921559991`
- Models loaded:
  - `qwen3:32b` (`030ee887880f`, 20 GB)
  - `gemma3:4b` (`a2af6cc3eb7f`, 3.3 GB)
- Cluster components at:
  - `noetl-server`: `ghcr.io/noetl/noetl:v2.35.2`
  - `noetl-worker`: `ghcr.io/noetl/noetl:v2.35.2`
  - `ollama-bridge`: `ghcr.io/noetl/noetl:v2.35.2`
- Bridge JSON-RPC reachability: OK; `tools/list` returned the `chat` tool schema.

## What worked

- Pulled latest `ai-meta` and submodules with `git pull --recurse-submodules`; repository was already up to date.
- Rebuilt and installed the maintained Rust CLI from `repos/cli`; after shell hash refresh, `noetl --version` and `ntl --version` both reported `2.14.1`.
- Registered all requested spike, troubleshoot, bridge, AI-OS, and lifecycle catalog resources.
- Directly bumped `noetl-server`, `noetl-worker`, and `ollama-bridge` to `ghcr.io/noetl/noetl:v2.35.2` after the lifecycle bump playbook failed.
- AI-OS deployment created/kept the Ollama backend and bridge resources; both pods reached `Running`.
- Pulled `gemma3:4b` and `qwen3:32b`. `qwen3:32b` remains the closest Ollama match to the requested Qwen 3.6/35B family; no exact 35B tag was found in the known qwen3 lineup.
- Verified `ollama-bridge` JSON-RPC from inside the bridge pod:

```text
{"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"chat","description":"Chat completion against a local Ollama model. Pass `messages` as an array of {role, content} entries (OpenAI-compatible shape). `model` is required.","inputSchema":{"type":"object","properties":{"model":{"type":"string","description":"Ollama model tag, e.g. 'gemma2:9b'"},"messages":{"type":"array","description":"OpenAI-style messages: [{role: 'user'|'system'|'assistant', content: ...}]","items":{"type":"object","properties"
```

## What didn't work + workarounds

- Symptom: `automation/agents/noetl/lifecycle/bump_image` failed.
  - Error message: `shell command exited with returncode=1: set -euo pipefail`
  - Workaround: used `kubectl -n noetl set image` directly for `deployment/noetl-server`, `deployment/noetl-worker`, and `deployment/ollama-bridge`, then waited for rollouts.

- Symptom: `automation/agents/ai_os/lifecycle/deploy` failed even though the resources were mostly applied and ready.
  - Error message: `shell command exited with returncode=1: set -euo pipefail`
  - Observed details: `apply_ollama_manifests`, `wait_ollama_ready`, and `wait_bridge_ready` succeeded; failure occurred around the reachability verification phase.
  - Workaround: inspected pods/services directly and verified bridge reachability with the JSON-RPC command requested in the runbook.

- Symptom: existing `ollama-data` PVC could not be resized from 20Gi to 40Gi.
  - Error message: `persistentvolumeclaims "ollama-data" is forbidden: only dynamically provisioned pvc can be resized and the storageclass that provisions the pvc must support resize`
  - Workaround: created a new `ollama-data-40g` PVC and patched `deployment/ollama` to mount that claim.

- Symptom: spike smoke stayed AMBER instead of GREEN.
  - Assertion failure:
    - `agent_envelope.status == 'error'` expected, got `started`
    - `agent_envelope.framework == 'noetl'` expected, got `None`
  - Evidence: the child execution did fail later:
    - `619911523921559991 | FAILED | tests/spike/spike_failing_subflow`
    - Error: `Request error: [Errno -2] Name or service not known`
  - Root behavior: the parent `spike_e2e_test` extracted the `tool: agent` envelope while the child execution was still only `started`, so the auto-troubleshoot diagnosis was not attached to the parent result.
  - Workaround: reran the spike once to check timing; result repeated, so no further mutation was made.

- Symptom: the spike playbook workload still defaults `ollama_model` to `gemma2:2b`, while this runbook pulled `gemma3:4b` and `qwen3:32b`.
  - Error message: none observed, because the parent extracted the envelope before troubleshoot reached model inference.
  - Workaround: none applied in this session; this should be fixed in the playbook or run payload before expecting GREEN.

## Cluster state at end

`kubectl -n noetl get pods,svc,pvc -o wide`

```text
NAME                                READY   STATUS    RESTARTS   AGE     IP            NODE                  NOMINATED NODE   READINESS GATES
pod/noetl-server-5476f764c5-tf976   1/1     Running   0          12m     10.244.0.29   noetl-control-plane   <none>           <none>
pod/noetl-worker-78c58448b7-5nhld   1/1     Running   0          11m     10.244.0.33   noetl-control-plane   <none>           <none>
pod/noetl-worker-78c58448b7-crzj7   1/1     Running   0          11m     10.244.0.32   noetl-control-plane   <none>           <none>
pod/noetl-worker-78c58448b7-jhhhd   1/1     Running   0          12m     10.244.0.30   noetl-control-plane   <none>           <none>
pod/ollama-7699754455-hpc7v         1/1     Running   0          8m37s   10.244.0.35   noetl-control-plane   <none>           <none>
pod/ollama-bridge-8b8796796-8rz5q   1/1     Running   0          12m     10.244.0.31   noetl-control-plane   <none>           <none>

NAME                    TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)          AGE     SELECTOR
service/noetl           ClusterIP   10.96.205.24   <none>        8082/TCP         27h     app=noetl-server
service/noetl-ext       NodePort    10.96.71.122   <none>        8082:30082/TCP   27h     app=noetl-server
service/ollama          ClusterIP   10.96.67.50    <none>        11434/TCP        4h9m    app=ollama
service/ollama-bridge   ClusterIP   10.96.40.117   <none>        8765/TCP         3h59m   app=ollama-bridge

NAME                                      STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   VOLUMEATTRIBUTESCLASS   AGE     VOLUMEMODE
persistentvolumeclaim/noetl-data          Bound    noetl-data                                 1Gi        RWO            standard       <unset>                 27h     Filesystem
persistentvolumeclaim/noetl-data-shared   Bound    noetl-data-pv                              10Gi       RWX            noetl-shared   <unset>                 27h     Filesystem
persistentvolumeclaim/noetl-logs          Bound    noetl-logs                                 1Gi        RWO            standard       <unset>                 27h     Filesystem
persistentvolumeclaim/ollama-data         Bound    pvc-4fa73534-df69-44dd-b804-8b47b6e3e1e9   20Gi       RWO            standard       <unset>                 4h9m    Filesystem
persistentvolumeclaim/ollama-data-40g     Bound    pvc-4624cf5f-a376-4557-b52f-aec266c83664   40Gi       RWO            standard       <unset>                 8m38s   Filesystem
```

`ollama list`

```text
NAME         ID              SIZE      MODIFIED
qwen3:32b    030ee887880f    20 GB     11 seconds ago
gemma3:4b    a2af6cc3eb7f    3.3 GB    6 minutes ago
```

Component image summary:

```text
noetl-server	noetl-server:ghcr.io/noetl/noetl:v2.35.2 policy=Always
noetl-worker	worker:ghcr.io/noetl/noetl:v2.35.2 policy=Always
ollama-bridge	ollama-bridge:ghcr.io/noetl/noetl:v2.35.2 policy=IfNotPresent
```

Catalog summary:

- `noetl catalog list playbook --json` returned 242 playbook entries, 171 unique paths.
- Relevant registered paths confirmed:

```text
automation/agents/ai_os/lifecycle/deploy
automation/agents/ai_os/lifecycle/status
automation/agents/ai_os/lifecycle/undeploy
automation/agents/ai_os/runtime
automation/agents/bridge/run_commands
automation/agents/noetl/lifecycle/bump_image
automation/agents/troubleshoot/diagnose_execution
automation/agents/troubleshoot/runtime
tests/spike/spike_e2e_test
tests/spike/spike_failing_subflow
```

## Recommendations for the next session

- Fix `tool: agent framework=noetl` or the spike playbook so the parent receives a terminal child envelope, not only `{status: started, execution_id, commands_generated}`. The current AMBER is caused by the parent extracting before the child failure is available.
- Update `tests/spike/spike_e2e_test` to use a model that the runbook actually pulls, likely `gemma3:4b`, or add `gemma2:2b` to the model pull step.
- Make `automation/agents/ai_os/lifecycle/deploy` robust for non-Helm local kind installs and return the concrete failing command/output from the verification step.
- Make the Ollama PVC size configurable and default the AI-OS stack to at least 40Gi when `qwen3:32b` is part of the standard smoke.
- Fix `automation/agents/noetl/lifecycle/bump_image` for this local kind layout, or document the direct `kubectl set image` fallback as the official escape hatch.
- Consider removing or cleaning up the old 20Gi `ollama-data` PVC only when the user explicitly approves cleanup; it was left intact per the no-destructive-action constraint.

## Verbatim verify_shell output

```text
[PASS] result is a dict — got dict
[PASS] smoke_status == 'ok' (extract_envelope step ran) — got 'ok'
[FAIL] agent_envelope.status == 'error' (sub-playbook should have failed) — got 'started'
[FAIL] agent_envelope.framework == 'noetl' (Gap 1) — got None

============================================================
AMBER: smoke harness ran end-to-end; diagnosis MISSING
       (optional-dependency contract held — no crash)
============================================================

To get a fully GREEN run with an attached diagnosis:

  1. Register the troubleshoot agents:
       noetl catalog register repos/ops/automation/agents/troubleshoot/diagnose_execution.yaml
       noetl catalog register repos/ops/automation/agents/troubleshoot/runtime.yaml

  2. Register the mcp/ollama Mcp resource:
       noetl catalog register repos/noetl/noetl/tools/ollama_bridge/catalog_template.yaml

  3. Deploy the Ollama bridge sidecar (helm) + Ollama backend.
     See playbooks/ai_os_spike_e2e_smoke.md prereqs.

  4. Re-run this smoke. Diagnosis should attach automatically
     via Gap 4.1's on_failure.troubleshoot hook.

  Spike framework: PASS (Gaps 1 + 4.1 contract)
  Diagnosis attachment: SKIP (subsystem not deployed)
```
