# GKE parity sync closes AMBER — catalog + engine parity fixed; GUI gap + storage tier finding

- date: 2026-05-11T12:00:00Z
- tags: gke, parity, deployment-drift, gui-gap, storage-tier, kv-tier, s3-not-gcs, amber, retro

## What landed

- Catalog parity on GKE achieved: travel/runtime, mcp/amadeus, mcp/vertex-ai, mcp/ollama all re-registered at session-current versions
- Item #11 activities-hydration regression GREEN on GKE
- Storage tier audit complete with surprising findings
- Sync issue, result JSON, close-out memory all staged
- No submodule pointer bumps, no code changes, no push

## What's unresolved

**GUI deployment doesn't exist on GKE.** There is NO `gui` or `noetl-gui`
Deployment, Service, or Helm release in the GKE noetl namespace to bump
to `ghcr.io/noetl/gui:v1.11.0`. The bridge task assumed a noetl-gui
deployment exists on GKE the same way it does on kind — that assumption
was wrong.

This means Kadyapam's "`travel` is unknown command" failure on the
gateway terminal isn't a GUI image-version problem — it's coming from
somewhere else entirely. The gateway terminal surface lives somewhere
that wasn't audited in this round.

## Two follow-up rounds the finding implies

**Follow-up A — locate the gateway terminal surface.**
The gateway page showing `noetl@gateway:/travel$` must be served from
somewhere. Candidates:
  - Cloudflare Pages (per the older `current.md` note about
    https://mestumre.dev served via Cloudflare Pages from a separate
    static-site build).
  - A gateway service in the GKE cluster (different namespace? different
    name than noetl-gui?).
  - The static GUI build embedded in the noetl-server image (older
    deployment shape).

Once located, the `travel` command parser update from gui v1.11.0 needs
to be deployed THERE — not to a missing noetl-gui pod. Likely a smaller
round than originally framed because there may be no new infra needed,
just a pointer/image bump at the actual GUI surface.

**Follow-up B — storage tier decision in GCP.**
The audit found a real architectural smell:

- `NOETL_DEFAULT_STORAGE_TIER=kv`
- Large payloads spill to **worker-local disk** at `/opt/noetl/data/disk_cache`
- Router cloud tier is **S3, not GCS**
- GCS is configured but NOT active as the cache tier

Three concerns:

1. **Worker-local disk doesn't survive pod restarts.** Cached results
   vanish on every noetl-worker rollout. Acceptable for ephemeral
   re-read caching; problematic if anyone counts on cached results
   being durable across deployments.

2. **S3 as the cloud tier in a GCP project is unusual.** Either S3 is
   being used cross-cloud (AWS bucket from GKE — cross-cloud egress
   cost on every spill), OR S3 is configured but not reachable so
   spillover silently falls through to local disk. Either way, GCS
   would be the natural choice in this project (same cloud, Workload
   Identity already wired for the worker SA for Vertex AI).

3. **GCS configured but not active** suggests a partial migration or
   a config gap. Worth understanding what state was intended.

The follow-up round here is a decision before implementation:
   - Switch cloud tier from S3 to GCS (likely correct)
   - Keep S3 but verify reachability + document why
   - Move local-disk tier to a persistent volume so cache survives rollouts

Item #11's hydration fix bypasses the tier layer entirely (walks events
table for terminal-result hydration) so this storage-tier question is
orthogonal to current correctness. But it matters for caching efficiency
and for any future feature that depends on durable result spillover.

## What worked correctly

- Catalog re-register via `kubectl port-forward` + `noetl register` —
  established pattern, clean execution.
- Item #11 hydration regression on GKE passed — activities path produces
  real data through the v2.37.8 engine fix.
- Storage tier introspection methodology worked cleanly — read-only env
  inspection + router class introspection answered the GCS question
  definitively.

## Process lesson reinforced

This round's GUI gap is a clear case for the recurring-process rule:

> Any cowork round shipping a GUI image to local kind should also
> verify (and update) the GUI image at the deployed gateway surface,
> OR explicitly defer to a chained parity round with named owners
> for each surface.

The session's round #3 (app:form refinement) shipped gui v1.11.0 to
kind. We assumed the same image would reach the gateway terminal on
GKE via a noetl-gui deployment. It didn't, because the gateway terminal
surface is somewhere else.

## Trigger prompt for Codex (after the next session decides A vs B)

Two paths from here:

**Path A — locate the gateway terminal surface and ship gui v1.11.0
there.** Likely smaller than originally framed. Specific Codex round:
trace what serves `noetl@gateway:/travel$`, identify the right artifact
(Cloudflare Pages deployment? gateway service in a different namespace?
embedded in noetl-server?), bump the GUI commit/image at that surface.
Then re-smoke the gateway terminal.

**Path B — storage tier decision + implementation.** Bigger; requires
a decision first (GCS? persistent volume? leave as-is?), then config
+ deploy + smoke.

Both are deferred. The travel agent is functionally GREEN on GKE for
direct catalog access — only the gateway terminal command parser is
stale. Kadyapam can still drive the travel agent via direct execution
or any non-gateway-terminal surface.
