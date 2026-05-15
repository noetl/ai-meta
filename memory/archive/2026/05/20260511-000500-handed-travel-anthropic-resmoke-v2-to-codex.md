# Handed travel Anthropic re-smoke v2 to Codex (refreshed for post-Phase-3 state)

- date: 2026-05-11T00:05:00Z
- tags: travel-agent, anthropic, re-smoke, gcp-secret, gke-project-alignment, codex-handoff

## Round goal

Re-run the Anthropic provider smokes once Kadyapam provisions the GCP
Anthropic secret. Refreshed from the May 9 task because the world has
moved since:

- Phase 3 vertex-ai landed; GKE project corrected to `noetl-demo-19700101`
  (the original task assumed `noetl-cluster`).
- Hotels and activities branches landed — smoke matrix grows from 3 to 5.
- Refinement forms landed — should render under each anthropic widget too.
- Audit side-effect landed — audit rows should show ai_provider='anthropic'
  for anthropic smokes.

Travel runtime is at catalog v22.

## Why a refresh, not just running the May 9 task

The original re-smoke task assumed Anthropic would be smoked on the same
project as Phase 3 vertex-ai (noetl-cluster). Phase 3 retro corrected that:
GKE runs in noetl-demo-19700101. If Kadyapam provisioned the Anthropic
secret in the GKE project (the right place), the travel runtime's
anthropic_secret_path workload field — which still points at project number
1014428265962 (noetl-cluster) — would miss it. Same trap as Phase 3.

The refreshed task makes secret-path alignment phase 1 of the round. Codex
checks both projects, picks the right default, and may open a 1-line ops PR
to realign if needed. Mirrors the Phase 3 ops#60 fix.

## Smoke matrix expansion

| intent     | --provider anthropic | regression spot-check |
| ---------- | -------------------- | --------------------- |
| help       | required             | openai default        |
| flights    | required             | —                     |
| locations  | required             | —                     |
| hotels     | required             | —                     |
| activities | required             | —                     |
| —          | —                    | vertex-ai help        |

Each anthropic smoke must produce:
- status=completed
- effective_provider='anthropic'
- provider_fallback_reason null/absent
- audit row in travel_agent_events with ai_provider='anthropic'

## Cap

Smoke-only by default. One small ops PR allowed if secret_path needs to
move from project number 1014428265962 to the GKE project number.

## Phases (4)

1. Verify secret alignment (read-only gcloud + project number lookup).
2. Re-register if path changed.
3. Full anthropic smoke matrix + spot-check regressions.
4. Close-out: result file + validation log if GREEN.

## Bridge artefacts

- `bridge/inbox/delegated/20260511-000500-travel-anthropic-resmoke-v2.task.json`
- `scripts/travel_anthropic_resmoke_v2_msg.txt`

## Provisioning recipe for Kadyapam (target the GKE project)

```bash
# Create or add a version:
echo -n "sk-ant-api03-..." | gcloud secrets create anthropic-api-key \
  --replication-policy=automatic --project=noetl-demo-19700101 --data-file=-
# Or:
echo -n "sk-ant-api03-..." | gcloud secrets versions add anthropic-api-key \
  --project=noetl-demo-19700101 --data-file=-

# Grant worker SA access:
gcloud secrets add-iam-policy-binding anthropic-api-key \
  --project=noetl-demo-19700101 \
  --member=serviceAccount:noetl-worker-mcp@noetl-demo-19700101.iam.gserviceaccount.com \
  --role=roles/secretmanager.secretAccessor
```

The worker SA name is the same as the Vertex AI Workload Identity SA from
Phase 3 — same service account reads Anthropic and Vertex AI tokens, just
gets a different secretAccessor binding.

## What's next after this lands (or is skipped)

6. Ollama provider — needs in-cluster bridge URL routing design
7. Investigate Amadeus test API 500s on flights/locations
8. NoETL-Python globals/locals idiom into the authoring guide as 13th rule
9. Single-source-of-truth refactor for the classifier system prompt

If you'd rather skip Anthropic entirely for now, the round can sit on
disk untouched — bridge watcher only picks up the task when ai-meta is
pushed. Item #6 (Ollama) is independent and can be designed any time.
