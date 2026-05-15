# Ollama backend on GKE provisioned

Date: 2026-05-12
Status: GREEN

Round B was promoted from option A (bridge only) to option B (bridge plus backend) on GKE.

Ops changes:

- ops#74 added an opt-in `ollama` Helm component: PVC, Deployment, and Service.
- ops#75 resized the backend for `gemma3:4b` after live GKE validation showed the first 4Gi/6Gi sizing was too small.
- ai-meta now points `repos/ops` at `3587f12ac0e1aaee0185e285b064cfde7703f430`.

GKE deployment:

- Helm release `noetl` revision `129`
- Deployment `noetl/ollama`
- Service `ollama.noetl.svc.cluster.local:11434`
- PVC `noetl/ollama-data`, 20Gi
- Image `ollama/ollama:latest`
- Model `gemma3:4b`, digest prefix `a2af6cc3eb7f`, size `3.3 GB`
- CPU-only sizing: request `500m` CPU / `8Gi` memory, limit `2` CPU / `10Gi` memory

Important sizing lesson:

The first live attempt with a 4Gi request / 6Gi limit reached the bridge and cached the model, but `/api/chat` returned HTTP 500 because Ollama could not load the model. Logs said the model needed about `4.0 GiB`, while only `2.7 GiB` was free inside the container after runtime overhead. Raising the pod to 8Gi/10Gi fixed it. Direct bridge-to-Ollama `/api/chat` returned `pong`.

Travel smokes on GKE:

- `help`: execution `624881246190961331`, child `624881262003487439`, `effective_provider=ollama`, no fallback, `app:column`
- `flights`: execution `624881921993999156`, child `624881937731027792`, `effective_provider=ollama`, no fallback, `app:column`
- `activities`: execution `624885675040440455`, child `624885689158467747`, `effective_provider=ollama`, no fallback, `app:column`

Observed latency:

- Average travel smoke elapsed time: about `91s`
- Average Ollama child execution time: about `62s`

This is acceptable for the proof round but not pleasant UX. Future tuning options are smaller model, more CPU, GPU nodes, or external Ollama endpoint. Those are explicitly out of scope for this CPU-only round.

One failed/stuck attempt to ignore:

- Activities execution `624882636149752823` overlapped a Helm/server rollout and stuck after `log_classification` because the Amadeus child result tried to emit events while the server connection was unavailable. The clean rerun `624885675040440455` is the accepted smoke.

Remaining user-gated follow-up: Amadeus production credentials provisioning and limited paid production smoke.
