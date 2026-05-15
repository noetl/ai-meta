# Session refresh after cleanup-repo bumps
- Timestamp: 2026-05-03T18:00:00Z
- Author: Kadyapam (assisted)
- Tags: sync,cleanup,memory,refresh

## Summary

Picked up from `c31e6f9 chore(sync): bump cli cleanup repos to merged SHAs`.
All submodules now at clean merged tips after the post-MCP-architecture
cleanup arc landed across noetl/cli, noetl/apt, noetl/docs, noetl/ops,
noetl/gui, noetl/e2e, and noetl/homebrew-tap.

## Submodule state at refresh

| repo | pinned SHA | branch/tag |
|---|---|---|
| `repos/apt` | `ac8776d` | `kadyapam/current-amd64-cli-index` |
| `repos/cli` | `a384806` | `v2.13.0-3-ga384806` |
| `repos/docs` | `3afa226` | main (post Cloudflare runbook merges) |
| `repos/e2e` | `bbff2f7` | main (post auth0 login repair) |
| `repos/gateway` | `3084cda` | `v2.10.0-2-g3084cda` |
| `repos/gui` | `2809bd9` | `v1.4.0-4-g2809bd9` |
| `repos/homebrew-tap` | `1a9aef1` | main |
| `repos/noetl` | `1bf22d0` | `v2.5.5-878-g1bf22d08` |
| `repos/noetl.io` | `1b6d222` | main |
| `repos/ops` | `2c9989f` | main (post Cloudflare edge playbook + MCP role docs) |

## What landed in the cleanup arc (since the 2026-04-29 MCP session)

Recent inbox entries documenting the post-session work:

- `20260430-033833-gke-gateway-auth0-login-repair.md` — fixed
  `api_integration/auth0/auth0_login` after distributed-runtime
  output-shape changes. Catalog version 76 in GKE; smoke returns 200.
- `20260430-060200-gke-private-gui-profile-live.md` — private GUI
  profile live on GKE.
- `20260430-063754-cloudflare-pages-gui-and-cloud-run-gateway-runbook-merged.md` —
  initial Cloudflare runbook (Cloud Run gateway variant).
- `20260430-070605-cloudflare-tunnel-for-gke-gateway-docs-merged.md` —
  tunnel-fronted GKE gateway runbook.
- `20260430-150030-cloudflare-gke-edge-deployment-playbook-merged.md` —
  `automation/cloudflare/gke_gateway_edge.yaml` (`noetl/ops#21`) for
  end-to-end Cloudflare Pages GUI + Cloudflare Tunnel → private GKE
  Gateway ClusterIP. Multiple gateway hostnames supported. Requires
  scoped `CLOUDFLARE_API_TOKEN` (not Global API Key).

`memory/current.md` already reflects the Cloudflare Pages + Tunnel
posture (last modified 2026-04-30T15:00:48Z).

## Backlog still open

`sync/issues/2026-04-29-mcp-architecture-backlog.md` carries the
six follow-ups from the MCP architecture session that haven't been
promoted to GitHub Issues yet:

- #37 `playbooks` terminal listing pagination + filter (gui)
- #51 Mcp tab + Add-MCP wizard (gui)
- #74 GUI prompt: context-aware lifecycle verbs (gui)
- #78 bake mcp-server reader RBAC into chart values (ops)
- #79 investigate failed:True on otherwise-successful lifecycle.deploy (ops)
- #80 GUI prompt: support `&&` to chain commands (gui)

The Cloudflare Pages + Tunnel work doesn't touch any of those —
they're still the right next leads when MCP feature work resumes.

## Architecture state

Eight architectural pieces shipped on 2026-04-29 are all merged
and deployed:

- Phase 1: Mcp resource lifecycle endpoint (noetl ≥ 2.26)
- Phase 2: server-side `check_playbook_access` (noetl ≥ 2.27)
- Phase 3: ops kubernetes MCP lifecycle agent fleet (ops main)
- Phase 4: friendly run dialog + Mcp tile renderer (gui ≥ 1.3)
- Supporting: catalog kind authority, DSL schema regen,
  register-time validation, 422-status preservation, helm+kubectl
  in worker image, kind:shell distributed executor, worker
  cluster RBAC, GUI release timeout fix, prompt action label CSS.

The post-session cleanup arc added the Cloudflare edge layer on
top: Pages-served GUI + Tunnel-fronted Gateway, GKE keeps NoETL
server/workers/NATS/PgBouncer private.

## How to keep this current

- Submodule pointer bumps go in `chore(sync):` commits — already
  the established pattern, no change needed.
- Inbox entries (one per merged PR or significant deploy) keep the
  paper trail; `memory/current.md` carries the rolled-up "active
  focus" view that should be readable as a standalone status page.
- Backlog items live in `sync/issues/<date>-<topic>.md`. Promote
  to GitHub Issues when external tracking helps; otherwise edit
  in place when items close.

## Related

- `memory/inbox/2026/04/20260429-060000-mcp-architecture-end-to-end-running.md`
- `sync/issues/2026-04-29-mcp-architecture-backlog.md`
- `memory/current.md`
