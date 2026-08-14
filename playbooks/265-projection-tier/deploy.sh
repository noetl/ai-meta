#!/usr/bin/env bash
# Put the ai-meta#265 projection-tier gate on the kind cluster, MULTI-REPLICA.
#
#   deploy.sh load                  — load both gate images into the kind node
#   deploy.sh writer                — arm the writer's tier service (:9110 + store)
#   deploy.sh arm <mode> [N]        — N worker replicas; mode ∈ off|shadow|primary
#   deploy.sh point <host:port>     — repoint ONLY the tier-service address (mutation)
#   deploy.sh corrupt               — rewrite the newest projection record in the store
#   deploy.sh drop                  — empty the projection store, leave the event log
#   deploy.sh bypass                — disarm the server's projection mirror only
#   deploy.sh restore               — released images, EHDB projection env cleared
#
# WHY MULTI-REPLICA. The projection tier has no pod-local write path at all
# (#265 A1), so every replica's mirror resolves to the writer's single store —
# but that is a claim about the code, and a gate that ran at one replica could
# not tell it from the pod-local behaviour it replaces. Three replicas is what
# makes "one store" a measurement.
#
# The arms differ in exactly ONE variable each. `arm` moves
# `NOETL_EHDB_PROJECTION`; `bypass` moves `NOETL_EHDB_PROJECTION_MIRROR_SOURCE`;
# `point` moves `NOETL_EHDB_TIER_SERVICE_ADDR`. Images, replica count, relay URL
# and the writer's configuration are held constant, so a change in the verdict
# is attributable to the one variable that moved.
set -euo pipefail

export KIND_EXPERIMENTAL_PROVIDER=podman
SRV_IMG="${SRV_IMG:-localhost/noetl-server:265proj}"
WK_IMG="${WK_IMG:-localhost/noetl-worker:265proj}"

NS=noetl
WORKER_DEPLOY=noetl-worker-rust
WORKER_CTR=worker
WRITER_STS=noetl-cmdbus-writer
WRITER_CTR=noetl-worker
# Stable per-pod DNS: the tier service must resolve to ONE process, which is the
# premise. The headless service would round-robin.
TIER_ADDR="${TIER_ADDR:-noetl-cmdbus-writer-0.noetl.svc.cluster.local:9110}"
TIER_DIR=/data/eventbus/tier
RELAY_SVC=http://noetl-worker-rust-metrics.noetl.svc.cluster.local:9090

k() { kubectl --context kind-noetl -n "$NS" "$@"; }
writer_pod() { k get pod -l app=noetl-cmdbus-writer -o name | head -1; }

wait_server() {
  local i pods streak=0
  for i in $(seq 1 90); do
    pods=$(k get pods -l app=noetl-server-rust --no-headers 2>/dev/null | grep -c Running || true)
    if [ "${pods:-0}" -eq 1 ] \
       && [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://localhost:8082/api/health)" = "200" ]; then
      streak=$((streak+1)); [ "$streak" -ge 3 ] && { sleep 2; return 0; }
    else
      streak=0
    fi
    sleep 2
  done
  echo "server never settled" >&2; return 1
}

load() {
  local tmp found
  for img in "$SRV_IMG" "$WK_IMG"; do
    tmp=$(mktemp -t kindloadXXXXXX).tar
    podman save -o "$tmp" "$img"
    kind load image-archive "$tmp" --name noetl
    rm -f "$tmp"
    echo "loaded: $img"
  done
  # Positive control on the load. `kind load` has reported success for an image
  # the node did not end up with; a silent miss then presents as an unexplained
  # old-behaviour gate result rather than as a load failure.
  echo "-- present in the node --"
  podman exec noetl-control-plane crictl images | grep 265proj || true
  found=$(podman exec noetl-control-plane crictl images | grep -c 265proj || true)
  [ "$found" -ge 2 ] || { echo "FAILED: expected 2 265proj images in the node, found $found" >&2; return 1; }
}

writer() {
  echo "-- writer: tier service up, store on the PVC --"
  k set image "sts/$WRITER_STS" "$WRITER_CTR=$WK_IMG"
  k set env "sts/$WRITER_STS" \
      NOETL_EHDB_ENABLED=true \
      NOETL_EHDB_TIER_SERVICE_BIND=0.0.0.0:9110 \
      NOETL_EHDB_TIER_SERVICE_DIR="$TIER_DIR" \
      NOETL_EHDB_PROJECTION_MIRROR_SOURCE=server \
      NOETL_EHDB_PROJECTION=shadow
  k rollout status "sts/$WRITER_STS" --timeout=300s
  echo "writer armed: :9110 -> $TIER_DIR (projection appends accepted)"
}

arm() {
  local mode="$1" replicas="${2:-3}"
  case "$mode" in off|shadow|primary) ;; *) echo "arm must be off|shadow|primary" >&2; exit 2;; esac

  echo "-- worker pool: $replicas replicas, NOETL_EHDB_PROJECTION=$mode --"
  k set image "deploy/$WORKER_DEPLOY" "$WORKER_CTR=$WK_IMG"
  k set env "deploy/$WORKER_DEPLOY" \
      NOETL_EHDB_ENABLED=true \
      NOETL_EHDB_CLIENT_ROLE=worker \
      NOETL_EHDB_EVENTLOG=shadow \
      NOETL_EHDB_LOCAL_REFERENCE_LOG=/tmp/ehdb/ref.jsonl \
      NOETL_EHDB_EVENTLOG_MIRROR_SOURCE=server \
      NOETL_EHDB_PROJECTION="$mode" \
      NOETL_EHDB_PROJECTION_MIRROR_SOURCE=server \
      NOETL_EHDB_TIER_SERVICE_ADDR="$TIER_ADDR" \
      NOETL_EHDB_TIER_QUERY_SOURCE=service
  # The writer makes the serve decision for records the server mirrors, so its
  # tier mode has to move WITH the pool or the flip is only half applied.
  k set env "sts/$WRITER_STS" NOETL_EHDB_PROJECTION="$mode" \
      NOETL_EHDB_TIER_SERVICE_ADDR="$TIER_ADDR" \
      NOETL_EHDB_TIER_QUERY_SOURCE=service
  k rollout status "sts/$WRITER_STS" --timeout=300s

  # NOT `kubectl scale`. A KEDA ScaledObject with `paused-replicas: "0"` reverts
  # a manual scale within seconds, and a 0-replica Deployment reports
  # "successfully rolled out" — so the scale looks fine and the gate runs at zero.
  k annotate scaledobject "$WORKER_DEPLOY" \
      "autoscaling.keda.sh/paused-replicas=$replicas" --overwrite >/dev/null
  local ready
  for _ in $(seq 1 60); do
    ready=$(k get deploy "$WORKER_DEPLOY" -o jsonpath='{.status.readyReplicas}')
    [ "${ready:-0}" -ge "$replicas" ] && break
    sleep 5
  done
  ready=$(k get deploy "$WORKER_DEPLOY" -o jsonpath='{.status.readyReplicas}')
  [ "${ready:-0}" -ge "$replicas" ] || {
    echo "FAILED: wanted $replicas ready replicas, have ${ready:-0}" >&2; exit 1; }
  echo "   $ready replicas ready"

  echo "-- server --"
  k set image "deploy/noetl-server-rust" \
     "$(k get deploy noetl-server-rust -o jsonpath='{.spec.template.spec.containers[0].name}')=$SRV_IMG"
  k set env deploy/noetl-server-rust \
      NOETL_EHDB_PROJECTION_PARITY_ENABLED=true \
      NOETL_EHDB_PROJECTION_MIRROR_SOURCE=server \
      NOETL_EHDB_WORKER_QUERY_URL="$RELAY_SVC"
  k rollout status deploy/noetl-server-rust --timeout=300s
  wait_server
  echo "armed: projection=$mode replicas=$replicas"
}

point() {
  local addr="$1"
  k set env "deploy/$WORKER_DEPLOY" NOETL_EHDB_TIER_SERVICE_ADDR="$addr"
  k rollout status "deploy/$WORKER_DEPLOY" --timeout=300s
  echo "tier-service address now: $addr"
}

# MUTATION 1 — corrupt the content of the newest projection record in the
# writer's store, leaving its `version` intact.
#
# This is the corruption the comparator exists for and the one a count-based
# check cannot see: every record is present, the versions line up, and the tier
# holds different bytes for the revision it claims. The expected verdict is
# `checksum`, NOT `stale_version`.
corrupt() {
  local pod; pod=$(writer_pod)
  k exec "$pod" -- sh -c "
    f=$TIER_DIR/projection.jsonl
    [ -s \"\$f\" ] || { echo 'NOTHING TO CORRUPT: projection store is empty or absent' >&2; exit 3; }
    before=\$(wc -l < \"\$f\")
    # Rewrite the checksum inside the LAST record's payload only.
    sed -i '\$s/\"checksum\\\\\":\\\\\"[0-9a-f]*/\"checksum\\\\\":\\\\\"deadbeefdeadbeefdeadbeefdeadbeef/' \"\$f\"
    after=\$(wc -l < \"\$f\")
    [ \"\$before\" = \"\$after\" ] || { echo 'record count changed — this mutation must only rewrite content' >&2; exit 3; }
    echo \"corrupted the newest of \$after record(s)\"
  "
}

# MUTATION 2 — empty the projection store, leave the event-log store untouched.
#
# Two things at once: the comparator must report `missing_execution`, AND the
# event-log tier's verdict must be unaffected. If emptying one store moved the
# other tier's verdict, the two tiers share a store and the whole per-tier
# separation is fiction.
drop() {
  local pod; pod=$(writer_pod)
  k exec "$pod" -- sh -c "
    f=$TIER_DIR/projection.jsonl
    e=$TIER_DIR/eventlog.jsonl
    [ -s \"\$f\" ] || { echo 'NOTHING TO DROP: projection store is empty or absent' >&2; exit 3; }
    el_before=\$(wc -l < \"\$e\" 2>/dev/null || echo 0)
    : > \"\$f\"
    el_after=\$(wc -l < \"\$e\" 2>/dev/null || echo 0)
    [ \"\$el_before\" = \"\$el_after\" ] || { echo 'the event-log store moved too — the stores are NOT separate' >&2; exit 3; }
    echo \"projection store emptied; event log still holds \$el_after record(s)\"
  "
}

# MUTATION 3 — disarm the server's projection mirror ONLY.
#
# Everything else stays: the tier service is up, the store is there, the
# comparator is on, the event-log mirror keeps running. A fresh execution must
# then produce a projection divergence and NO event-log divergence. This is what
# separates "the comparator measures the projection mirror" from "the comparator
# measures whether anything is running at all".
bypass() {
  k set env deploy/noetl-server-rust NOETL_EHDB_PROJECTION_MIRROR_SOURCE=worker
  k rollout status deploy/noetl-server-rust --timeout=300s
  wait_server
  echo "server projection mirror DISARMED (event-log mirror still armed)"
}

restore() {
  k annotate scaledobject "$WORKER_DEPLOY" \
      "autoscaling.keda.sh/paused-replicas=0" --overwrite >/dev/null || true
  k set env deploy/noetl-server-rust \
      NOETL_EHDB_PROJECTION_PARITY_ENABLED- NOETL_EHDB_PROJECTION_MIRROR_SOURCE- || true
  k set env "deploy/$WORKER_DEPLOY" NOETL_EHDB_PROJECTION- NOETL_EHDB_PROJECTION_MIRROR_SOURCE- || true
  k set env "sts/$WRITER_STS" NOETL_EHDB_PROJECTION- NOETL_EHDB_PROJECTION_MIRROR_SOURCE- || true
  echo "restored (projection-tier env cleared; images left as-is)"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  load) load ;;
  writer) writer ;;
  arm) arm "$@" ;;
  point) point "$@" ;;
  corrupt) corrupt ;;
  drop) drop ;;
  bypass) bypass ;;
  restore) restore ;;
  *) sed -n '2,20p' "$0"; exit 2 ;;
esac
