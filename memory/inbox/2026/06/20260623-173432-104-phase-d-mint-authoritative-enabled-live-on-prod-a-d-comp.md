# #104 Phase D mint-authoritative ENABLED LIVE on prod (A–D complete)
- Timestamp: 2026-06-23T17:34:32Z
- Author: Kadyapam
- Tags: noetl,104,phase-d,result-tier,prod,mint-authoritative,dual-write,enabled,live

## Summary
2026-06-23: NOETL_RESULT_MINT_AUTHORITATIVE=true LIVE + LEFT ON on prod GKE (noetl-demo-19700101 ns noetl) — staged result-tier enablement A-D now complete. Flag on system-pool (authoritative Feather/GCS materializer cell usc1-a; log 'AUTHORITATIVE Feather tier; #104 Phase D authoritative=true') + server (dual-write counter) ONLY. NOT worker-rust: the materializer spawn is gated 'materializer_enabled() OR mint_authoritative()' (worker/src/result_materializer.rs:154) so the flag there spawns a STRAY result materializer at the wrong cell (local-0, no NOETL_RESULT_CELL_* env) that fans out as worker-rust autoscales 1->20; ops#204 templates the flag on system-pool only; worker-rust already resolves from the tier via Phase C (RESULT_URI_RESOLVE=true) so D there was redundant. Set it on worker-rust briefly, captured result_mint_authoritative_total{path=tier}=2 as one-time consume-path proof, then removed. URN->Feather/GCS tier is now AUTHORITATIVE result store; noetl.result_store kept as reversible dual-write fail-safe. Validated 6 over-budget execs (1200-row producer->settle->consume, tenant-segregated phased-mint*/phased-soak*): Feather object ONLY at env=prod/cell=usc1-a (no local-0 stray), result_store_dual_write_total 1:1 with execs + result_store row each, resolved_feather correct (row_count=1200/deep_id=1100/test_passed=true), event-mat sole-writer projected==acked==135 dup=0, lag(noetl_materializer)=0, never-scan state_build_event_scans=0, 0 restarts, 0 gcs/adc auth errors. Off-server CQRS gate (PUBLISH_ONLY=true+STATE_BUILDER=offserver), cell env, CPU limit 2 preserved; GC/DR OFF. Revert armed: kubectl -n noetl set env deploy/noetl-worker-system-pool deploy/noetl-server-rust NOETL_RESULT_MINT_AUTHORITATIVE-. Remaining (gated, NOT touched): OQ5 byte-source re-plumb (materializer fetches payload FROM result_store today) + noetl.result_store retirement + OQ5 soak. #104 stays OPEN. #104 comment 4781800172; wiki ai-meta-wiki@6986afa.

## Actions
-

## Repos
-

## Related
-
