# Scope B post-validation — fresh kind redeploy + KEDA + supercluster + playbook smoke
- Timestamp: 2026-05-23T21:02:52Z
- Author: Kadyapam
- Tags: noetl,ops,scope-b,validation,keda,nats-supercluster,redeploy,metrics

## Summary
Cluster torn down (noetl/nats/postgres/test-server namespaces) and re-provisioned via 'noetl run automation/development/noetl.yaml --runtime local --set action=deploy --set image_tag=2026-05-22-09-37 --set podman_machine= --set verify_test_server_contract=false' from repos/ops cwd. Three real issues hit + fixed: (1) PV-claimRef sticky after PVC deletion — same problem affected postgres, noetl-data, noetl-logs, noetl-data-pv. Fix per PV: 'kubectl patch pv <name> --type=json -p [{"op":"remove","path":"/spec/claimRef"}]'. Worth automating in a future 'reset' playbook action since this hits every teardown/redeploy cycle. (2) test-server contract verification fails on first deploy because paginated-api hasn't fully bound its port. Workaround: --set verify_test_server_contract=false (or wait + retry). (3) Single kind node hits CPU pressure at ~96% reservation; can't fit (5-cluster supercluster + KEDA + paginated-api + noetl stack + postgres + nats). Scaled supercluster to 0 to free CPU, ran KEDA regression, then restored supercluster at cluster_size=1 (instead of 3) — bidirectional gateway mesh confirmed working with single replicas. Test results: NoETL API healthy, 415 playbooks in catalog (data survived because postgres PV is Retain), test/simple_python execution 0.66s warm steady-state (over 5 runs: 1.2 → 0.97 → 0.73 → 0.67 → 0.66s). DB conns post-validation: server=8 idle (own pool), projector=5 idle, outbox-publisher=2 idle = 15 idle total (matches baseline 11-12 with normal pool variance, no leak). Workers hold 0 conns (NATS-only by design). KEDA regression: scaledobject re-created cleanly post-teardown; 200-message burst scaled noetl-worker 1→12, drained, scaled back to 1 via HPA stabilization. Supercluster regression after scale-up: server_name unique per pod, gateway outbound+inbound both populated, URN-derived JetStream domain (tenant_default_org_default_region_us_east_1_cluster_a) intact. CPU at 78% reservation post-validation — sustainable with current pod set.

## Actions
-

## Repos
-

## Related
-
