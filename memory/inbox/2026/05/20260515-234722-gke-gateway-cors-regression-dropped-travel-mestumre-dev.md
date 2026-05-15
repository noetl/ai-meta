# GKE gateway CORS regression dropped travel.mestumre.dev
- Timestamp: 2026-05-15T23:47:22Z
- Author: Kadyapam
- Tags: gke,gateway,cors,travel,regression,hotfix

## Summary
Helm release gateway v114 (deployed 2026-05-15 ~18:30Z) shipped CORS_ALLOWED_ORIGINS without https://travel.mestumre.dev / http://travel.mestumre.dev, so Firefox on travel.mestumre.dev got NetworkError when attempting to fetch resource on every gateway call (preflight returned 200 but with no access-control-allow-origin echo). Helm chart default (repos/ops/automation/helm/gateway/values.yaml) and the fresh-stack playbook default (gateway_cors_allowed_domains: 'travel.mestumre.dev' in repos/ops/automation/gcp_gke/noetl_gke_fresh_stack.yaml) both still include travel, so the regression came from a deploy invocation that passed --set workload.gateway_cors_allowed_domains (or equivalent) and replaced the default without re-listing travel. In-cluster hotfix: kubectl set env -n gateway deployment/gateway CORS_ALLOWED_ORIGINS=... including https://travel.mestumre.dev,http://travel.mestumre.dev; rolled new pod gateway-596d6ffc88; preflight from Origin https://travel.mestumre.dev now echoes access-control-allow-origin. The patch is NOT persisted -- next helm upgrade overwrites it unless the playbook invocation passes the full allowed-domains list. Follow-up doc updates landed in repos/ops gcp_gke README and repos/docs cloudflare pages-gui-tunnel-gateway runbook.

## Actions
-

## Repos
-

## Related
-
