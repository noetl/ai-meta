# Travel gateway CORS tunnel hotfix

Date: 2026-05-13

Kadyapam reminded that Travel reaches the NoETL gateway through the Cloudflare
Tunnel to GKE. The remaining failure was on that browser-to-tunnel edge:
`POST https://gateway.mestumre.dev/api/auth/login` never reached the auth
playbook because browser CORS preflight did not allow Travel's origin.

Observed before fix:

- `Origin: https://mestumre.dev` returned
  `access-control-allow-origin: https://mestumre.dev`.
- `Origin: https://travel.mestumre.dev` returned HTTP 200 to OPTIONS but no
  `access-control-allow-origin`.
- `Origin: http://127.0.0.1:5173` returned HTTP 200 to OPTIONS but no
  `access-control-allow-origin`.

Live mitigation:

- Upgraded `noetl-gateway` Helm release in namespace `gateway` to revision 112.
- Set `CORS_ALLOWED_ORIGINS` to:
  `http://localhost:3001,http://localhost:5173,http://127.0.0.1:5173,https://mestumre.dev,https://travel.mestumre.dev,https://gateway.mestumre.dev`
- `kubectl -n gateway rollout status deployment/gateway --timeout=300s`
  completed successfully.

Durable fix:

- `noetl/ops#89` merged at
  `16e0ef7559340b515d33a8bd4cfbdc6948ac9226`.
- `automation/helm/gateway/values.yaml` now includes Travel + Vite dev origins.
- `automation/gcp_gke/noetl_gke_fresh_stack.yaml` now includes
  `travel.mestumre.dev` in default gateway CORS domains and adds
  `localhost:5173` / `127.0.0.1:5173` when localhost origins are included.

Post-fix probes:

- OPTIONS preflight returns `access-control-allow-origin` for
  `https://travel.mestumre.dev`, `http://localhost:5173`, and
  `http://127.0.0.1:5173`.
- Invalid-token POST returns HTTP 401 with `access-control-allow-origin` for
  those origins, proving the browser can now send the gateway login request.

Next expected browser smoke: after Auth0 redirects back to Travel, the gateway
auth playbook should start. If auth fails now, it should be a real gateway
login/playbook error rather than a preflight block.
