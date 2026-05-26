# Wikis bootstrapped for all six remaining production submodules; gateway gets v2.11.0 coverage
- Timestamp: 2026-05-24T18:47:28Z
- Author: Kadyapam
- Tags: wikis,bootstrap,gateway,v2.11.0,docs

## Summary
User enabled wikis on noetl/gateway, noetl/cli, noetl/doctor, noetl/e2e, noetl/gui, noetl/apt (created Home pages). Added all six as ai-meta submodules under repos/noetl-{gateway,cli,doctor,e2e,gui,apt}-wiki. The gateway wiki was bootstrapped with full v2.11.0 coverage (6 pages, ~1000 lines): Home + Sidebar + architecture (module map, request flows) + sse-events (full frame catalog incl. new playbook/state and subscription/event v2.11.0 frames) + subscriptions (POST/DELETE /api/subscriptions/firestore, Python sidecar architecture, credential provisioning) + configuration (env var reference with platform-runtime vs business-logic classification) + deployment (Docker, k8s manifests, Cloudflare Tunnel, health checks, rollout/rollback). Wiki commit b98c7e8 on gateway. The other five wikis got Home-only stubs (cli 2e6694e, doctor 8be7368, e2e 54c6440, gui 96c1a3f, apt 3e60c94) — each frames the repo's role and cross-links into the broader docs, ready to grow as those repos see bumps. agents/rules/wiki-maintenance.md updated: gap list cleared (all production submodules now have wikis), all nine wiki submodules listed in the Tooling section. Total state after this turn: 9 wikis, 8 submodule pointers added. Per Rule 1b, future pointer bumps in any of these repos will coordinate with their wiki.

## Actions
-

## Repos
-

## Related
-
