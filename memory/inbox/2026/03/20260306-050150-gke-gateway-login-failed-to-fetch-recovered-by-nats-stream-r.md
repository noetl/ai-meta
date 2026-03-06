# GKE gateway login failed-to-fetch recovered by NATS stream reset
- Timestamp: 2026-03-06T05:01:50Z
- Author: Kadyapam
- Tags: gke,gateway,auth,cors,nats,noetl,incident

## Summary
Investigated CORS-like browser failure for https://mestumre.dev login. Root cause was NoETL worker crash-loop due NOETL_COMMANDS stream retention=WorkQueue conflicting with worker consumer deliver_policy=new; this caused backend 502 and Cloudflare returned generic 502 page without CORS headers. Reset stream and restarted noetl deployments; login endpoint now responds with proper CORS headers and JSON errors/status.

## Actions
- Verified gateway CORS config included `https://mestumre.dev` and preflight worked:
  `curl -i -X OPTIONS https://gateway.mestumre.dev/api/auth/login -H 'Origin: https://mestumre.dev' -H 'Access-Control-Request-Method: POST'`.
- Confirmed backend failure signature in `noetl-server` logs:
  `Failed to publish command: nats: no response from stream`.
- Confirmed worker crash-loop root cause in `noetl-worker` logs:
  `consumer must be deliver all on workqueue stream`.
- Inspected JetStream and found `NOETL_COMMANDS` had `Retention: WorkQueue`, which is incompatible with worker consumer config.
- Deleted bad stream and allowed NoETL runtime to recreate it with expected config:
  `kubectl -n nats exec deploy/nats-box -- nats --server nats://noetl:noetl@nats.nats.svc.cluster.local:4222 stream rm NOETL_COMMANDS -f`.
- Restarted NoETL control plane/workers:
  `kubectl -n noetl rollout restart deployment/noetl-server deployment/noetl-worker`.
- Verified recovery:
  `NOETL_COMMANDS` recreated with `Retention: Limits` and subject `noetl.commands`;
  consumer `noetl_worker_pool` exists; workers returned to ready state (`2/2`).
- Verified gateway endpoint behavior through Cloudflare:
  `POST /api/auth/login` now returns JSON 401 with `Access-Control-Allow-Origin: https://mestumre.dev` for invalid token input (no browser-level CORS block).

## Repos
- `repos/noetl` (runtime behavior referenced from `noetl/core/messaging/nats_client.py`)
- GKE cluster `gke_noetl-demo-19700101_us-central1_noetl-cluster`

## Related
- UI origin: `https://mestumre.dev`
- Gateway API: `https://gateway.mestumre.dev/api/auth/login`
