# 2026-05-11 — Gateway terminal surface traced to Cloudflare Pages, deploy blocked on token

The GKE GUI parity follow-up traced the browser terminal surface.

Finding:

- The GUI is served from Cloudflare Pages at `https://mestumre.dev`.
- The API/gateway endpoint is `https://gateway.mestumre.dev`.
- The existing deployment mechanism is `repos/ops/automation/cloudflare/gke_gateway_edge.yaml`.
- That playbook builds `repos/gui` with `VITE_API_MODE=gateway`, `VITE_GATEWAY_URL=https://gateway.mestumre.dev`, and deploys `dist` with `wrangler pages deploy --project-name noetl-gui --branch main`.
- GKE still has the `gateway` service/deployment and the `cloudflare/noetl-gke-gateway-tunnel` deployment running; the missing surface is not a Kubernetes `gui` deployment.

Why the round closed AMBER:

- `CLOUDFLARE_API_TOKEN` was not present.
- `wrangler pages project list` failed in non-interactive mode because a Cloudflare API token is required.
- No Cloudflare project, tunnel, DNS, or Pages deployment was modified.
- The public browser session opened `https://mestumre.dev/login`; without a session/token and without a successful Pages deploy, the gateway terminal smoke sequence was not run.

Version note:

- `noetl/gui` release `v1.11.0` exists at commit `831ba66`.
- The current local submodule had been at `74f97f9`, the feature commit that `v1.11.0` wraps with the semantic-release version bump.
- The live Pages bundle contains the `/travel` route and app-form field support, but does not contain the terminal prompt's travel command strings (`usage: travel`, `started travel agent`, `automation/agents/travel/runtime`), so it is older than the fully expected gateway-terminal bundle.

Future handoff:

- Export a scoped `CLOUDFLARE_API_TOKEN` locally, then run the existing playbook with `action=pages` or `action=deploy`.
- Do not redesign topology. The surface is Cloudflare Pages plus Cloudflare Tunnel to GKE Gateway.
- Keep Cloudflare tokens out of ai-meta and result files.
