# Docs widget tutorial deployed + local LAN access note
- Timestamp: 2026-05-09T01:26:26Z
- Author: codex
- Tags: docs,widgets,tutorial,cloudflare-pages,local-kind,podman,lan-access

## Summary
Docs#44 (AI-OS docs text pass) and docs#45 (widget rendering tutorial) are deployed through the `noetl/docs` Cloudflare Pages workflow. The docs deploy run for docs#44 was `25583351913` and completed successfully at `2026-05-08T22:51:40Z`; docs#45 merged at `65cc1360a2f26b426bb665e54377e0f78cfbe501` and deploy run `25584544097` completed successfully. Public docs paths verified from the host: `https://noetl.dev/docs/gui/catalog-ux`, `https://noetl.dev/docs/gui/widgets`, and `https://noetl.dev/docs/tutorials/widget-rendering/`. The new tutorial explains emitting `result.render`, verifying nested `render.args` with `noetl status --json`, rendering in the terminal-style prompt via `report <execution_id>`, button `event.key: command`, and unsupported-widget fallback.

## Local LAN access note
Current local kind context is `kind-noetl`, running under Podman only. `kubectl -n noetl get svc` shows `gui` as NodePort `30081` and `noetl-ext` / server API exposed on host port `8082` through the kind control-plane container. `podman ps` confirms `0.0.0.0:30081->30081/tcp` and `0.0.0.0:8082->30082/tcp`; `lsof` shows `gvproxy` listening on `*:30081` and `*:8082`. Host LAN IP during verification was `192.168.1.240`. From another machine on the same network, use `http://192.168.1.240:30081/` for the GUI and `http://192.168.1.240:8082/api/health` or `noetl --server http://192.168.1.240:8082 ...` for CLI/API access. Both `curl http://192.168.1.240:30081/` and `curl http://192.168.1.240:8082/api/health` returned healthy responses from the host.

## Actions
- Added `docs/tutorials/06-widget-rendering.md` in noetl/docs#45.
- Cross-linked the tutorial from `docs/gui/widgets.md`.
- Ran `npm run build` and `git diff --check` in `repos/docs`.
- Merged docs#45 and bumped the `repos/docs` submodule pointer in ai-meta with local commit `e9c060e`.

## Repos
- `repos/docs`: `65cc1360a2f26b426bb665e54377e0f78cfbe501`
- `ai-meta`: local pointer bump `e9c060e` pending user push

## Related
- docs#44: https://github.com/noetl/docs/pull/44
- docs#45: https://github.com/noetl/docs/pull/45
- Cloudflare Pages deploy run for docs#45: https://github.com/noetl/docs/actions/runs/25584544097

## Follow-up: GUI prompt Network Error from another machine
After opening `http://192.168.1.240:30081/` from another LAN machine, `noetl@kind:/catalog$ ls` returned `Network Error`. Root cause was GUI runtime config still pointing at `VITE_API_BASE_URL=http://localhost:8082`; from another machine, browser `localhost` refers to that other machine, not the Mac hosting Podman/kind. Local cluster health was fine: `curl http://192.168.1.240:8082/api/health` returned `{"status":"ok"}`, CORS preflight from origin `http://192.168.1.240:30081` returned 200, and pods were healthy. Applied local runtime patch: `kubectl -n noetl set env deploy/gui VITE_API_BASE_URL=http://192.168.1.240:8082 VITE_APP_VERSION=v1.8.0`, then waited for rollout. Verified `/env-config.js` now reports `VITE_API_BASE_URL: "http://192.168.1.240:8082"`. Future local LAN GUI redeploys need the API base URL set to the host LAN IP or another LAN-routable hostname, not `localhost`.
