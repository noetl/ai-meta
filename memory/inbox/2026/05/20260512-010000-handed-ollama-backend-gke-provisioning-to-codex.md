# Handed Ollama backend provisioning on GKE to Codex (Round B option A → option B)

- date: 2026-05-12T01:00:00Z
- tags: gke, ollama, option-b-promotion, cpu-pod, gemma3, codex-handoff

## Round goal

Promote Round B from option A (bridge-only routing placeholder) to
option B (bridge + CPU Ollama pod with gemma3:4b cached). After this,
`travel --provider ollama` on GKE returns real inference instead of
falling back to OpenAI.

## What changes

- Helm values: enable Ollama backend (case (a) flag flip OR case (b)
  new minimal template). Decision in phase 1.
- New Ollama pod deployed in noetl namespace. ~2-4GB memory request.
- Model cache warmed via `ollama pull gemma3:4b`.
- Bridge starts proxying to a real backend instead of returning errors.

## What does NOT change

- ollama-bridge Service (already working from Round B option A).
- Travel runtime classifier code.
- Storage tier (GCS, just landed).
- In-cluster object-store chooser.
- Bridge → travel-runtime wiring.

## Cost note

~$30-50/month for the always-on Ollama pod (CPU-only). No GPU. gemma3:4b
runs comfortably on CPU but classification latency is ~3-10 seconds per
call vs ~1-2s for cloud providers. Latency is the trade-off for the cost
profile. wait_timeout settings may need to budget for this.

## Phases (5)

1. Inspect existing ollama helm templates — case (a) or (b).
2. Helm values: enable Ollama backend. helm template --validate clean.
3. Deploy + warm gemma3:4b cache + verify bridge can reach backend.
4. Smoke travel --provider ollama (help/flights/activities). Each must
   show effective_provider='ollama' with no fallback. Allow longer
   wait_timeout for CPU latency.
5. Close out — sync issue section close, validation log, memory entry,
   ops pointer bump.

## Cap

1 ops PR (helm values change), CPU pod deploy, model pull, three smokes.

## Bridge artefacts

- `bridge/inbox/delegated/20260512-010000-ollama-backend-gke-provisioning.task.json`
- `scripts/ollama_backend_gke_provisioning_msg.txt`

## Trigger prompt for Codex (paste this in after pushing)

```
Promote Round B from option A (bridge only) to option B (bridge + CPU
Ollama pod with gemma3:4b). After this lands, travel --provider ollama
on GKE returns real Ollama inference instead of OpenAI fallback.

Bridge task: bridge/inbox/delegated/20260512-010000-ollama-backend-gke-provisioning.task.json
Prompt details: scripts/ollama_backend_gke_provisioning_msg.txt
Result file: bridge/outbox/20260512-010000-ollama-backend-gke-provisioning.result.json

Run all 5 phases per the bridge task:
  1. Inspect existing ollama helm templates — case (a) flag flip or (b)
     new minimal template.
  2. Helm values: enable Ollama backend. helm template --validate clean.
     Open small ops PR.
  3. Deploy. kubectl rollout. ollama pull gemma3:4b inside pod
     (~3GB, 2-5 minutes). Verify bridge reaches backend.
  4. Smoke travel --provider ollama help / flights / activities.
     Each must show effective_provider='ollama', audit rows show
     ai_provider='ollama'. CPU latency ~3-10s per classification —
     bump wait_timeout if needed.
  5. Close out: sync issue, validation log, memory, pointer bump.

Architectural rules:
  - CPU-only. No GPU provisioning.
  - Don't touch ollama-bridge service (already working).
  - Don't touch storage tier (just landed GCS), classifier code, chooser.
  - Pull only gemma3:4b this round.
  - No release cut. No git push from ai-meta.

Expected: all three ollama smokes GREEN with effective_provider='ollama'.
After this: only Amadeus production credentials provisioning remains.
```

## What's after this

Only one deferred item remains:
- **Amadeus production credentials provisioning** — Kadyapam provisions
  `amadeus-production-client-id` + `amadeus-production-client-secret`
  in GCP secret manager + IAM binding, then a 3-call production smoke
  closes the loop on Round C.

The session reaches genuine architectural completion after either of
these lands.
