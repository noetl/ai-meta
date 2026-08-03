#!/usr/bin/env bash
# Bring the LOCAL KIND cluster to the EHDB-only topology (noetl/ai-meta#209/#221).
#
# Imperative on purpose: it mirrors how prod was actually cut over, and the
# existing kind manifests in repos/ops are all NATS-era, so a re-apply would
# undo this. Every step is idempotent — re-running is safe.
#
# Refuses to run against anything but kind-noetl. There is no gcloud here and
# none is needed.
set -euo pipefail

CTX="${CTX:-kind-noetl}"
NS=noetl
WRITER_IMG="${WRITER_IMG:-localhost/noetl-worker:h5209}"
SERVER_IMG="${SERVER_IMG:-localhost/noetl-server-rust:ehdbonly}"
HERE="$(cd "$(dirname "$0")" && pwd)"

if [[ "$CTX" != kind-* ]]; then
  echo "REFUSING: CTX=$CTX is not a kind context. This script is kind-only." >&2
  exit 1
fi
k() { kubectl --context "$CTX" -n "$NS" "$@"; }

WRITER_DNS=noetl-cmdbus-writer.noetl.svc.cluster.local

echo "== 0. PVCs + Service (all six events faces incl. 9107 KV / 9108 WAL) =="
kubectl --context "$CTX" apply -f "$HERE/ehdb-only-kind.yaml"

echo "== 1. writer pod: host BOTH the command bus and the events feed =="
# STRATEGIC merge, not `--type merge`: a JSON merge patch REPLACES the whole
# containers array, which silently wipes every env var the container had.
# Strategic merge keys the list on `name` and merges in place.
k patch deployment noetl-cmdbus-writer -p "$(cat <<EOF
{"spec":{"template":{"spec":{
  "containers":[{"name":"noetl-worker","image":"${WRITER_IMG}","imagePullPolicy":"Never",
    "ports":[
      {"name":"cmdbus-ingest","containerPort":9100},
      {"name":"cmdbus-claim","containerPort":9101},
      {"name":"cmdbus-lag","containerPort":9102},
      {"name":"metrics","containerPort":9090},
      {"name":"events-ingest","containerPort":9103},
      {"name":"events-claim","containerPort":9104},
      {"name":"events-sse","containerPort":9105},
      {"name":"events-lag","containerPort":9106},
      {"name":"events-kv","containerPort":9107},
      {"name":"events-wal","containerPort":9108}],
    "volumeMounts":[
      {"name":"cmdbus-data","mountPath":"/data/cmdbus"},
      {"name":"eventbus-data","mountPath":"/data/eventbus"},
      {"name":"eventbus-kv","mountPath":"/data/eventkv"}]}],
  "volumes":[
    {"name":"cmdbus-data","persistentVolumeClaim":{"claimName":"noetl-cmdbus-writer-data"}},
    {"name":"eventbus-data","persistentVolumeClaim":{"claimName":"noetl-eventbus-writer-data"}},
    {"name":"eventbus-kv","persistentVolumeClaim":{"claimName":"noetl-eventbus-kv-data"}}]
}}}}
EOF
)"

# The writer is a singleton over an RWO volume: Recreate, never RollingUpdate.
k patch deployment noetl-cmdbus-writer --type merge \
  -p '{"spec":{"strategy":{"type":"Recreate","rollingUpdate":null},"replicas":1}}'

# Every `>` MUST be quoted — an unquoted one is a shell redirect, and the
# resulting truncated filter (`noetl.commands.cmdbus.`) resolves to a different
# pool. That exact class of silent mis-routing is noetl/ai-meta#218.
k set env deployment/noetl-cmdbus-writer \
  WORKER_POOL_NAME=cmdbus-writer \
  NOETL_SERVER_URL=http://noetl-server-rust.noetl.svc.cluster.local:8082 \
  WORKER_MAX_CONCURRENT=1 \
  WORKER_METRICS_BIND=0.0.0.0:9090 \
  RUST_LOG='info,noetl_worker=info,ehdb_feed=info' \
  NOETL_COMMAND_BUS_SHARD=0 \
  NOETL_COMMAND_SHARD_COUNT=1 \
  NOETL_COMMAND_BUS_WRITER_DIR=/data/cmdbus \
  NOETL_COMMAND_BUS_INGEST_BIND=0.0.0.0:9100 \
  NOETL_COMMAND_BUS_CLAIM_BIND=0.0.0.0:9101 \
  NOETL_COMMAND_BUS_METRICS_BIND=0.0.0.0:9102 \
  NOETL_COMMAND_BUS_ACK_WAIT_SECS=30 \
  NOETL_COMMAND_BUS=ehdb \
  NOETL_COMMAND_BUS_HOST=true \
  NOETL_EVENT_BUS_HOST=true \
  NOETL_EVENT_BUS_SHARD=0 \
  NOETL_EVENT_SHARD_COUNT=1 \
  NOETL_EVENT_BUS_WRITER_DIR=/data/eventbus \
  NOETL_EVENT_BUS_KV_DIR=/data/eventkv \
  NOETL_EVENT_BUS_INGEST_BIND=0.0.0.0:9103 \
  NOETL_EVENT_BUS_CLAIM_BIND=0.0.0.0:9104 \
  NOETL_EVENT_BUS_SSE_BIND=0.0.0.0:9105 \
  NOETL_EVENT_BUS_METRICS_BIND=0.0.0.0:9106 \
  NOETL_EVENT_BUS_KV_BIND=0.0.0.0:9107 \
  NOETL_EVENT_BUS_WAL_BIND=0.0.0.0:9108 \
  NOETL_EVENT_BUS_ACK_WAIT_SECS=30 \
  NOETL_EVENT_BUS_CURSOR_PERSIST_SECS=5 \
  NOETL_EVENT_BUS_CURSOR_FALLBACK=tail \
  NOETL_COMMAND_BUS_CLAIM_ADDR=127.0.0.1:9101 \
  NOETL_FEED_FILTER_SUBJECT='noetl.commands.cmdbus.>' \
  NATS_URL- NATS_STREAM- NATS_CONSUMER-

echo "== 2. server: publish commands AND events to EHDB =="
k set image deployment/noetl-server-rust noetl-server="${SERVER_IMG}"
k patch deployment noetl-server-rust \
  -p '{"spec":{"template":{"spec":{"containers":[{"name":"noetl-server","imagePullPolicy":"Never"}]}}}}'
k set env deployment/noetl-server-rust \
  NOETL_COMMAND_BUS=ehdb \
  NOETL_EVENT_BUS=ehdb \
  NOETL_COMMAND_BUS_INGEST_ADDRS="0@${WRITER_DNS}:9100" \
  NOETL_EVENT_BUS_WRITER_ADDRS="0@${WRITER_DNS}:9103" \
  NOETL_EVENT_INGEST_PUBLISH_ONLY=true \
  NOETL_STATE_BUILDER=server \
  NOETL_NATS_URL-

echo "== 3. system pool: all three materializer groups + the WAL drain, on EHDB =="
# H5 (noetl/ai-meta#221) makes every one of these *_SOURCE vars mandatory: unset
# is now a hard error instead of a silent fall-through to the deleted NATS bus.
# That is the point — a typo here should crashloop, not stall a flat cursor.
#
# Shadow is `NOETL_STATE_BUILDER_SHADOW=true`, NOT `NOETL_STATE_BUILDER=shadow`.
# `builder_mode()` only recognises `offserver` on that var and otherwise falls
# through to a SEPARATE flag, so `NOETL_STATE_BUILDER=shadow` reads as a
# perfectly sensible value and silently means **Off** — the drain never starts
# and :9108 never gets a client. Found the hard way in this soak: the WAL face
# was bound with zero connections. Same silent-default class as H5.
k set env deployment/noetl-worker-system-pool \
  NOETL_COMMAND_BUS=ehdb \
  NOETL_COMMAND_BUS_HOST=false \
  NOETL_COMMAND_BUS_CLAIM_ADDR="${WRITER_DNS}:9101" \
  NOETL_FEED_FILTER_SUBJECT='noetl.commands.system.>' \
  NOETL_EVENT_BUS_CLAIM_ADDR="${WRITER_DNS}:9104" \
  NOETL_EVENT_BUS_WAL_ADDR="${WRITER_DNS}:9108" \
  NOETL_MATERIALIZER_ENABLED=true \
  NOETL_MATERIALIZER_SOURCE=ehdb \
  NOETL_RESULT_MATERIALIZER_ENABLED=true \
  NOETL_RESULT_MATERIALIZER_SOURCE=ehdb \
  NOETL_STATE_SHARD_WRITE=true \
  NOETL_STATE_MATERIALIZER_SOURCE=ehdb \
  NOETL_STATE_BUILDER_SHADOW=true \
  NOETL_STATE_BUILDER_SOURCE=ehdb \
  NATS_URL- NATS_STREAM- NATS_CONSUMER-
k set image deployment/noetl-worker-system-pool noetl-worker="${WRITER_IMG}"
k patch deployment noetl-worker-system-pool \
  -p '{"spec":{"template":{"spec":{"containers":[{"name":"noetl-worker","imagePullPolicy":"Never"}]}}}}'

echo "== 4. user pool: claim commands off EHDB =="
k set env deployment/noetl-worker-rust \
  NOETL_COMMAND_BUS=ehdb \
  NOETL_COMMAND_BUS_HOST=false \
  NOETL_COMMAND_BUS_CLAIM_ADDR="${WRITER_DNS}:9101" \
  NOETL_FEED_FILTER_SUBJECT='noetl.commands.shared.>' \
  NATS_URL- NATS_STREAM- NATS_CONSUMER-
k set image deployment/noetl-worker-rust worker="${WRITER_IMG}"
k patch deployment noetl-worker-rust \
  -p '{"spec":{"template":{"spec":{"containers":[{"name":"worker","imagePullPolicy":"Never"}]}}}}'

# The second system shard is a #166 artifact and has no shard-1 writer here.
k scale deployment noetl-worker-system-pool-shard1 --replicas=0 2>/dev/null || true

echo "== 5. wait for rollouts (writer first — everything addresses it) =="
k rollout status deployment/noetl-cmdbus-writer --timeout=180s
k rollout status deployment/noetl-server-rust --timeout=180s
k rollout status deployment/noetl-worker-system-pool --timeout=180s
k rollout status deployment/noetl-worker-rust --timeout=180s

echo "== done =="
k get pods -o wide
