# Ollama bridge on GKE option A GREEN

Date: 2026-05-11

Option A was explicitly selected: deploy `ollama-bridge` to GKE without deploying an Ollama backend. This round proves bridge routing only; it does not make `--provider ollama` perform real Ollama inference yet.

Deployment:

- Helm release `noetl/noetl` upgraded to revision `126`.
- `ollamaBridge.enabled=true`.
- Deployment: `noetl/ollama-bridge`.
- Pod: `ollama-bridge-6ddd59bd85-pbnm7`, ready `1/1`.
- Image: `ghcr.io/noetl/noetl:v2.37.8`.
- Service: `ollama-bridge.noetl.svc.cluster.local:8765`.
- Bridge env: `OLLAMA_URL=http://ollama.noetl.svc.cluster.local:11434`, `OLLAMA_BRIDGE_PORT=8765`.
- The `ollama` backend Service is intentionally absent.

Routing proof:

- From a NoETL worker pod, `POST http://ollama-bridge.noetl.svc.cluster.local:8765/jsonrpc` with `tools/list` returned HTTP 200 and a tool catalog.
- `kubectl logs deploy/ollama-bridge` showed `POST /jsonrpc HTTP/1.1 200 OK`, proving runtime traffic reached the bridge.

Travel smoke:

- Execution `624832446000792195` ran `travel --provider ollama help` on GKE.
- Status: `COMPLETED`.
- Render: `render_help`, `app:column`.
- Expected option-A behavior occurred: `effective_provider=openai`, because the bridge could not reach `ollama.noetl.svc.cluster.local:11434`.
- `provider_fallback_reason` included the backend-missing message: `Cannot connect to host ollama.noetl.svc.cluster.local:11434`.
- `travel_agent_events` recorded the fallback classification row with `ai_provider=openai` and `intent=help`.

Consequence: GKE now has the `ollama-bridge` Service placeholder and the travel runtime reaches it. Real Ollama provider GREEN remains deferred until an Ollama backend is provisioned, either as a CPU pod or an external endpoint.

Result file: `bridge/outbox/20260511-220000-ollama-bridge-gke-deployment.result.json`.
