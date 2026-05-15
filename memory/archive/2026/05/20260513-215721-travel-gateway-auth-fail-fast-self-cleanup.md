# Travel gateway auth fail-fast and self-cleanup

## Context

During the Travel/Muno browser smoke, login reached Auth0 successfully but then hung at the gateway-link step. The browser-side Travel build aborts gateway auth after 15 seconds, while the Gateway default waited 60 seconds for the NoETL auth playbook callback. When NoETL workers were unhealthy or saturated, users saw a stuck login state and had no safe recovery path except an operator-side rollout restart.

Live probes showed:

- `https://gateway.mestumre.dev/api/auth/login` CORS preflight for `https://travel.mestumre.dev` was healthy.
- An invalid-token login POST initially timed out after 20 seconds with no response.
- Gateway logs showed the auth login playbook was submitted, then waited for callback.
- NoETL worker logs showed long-running nested playbooks and Postgres pool waiting.
- Restarting `deployment/noetl-worker` and `deployment/noetl-server` restored fast auth failure: invalid tokens returned `401` immediately.

## Change

Implemented a fail-fast gateway auth guard:

- Gateway auth playbook timeout default changes from 60 seconds to 12 seconds, which is below Travel's 15-second frontend timeout.
- `POST /api/auth/login` and `POST /api/auth/check-access` now time-box both the NoETL execute call and the callback wait.
- On callback timeout, Gateway cancels its pending callback and best-effort cancels the NoETL execution with `cascade=true`, preventing timed-out auth attempts from accumulating as hidden running work.
- Timeout responses now return `503 Service Unavailable` with a retryable "auth backend is busy" message instead of hanging until the browser aborts.
- The GKE gateway Helm chart now passes `AUTH_PLAYBOOK_TIMEOUT_SECS=12` explicitly.

## Shipped

- Gateway PR: noetl/gateway#10, merged as `c410c1494cb489bbef366d258a722e84f2760054`, released as `v2.10.1`.
- Ops PR: noetl/ops#90, merged as `7437a035546f407d455b1038530d3548db355716`.
- GKE gateway rollout: `ghcr.io/noetl/gateway:v2.10.1`, Helm revision 113, `AUTH_PLAYBOOK_TIMEOUT_SECS=12`.
- Post-rollout slow-backend probe: invalid Auth0 token returned `503` after 12 seconds with a retryable auth-backend-busy message, proving the browser no longer hangs past its own timeout.
- One cleanup rollout of `deployment/noetl-worker` and `deployment/noetl-server` cleared the active backlog.
- Post-cleanup probe: invalid Auth0 token against `https://gateway.mestumre.dev/api/auth/login` returned `401` in about one second, confirming the route is responsive again.

## Lesson

For gateway-mediated auth, the gateway timeout must be shorter than the SPA fetch timeout, and any timed-out auth playbook must be cancelled server-side. Otherwise the user sees a frozen login while the cluster keeps spending worker capacity on an already-abandoned request.

This does not replace deeper worker-health work. If NoETL workers are repeatedly saturated or unable to complete auth playbooks, the platform still needs a separate worker-health / queue-isolation round. This patch makes the failure user-safe and self-cleaning instead of silent and manually recoverable only by restart.
