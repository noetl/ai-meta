# Handed GKE parity sync round to Codex (config + deploy + audit)

- date: 2026-05-11T11:00:00Z
- tags: gke, parity, deployment-drift, catalog-sync, gui-bump, storage-tier-audit, codex-handoff

## Round goal

Bring GKE to parity with local kind after the 12-round cowork session shipped
catalog + GUI updates that only landed on kind. Audit what storage tier is
actually in use on GKE — answer Kadyapam's "is GCS the cache" question.

## What surfaced this round

Kadyapam reproduced the drift via the GKE gateway terminal:

- `cd /mcp/amadeus; tools` returned 0 tools (stale mcp/amadeus catalog
  version — pre-session content).
- `travel <query>` returned 'unknown command' (stale GUI without the
  v1.11.0 app:form refinement parser updates).

The 12-round session shipped systematically to local kind. Only item #11
(noetl engine v2.37.8) had explicit GKE deploy phases. Rounds #2-#10
shipped catalog + GUI updates that never reached GKE.

## Phases (7)

1. Audit kind vs GKE — image tags + catalog versions for the four
   session-touched playbooks.
2. Re-register playbooks on GKE via port-forwarded `noetl register`:
   travel/runtime, mcp/amadeus, mcp/vertex-ai, mcp/ollama.
3. Bump noetl-gui to v1.11.0 on GKE (set image or helm-managed path).
4. Smoke through gateway terminal — reproduce Kadyapam's failing sequence,
   confirm it's fixed. Plus item #11 hydration regression on GKE
   (activities should render real data, not friendly-failure).
5. Audit StorageRouter — env vars + router introspection. Answer GCS-as-cache
   question. Document what tier large payloads actually spill to on GKE.
6. Write sync issue + close-out memory.
7. ai-meta pointer bumps (unlikely; config-only round).

## Cap

0 PRs expected. Sync issue at
`sync/issues/2026-05-11-gke-deployment-drift-and-storage-tier-audit.md`,
result file, memory entry.

## Bridge artefacts

- `bridge/inbox/delegated/20260511-110000-gke-parity-sync.task.json`
- `scripts/gke_parity_sync_msg.txt`

## Storage tier audit — what we don't know yet

From my earlier reading of `noetl/core/storage/result_store.py`:
- `TempStore` has tiers selected by `StorageRouter`.
- `StoreTier` enum exists (values not enumerated from inspection).
- 64KB inline threshold (`inline_max_bytes=65536`).
- NATS client is referenced in the constructor.
- GCS is NOT visible as a built-in tier in the code I saw.

But the actual configured router on GKE could be anything depending on the
deployment config. Codex inspects the live pod env + introspects the router
class to nail this down.

Note: item #11's hydration fix walks the EVENTS table (postgres) directly
for terminal-result hydration. The tier question is orthogonal — it's
about result caching/re-reads, not hydration. Both can coexist.

## Generalisable lesson likely to emerge

Future cowork rounds that ship to local kind should either:
- Include an explicit GKE-deploy phase, OR
- Chain a small GKE-parity round afterward.

Otherwise drift accumulates and surfaces as user-reported gateway terminal
weirdness like this round. Worth capturing in the playbook authoring guide
as a 14th rule or in the sync issue as a process note.

## Trigger prompt for Codex (paste this in after pushing)

```
The 12-round cowork session shipped catalog + GUI updates to local kind but
not to GKE (item #11's noetl engine fix was the only round with explicit GKE
deploy). Kadyapam surfaced the drift via the gateway terminal: mcp/amadeus
shows 0 tools (stale catalog), `travel` is unknown command (stale GUI).
Plus a question: what storage tier is in use on GKE — is GCS the cache?

Bridge task: bridge/inbox/delegated/20260511-110000-gke-parity-sync.task.json
Prompt details: scripts/gke_parity_sync_msg.txt
Result file: bridge/outbox/20260511-110000-gke-parity-sync.result.json
Sync issue (you write): sync/issues/2026-05-11-gke-deployment-drift-and-storage-tier-audit.md

Run all 7 phases per the bridge task:
  1. Audit kind vs GKE state (image tags + catalog versions).
  2. Re-register four playbooks on GKE via port-forward + noetl register.
  3. Bump noetl-gui to v1.11.0 on GKE.
  4. Gateway terminal smoke: amadeus tools (5 expected, was 0), travel help
     (now completes), 4-provider matrix, item #11 activities hydration
     regression on GKE.
  5. Audit StorageRouter env + introspect router. Answer GCS-as-cache.
  6. Write sync issue + close-out memory.
  7. ai-meta pointer bumps (likely none).

Architectural rules:
  - Config + deploy + audit round — NO code changes.
  - Don't deploy ollama-bridge to GKE this round (separate infra round).
  - Don't modify GCS bucket config or IAM — read-only inspection only.
  - Don't cut any release.
  - No git push from ai-meta.

GKE context: project=noetl-demo-19700101, namespace=noetl, worker SA already
has secretmanager.secretAccessor on anthropic-api-key + Workload Identity
for Vertex AI.
```
