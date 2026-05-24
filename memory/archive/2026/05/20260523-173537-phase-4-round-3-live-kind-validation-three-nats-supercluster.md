# Phase 4 round 3 live-kind validation — three NATS supercluster bugs caught + fixed (PR #596)
- Timestamp: 2026-05-23T17:35:37Z
- Author: Kadyapam
- Tags: noetl,v2-spec,phase4,nats-supercluster,validation,live-kind,bugfix,milestone

## Summary
End-to-end validation of Phase 4 round 3 in local kind cluster caught three real bugs in the NATS supercluster generator. Fixed in PR #596 (noetl v2.100.1). (1) NATS refused to start: 'jetstream cluster requires server_name to be set' — fixed by passing pod name via downward API as --name arg. (2) /healthz too aggressive: liveness probe killed pods during 'JetStream is still recovering meta layer' — fixed by split healthz (js-server-only liveness, js-enabled-only readiness, new startupProbe with failureThreshold 60). (3) Headless Service chicken-and-egg: gateway URLs resolve through peer Service DNS, default headless only publishes Ready pods, neither cluster could reach Ready — fixed by publishNotReadyAddresses: true. 31 tests passing (28 + 3 new live-validation guards). Live verification: 5/6 supercluster pods Running (1 Pending due to single-node kind CPU pressure, not a bug); cluster-a /gatewayz outbound to ['b'], cluster-b /gatewayz outbound to ['a'] + inbound from ['a'] — bidirectional supercluster confirmed; URN-derived JetStream domains live. KEDA scaler from PR #594 simultaneously validated: ScaledObject READY=True, HPA created with TARGETS=0/10 (avg), and KEDA actively reconciled noetl-worker from 3 → 1 replicas (zero lag → scale to minReplicaCount) — proving the trigger is operational, not just registered. Lesson: drift-guard tests catch hand-edits but not protocol-level requirements; live-kind validation finds the rest.

## Actions
-

## Repos
-

## Related
-
