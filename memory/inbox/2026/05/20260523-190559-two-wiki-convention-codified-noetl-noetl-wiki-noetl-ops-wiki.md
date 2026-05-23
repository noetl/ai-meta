# Two-wiki convention codified — noetl/noetl wiki + noetl/ops wiki
- Timestamp: 2026-05-23T19:05:59Z
- Author: Kadyapam
- Tags: noetl,ops,wiki,convention,two-wiki,documentation

## Summary
NoETL now has two wikis: github.com/noetl/noetl/wiki for Python API / DSL / core architecture, and github.com/noetl/ops/wiki for Kubernetes manifests + Helm install + deployment automation + infrastructure tuning. Bootstrapped ops wiki with Home + _Sidebar + manifests-keda + manifests-nats-supercluster pages. Migrated install/verify/tuning content from noetl-wiki/runtime/{keda,nats_supercluster}.md (now Python-API-only with prominent 'Operations:' callouts pointing at ops/wiki). Also fixed stale nats_account=$G reference on keda page (PR #597 fixed default to NOETL). ai-meta adds repos/noetl-ops-wiki submodule (baseline e755987) and rule 0 in agents/rules/wiki-maintenance.md codifying which wiki gets what content. Hybrid topics (generators in noetl producing manifests in ops) split across both with cross-link callouts — don't combine on one page. Convention applies going forward; existing noetl-wiki pages migrate to ops-wiki when next touched if their content is operational.

## Actions
-

## Repos
-

## Related
-
