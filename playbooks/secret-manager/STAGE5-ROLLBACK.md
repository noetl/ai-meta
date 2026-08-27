# Stage 5 rollback — re-add the secretKeyRef fallbacks

Stage 5 removes the `secretKeyRef` env bindings so the CSI-projected Secret
Manager files are the **sole** source. There is no fallback afterwards, so this
file exists **before** the removal, not after it.

The k8s Secrets `noetl-secret` and `noetl-internal-api-token` are **NOT deleted**
by stage 5 — they stay exactly so these commands work.

⚠ While both paths are live the FILE wins (`file_unusable` is reported rather
than a silent fallback). Re-adding the env alone therefore does not move the
source back to `env` — it restores a *fallback*. To force the env path, also
unset the matching `_FILE` variable (second command in each block).

⚠ Container names differ from kind: system pools are `noetl-worker`, the control
plane is `noetl-server`.

## 1. System pools — NOETL_INTERNAL_API_TOKEN

```bash
for D in noetl-worker-system-pool noetl-worker-system-pool-shard1; do
  kubectl -n noetl patch deploy "$D" --type=strategic -p '{"spec":{"template":{"spec":{"containers":[{
    "name":"noetl-worker","env":[{"name":"NOETL_INTERNAL_API_TOKEN","valueFrom":{"secretKeyRef":{
      "name":"noetl-internal-api-token","key":"token"}}}]}]}}}}'
done

# only if you also need the ENV path to win:
kubectl -n noetl set env deploy/noetl-worker-system-pool        NOETL_INTERNAL_API_TOKEN_FILE-
kubectl -n noetl set env deploy/noetl-worker-system-pool-shard1 NOETL_INTERNAL_API_TOKEN_FILE-

# verify (do NOT infer from the rollout)
kubectl -n noetl exec deploy/noetl-worker-system-pool -c noetl-worker -- \
  wget -qO- 127.0.0.1:9090/metrics | grep secret_source_total
```

## 2. Control plane — all three

```bash
kubectl -n noetl patch deploy noetl-server-rust --type=strategic -p '{"spec":{"template":{"spec":{"containers":[{
  "name":"noetl-server","env":[
    {"name":"POSTGRES_PASSWORD","valueFrom":{"secretKeyRef":{"name":"noetl-secret","key":"NOETL_PASSWORD"}}},
    {"name":"NOETL_ENCRYPTION_KEY","valueFrom":{"secretKeyRef":{"name":"noetl-secret","key":"NOETL_ENCRYPTION_KEY"}}},
    {"name":"NOETL_INTERNAL_API_TOKEN","valueFrom":{"secretKeyRef":{"name":"noetl-internal-api-token","key":"token"}}}
  ]}]}}}}'

# only if you also need the ENV path to win:
kubectl -n noetl set env deploy/noetl-server-rust \
  NOETL_ENCRYPTION_KEY_FILE- POSTGRES_PASSWORD_FILE- NOETL_INTERNAL_API_TOKEN_FILE-

# verify functionally — provenance alone is not enough here
kubectl -n noetl exec deploy/noetl-server-rust -c noetl-server -- \
  wget -qO- 127.0.0.1:8082/metrics | grep -E 'secret_source_total|build_info'
kubectl -n noetl exec deploy/noetl-server-rust -c noetl-server -- \
  wget -qO- 127.0.0.1:8082/health
```

⚠ `POSTGRES_PASSWORD` binds to key **`NOETL_PASSWORD`**, not to the
same-named `POSTGRES_PASSWORD` key in `noetl-secret` — that key is unused
(noetl/ai-meta#300). Re-adding it against the wrong key yields a wrong password
and a server that cannot reach Postgres.

## After stage 5

Secret Manager is the sole source, so the Postgres-password rotation
(noetl/ai-meta#304) only needs a new SM version — the k8s Secret no longer feeds
the running process. Do not rotate as part of stage 5.
