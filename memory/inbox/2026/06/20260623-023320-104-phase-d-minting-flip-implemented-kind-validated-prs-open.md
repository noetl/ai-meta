# #104 Phase D minting flip implemented + kind-validated; PRs OPEN; OQ5 is the open decision
- Timestamp: 2026-06-23T02:33:20Z
- Author: Kadyapam
- Tags: noetl,104,phase-d,result-storage,minting-flip,kind-validated,oq5,prs-open

## Summary
#104 Phase D (the minting flip) is implemented + kind-validated (3-pass green) and IN REVIEW — PRs unmerged, no ai-meta pointer bump, no prod change, flag default-off. One flag NOETL_RESULT_MINT_AUTHORITATIVE makes the URN->Feather/GCS tier the AUTHORITATIVE result store: worker materializer = authoritative tier writer (implies Phase B flag), resolve-by-URN = primary consume path (implies Phase C flag); server keeps writing noetl.result_store as the reversible DUAL-WRITE fallback (new counter noetl_result_store_dual_write_total; consume fallback noetl_worker_result_mint_authoritative_total{path=tier|legacy_fallback}). Tier write stays worker-side (slim control plane can't encode Feather, OQ7). PRs: server#263 (config flag+dual-write counter, 613 tests) / worker#129 (the flip, 247 tests) / ops#204 (system-pool flag default off) / e2e#78 (kind_validate_result_mint_authoritative.sh). Kind gate-ON+fake-gcs: PASS1 tier-authoritative(gcs put d4)+dual-write(row+d1)+resolve-from-tier(gcs get d2, mint{tier} d2) 1200 rows; PASS2 flag-off no-op(all d0)+parity; PASS3 forced tier-miss(object deleted pre-consume)->rollback to result_store(mint{legacy_fallback} d1, fallback_object_miss d1) 1200 rows; sole-writer every leg. Images localhost/noetl-{server,worker}:104-phase-d built (podman --pull=never + empty DOCKER_CONFIG to dodge docker-credential-gcloud), kind init container uses curlimages/curl:8.7.1 (don't wildcard set-image over it). Baseline restored to :104-phase-c. OQ5 (result_store retirement window) FRAMED on #104 as the open owner decision before any prod minting cutover — NOT decided; prerequisite: materializer fetches payload FROM result_store so retirement needs re-plumbing the tier-write byte source. On merge: release server/worker -> bump pointers -> close-out. #104 stays OPEN (Phase E/F remain).

## Actions
-

## Repos
-

## Related
-
