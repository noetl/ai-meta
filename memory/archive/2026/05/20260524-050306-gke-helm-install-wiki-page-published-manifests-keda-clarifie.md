# GKE Helm install wiki page published; manifests-keda clarified for kind vs GKE profile
- Timestamp: 2026-05-24T05:03:06Z
- Author: Kadyapam
- Tags: wiki,docs,gke,helm,option-a

## Summary
Wrote repos/noetl-ops-wiki/automation-gcp-gke.md (~390 lines) covering: topology (Cloud SQL+PgBouncer+Helm NATS+chart-templated KEDA), prerequisites, install via noetl_gke_fresh_stack.yaml, upgrade flow (with the --reuse-values does-not-merge-new-defaults gotcha that PR #116 surfaced), verify checklist, tuning (KEDA / PgBouncer / Cloud SQL HA), and common pitfalls (HPA fight, live-patching, consumer drift, stale Pending PVCs). Updated Home.md + _Sidebar.md to surface it. Patched manifests-keda.md to add a profile-note distinguishing the kind artifact (account: NOETL, nats.nats.svc) from the GKE chart-rendered artifact (account: $G, nats-headless); the original page presented kind values as universal which was misleading post-#116. Cross-references to ai-meta decision doc and ops PRs #115/#116/#600. Wiki commit bfd81eb.

## Actions
-

## Repos
-

## Related
-
