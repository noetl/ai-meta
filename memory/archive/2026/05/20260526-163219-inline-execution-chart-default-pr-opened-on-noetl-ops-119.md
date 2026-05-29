# Inline-execution chart-default PR opened on noetl/ops #119
- Timestamp: 2026-05-26T16:32:19Z
- Author: Kadyapam
- Tags: noetl,ops,helm,inline-execution,pr-119,gke,enforce

## Summary
Round B's NOETL_INLINE_TRIVIAL_CHILDREN env var has been baked into the helm chart (config.worker.NOETL_INLINE_TRIVIAL_CHILDREN: off as conservative default) and the GKE demo cluster's helm overrides via noetl_inline_trivial_children: enforce workload variable. Open as draft PR https://github.com/noetl/ops/pull/119 on branch kadyapam/inline-trivial-children-chart-default (commit fe3a36c). Changes: (1) automation/helm/noetl/values.yaml adds NOETL_INLINE_TRIVIAL_CHILDREN: off to config.worker block with documentation. (2) automation/gcp_gke/noetl_gke_fresh_stack.yaml adds workload.noetl_inline_trivial_children: enforce, --set config.worker.NOETL_INLINE_TRIVIAL_CHILDREN flag in helm upgrade, and NOETL_INLINE_TRIVIAL_CHILDREN- in the kubectl set env cleanup so any pre-existing direct override stops shadowing the chart value. Operators on other clusters get the conservative off default (no behavior change). After merge: helm upgrade on the GKE demo cluster will leave worker on enforce durably across future helm runs. No noetl-source change needed; this is operational manifest only.

## Actions
-

## Repos
-

## Related
-
