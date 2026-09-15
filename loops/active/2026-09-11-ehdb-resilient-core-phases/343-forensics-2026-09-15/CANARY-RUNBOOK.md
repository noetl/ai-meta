# Canary runbook — worker#315 (externalised-result hydration)

Staged 2026-09-15. Execute only on owner go-ahead.

## 0. Rollback artifact (captured, verify before rolling)

    deploy/noetl-worker-rust               sha256:6f20890b8c22ec5c8a840670ace63dff0b9c8faeb9829b5981fa2ee5c5051843
    deploy/noetl-worker-system-pool        (same)
    deploy/noetl-worker-system-pool-shard1 (same)
    sts/noetl-cmdbus-writer                sha256:c13b2957999f0bc15fe56b91a3005e7bfecd16bbbf51135c3ee641f2510e7466

Rollback (one command, ~20 s):
    kubectl -n noetl set image deploy/noetl-worker-rust \
      worker=us-central1-docker.pkg.dev/shastaratech-noetl-prod/noetl/noetl-worker-rust@sha256:6f20890b…51843

## 1. Merge + tag  (owner, or me if authorized)

    gh pr ready 315 -R noetl/worker && gh pr merge 315 -R noetl/worker --squash
    # then tag per semantic-release; release.yml triggers on the tag and
    # builds via Cloud Build into us-central1-docker.pkg.dev/.../noetl-worker-rust

## 2. Wait for the CI digest

    gh run list -R noetl/worker --workflow release.yml --limit 3
    gcloud artifacts docker images list \
      us-central1-docker.pkg.dev/shastaratech-noetl-prod/noetl/noetl-worker-rust \
      --include-tags --sort-by=~UPDATE_TIME --limit=3

## 3. Canary ONE deployment only

`noetl-worker-rust` only. Leave `noetl-worker-system-pool`,
`…-shard1`, and `sts/noetl-cmdbus-writer` on the old digest — the writer
especially, since it hosts the EHDB tier service.

    kubectl -n noetl set image deploy/noetl-worker-rust worker=<NEW_DIGEST>
    kubectl -n noetl rollout status deploy/noetl-worker-rust --timeout=6m

## 4. Verify end-to-end (the validation blocked all day)

    kubectl port-forward -n noetl svc/noetl 8082:8082 &
    curl -s -X POST http://localhost:8082/api/execute \
      -H 'Content-Type: application/json' -d '{
        "path":"muno/playbooks/hotel-cards",
        "payload":{"city":"Monterey, California","latitude":36.6002,"longitude":-121.8947,
                   "radius":20,"check_in":"2026-11-02","check_out":"2026-11-06",
                   "adults":2,"rooms":1,"children":0,"limit":20,"max_rooms":10,"price_bands":4}}'

PASS requires ALL of:
  - `count` > 1  (was 0 — or 1 from the truncated sample)
  - `deref_error` is null
  - hotels carry `images[]` with many entries (provider returned 66/20/200/114/109)
  - `rooms[]` spread across `priceBands`
  - room-level `images[]` where HotelBeds attributed them

Also re-run a FLIGHTS search — it must stay green (it never crossed the budget,
so it is the regression canary for over-resolution):

    one-way JFK→MCO, expect ~4 offers, logos + city + airport_name populated

## 5. Watch for regression (the fix's one risk is over-resolving)

    kubectl -n noetl logs deploy/noetl-worker-rust --tail=200 | grep -iE "resolve|kept as summary"
    # latency per step, and worker error rate

Roll back immediately if: step latency rises materially, resolve errors appear,
or any previously-working search returns fewer results.

## 6. If green, promote

Roll the remaining worker deployments to the same digest, one at a time.
`sts/noetl-cmdbus-writer` last and separately — it hosts the tier service and a
restart there is the thing that cleared the 38 h stall earlier today.

## 7. Record

Append to the ai-meta forensics dir and, if the playbook-registration ledger
lands (FOLLOW-UPS-FOR-OWNER.md item c), record the digest + git sha there.
