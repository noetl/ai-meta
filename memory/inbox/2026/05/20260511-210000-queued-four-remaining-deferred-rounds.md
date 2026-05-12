# Queued four remaining deferred rounds for Codex (session wind-down)

- date: 2026-05-11T21:00:00Z
- tags: queued, deferred, authoring-guide, ollama-gke, amadeus-production, cloud-tier-router

## What's queued

All four remaining deferred items from the session have bridge tasks +
Codex prompts on disk. Order is smallest-to-largest scope. Each can be
fired independently or skipped — none block any other.

### A. Authoring guide 14th rule (docs-only, smallest)

- `bridge/inbox/delegated/20260511-210000-authoring-guide-kind-gke-parity-rule.task.json`
- `scripts/authoring_guide_kind_gke_parity_rule_msg.txt`

Pin "every kind deploy needs a chained GKE-parity round" as the 14th
rule. Three rediscoveries in the session is the evidence. Cap: 1 docs PR.

### B. Ollama bridge GKE deployment (infra, medium)

- `bridge/inbox/delegated/20260511-220000-ollama-bridge-gke-deployment.task.json`
- `scripts/ollama_bridge_gke_deployment_msg.txt`

Deploy ollama-bridge + a CPU Ollama (default option B) to GKE so
`travel --provider ollama` runs natively on the production cluster.
Option C (GPU node pool) requires Kadyapam approval — AMBER + STOP.
Cap: 0 PRs if helm-managed; 1 PR if a values change is needed.

### C. Amadeus production API switch (ops + limited smoke)

- `bridge/inbox/delegated/20260511-230000-amadeus-production-api-switch.task.json`
- `scripts/amadeus_production_api_switch_msg.txt`

Add `amadeus_env: test | production` workload field to mcp/amadeus.
Default stays test. Production needs separate credentials in GCP secret
manager — recipe documented for Kadyapam. Smoke is tightly limited
(single-digit production calls — cost control). Cap: 1 ops PR.

### D. Cloud-tier router decision (design-first, largest scope)

- `bridge/inbox/delegated/20260511-235000-cloud-tier-router-decision.task.json`
- `scripts/cloud_tier_router_decision_msg.txt`

Surfaced as Path B from round 20260511-110000. NOETL_DEFAULT_STORAGE_TIER=kv,
spillover → worker-local disk (ephemeral), router cloud tier is S3 (not
GCS) in a GCP project. The MinIO elimination round addressed the
in-cluster object store. This round addresses the orthogonal cross-pod/
cross-cluster durable spillover question.

DESIGN ONLY — three-option matrix (GCS / in-cluster S3 / remote AWS S3),
recommendation, implementation sketch. Implementation is a separate
follow-up round. Cap: 0 PRs (decision doc only).

## Trigger prompts (paste into Codex as each round comes up)

Each round's trigger prompt lives in its scripts/*_msg.txt file. All
four can be fired in any order or skipped entirely depending on
priority. Recommended order matches the alphabet listing here
(smallest first):

1. A — 14th authoring rule (5-10 minutes of Codex time)
2. B — Ollama on GKE (~30-60 minutes; depends on Ollama image pull + model warm-up)
3. C — Amadeus production switch (~30 minutes; code-only if production secrets not provisioned)
4. D — Cloud-tier decision doc (~45-60 minutes of analysis)

## Why all four are non-blocking

The session has reached its true completion point. Travel agent + platform
are production-validated across kind + GKE + Cloudflare Pages. The four
remaining items are:

- **A** — process learning, doesn't change any behavior.
- **B** — fills a provider gap on GKE (Ollama still works on kind).
- **C** — production-grade Amadeus when wanted (test API still works for daily smokes).
- **D** — decision before any future implementation; can wait indefinitely.

No deadline on any of them. Fire as appetite + priority dictates.

## After A, B, C, D — what remains?

Genuinely nothing in scope from this session. The platform is feature-complete
for the travel arc + storage + multi-provider + multi-surface. New work
would be a new flagship arc or whatever the team picks up next.
