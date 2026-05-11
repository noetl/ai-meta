# Handed Path A — gateway terminal surface trace + gui v1.11.0 bump to Codex

- date: 2026-05-11T13:00:00Z
- tags: gke, gui-gap, gateway-terminal, cloudflare-pages, discovery-round, codex-handoff

## Round goal

Close the AMBER GUI gap from round 20260511-110000. The GKE parity-sync
round established that there's NO `noetl-gui` Deployment in the GKE noetl
namespace, so the gateway terminal page Kadyapam sees at
`noetl@gateway:/travel$` is served from somewhere else. Codex's job:
trace where, then ship gui v1.11.0 to that surface.

## Strong candidates per earlier memory

- Cloudflare Pages SPA served at `https://mestumre.dev`, with Cloudflare
  Tunnel exposing `gateway.mestumre.dev` to the private GKE Gateway
  ClusterIP (per the older `automation/cloudflare/gke_gateway_edge.yaml`
  playbook entry in current.md).
- Embedded static build in the noetl-server image (older topology).
- Separate gateway service in a different namespace.

Discovery-first round — investigate before acting.

## Five phases

1. Trace the gateway surface — browser DOM/network, repo
   (cloudflare/gke_gateway_edge.yaml + gui workflows + helm values),
   Cloudflare API read-only inspection.
2. Identify the bump mechanism — Case A (auto-tracks main), Case B (pinned
   to tag/branch), Case C (manual ops playbook).
3. Execute the bump — case-specific path. AMBER + STOP if blocked on
   tokens or build failure.
4. Smoke the gateway terminal — reproduce Kadyapam's original failing
   sequence; screenshots.
5. Close out — result file, update the AMBER sync issue, write a memory
   entry naming the gateway hosting surface so future rounds find it.

## Cap

0 PRs if Case A (just refresh + verify) or Case C (run an existing
playbook with the right inputs). 1 small PR if Case B (a pin source
needs to flip). No code changes either way.

## Bridge artefacts

- `bridge/inbox/delegated/20260511-130000-gateway-terminal-surface-and-gui-bump.task.json`
- `scripts/gateway_terminal_surface_and_gui_bump_msg.txt`

## What success looks like

Future rounds searching `memory/inbox/` for "gateway terminal" find a
clear answer to "where is it served from + how does it get updated"
in one search. The original AMBER sync issue at
`sync/issues/2026-05-11-gke-deployment-drift-and-storage-tier-audit.md`
has the GUI gap section closed.

Plus Kadyapam can type `travel <query>` in the gateway terminal and
get the same widget-rendering UX that works on local kind.

## Trigger prompt for Codex (paste this in after pushing)

```
Path A from the AMBER GKE parity-sync. Locate where the gateway terminal
at noetl@gateway:/travel$ is actually served from, then ship gui v1.11.0
to that surface.

Bridge task: bridge/inbox/delegated/20260511-130000-gateway-terminal-surface-and-gui-bump.task.json
Prompt details: scripts/gateway_terminal_surface_and_gui_bump_msg.txt
Result file: bridge/outbox/20260511-130000-gateway-terminal-surface-and-gui-bump.result.json
Sync issue to update: sync/issues/2026-05-11-gke-deployment-drift-and-storage-tier-audit.md

Strong candidates per earlier memory notes:
  - Cloudflare Pages SPA at https://mestumre.dev + Cloudflare Tunnel to
    private GKE Gateway ClusterIP (see automation/cloudflare/gke_gateway_edge.yaml)
  - Embedded static build in the noetl-server image
  - Separate gateway service in a different namespace

Discovery-first. Investigate before acting.

Run all 5 phases per the bridge task:
  1. Trace the gateway surface (browser DOM, repo wiring, Cloudflare read inspection).
  2. Identify the bump mechanism (Case A auto-tracks main / B pinned / C manual playbook).
  3. Execute the bump — AMBER + STOP if blocked on tokens or build failure.
  4. Smoke gateway terminal: ls → cd /mcp/amadeus → tools (5 expected) →
     travel help → travel flights → travel --provider anthropic help. Screenshots.
  5. Close out — result + sync issue update + memory entry naming the surface.

Architectural rules:
  - Pointer/version bumps only. No code changes.
  - Don't rotate or generate Cloudflare API tokens — Kadyapam owns those.
  - Don't change deployment topology — bump existing pointers, don't redesign.
  - Don't touch storage tier configuration (Path B, separate round).
  - Don't deploy ollama-bridge to GKE.
  - Don't cut a release.
  - No git push from ai-meta.

If surface is unknown after Phase 1, document what was tried and where the
trace ran out — Kadyapam knows the actual topology.
```

## What's after this lands

The arc reaches its closer. Remaining items, all explicitly deferred:

- **Path B — storage tier decision** (GCS vs S3 vs persistent-volume vs
  leave-as-is). NOETL_DEFAULT_STORAGE_TIER=kv, worker-local disk
  spillover, S3 as cloud tier (not GCS) — odd in a GCP project.
- Ollama bridge deployment on GKE.
- Amadeus production API switch.
- Travel runtime workaround cleanup once v2.37.8 stable.
- Process rule: pin "kind deploys need a chained GKE-parity round" as
  a 14th authoring guide rule.
