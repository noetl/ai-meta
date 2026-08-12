#!/usr/bin/env bash
# Put the ai-meta#257 PR 4 gate on the kind cluster, at MULTIPLE worker replicas.
#
#   deploy.sh load                — load both gate images into the kind node
#   deploy.sh writer              — arm the writer's tier service (:9110 + store)
#   deploy.sh arm local   [N]     — N replicas, tier reads resolve POD-LOCAL
#   deploy.sh arm service [N]     — N replicas, tier reads resolve through the writer
#   deploy.sh point <host:port>   — repoint ONLY the tier-service address (mutation)
#   deploy.sh relay <pod-ip|svc>  — pin the server's relay at one specific replica
#   deploy.sh restore             — released images, zero EHDB env, pool back to 0
#
# THE POINT OF THE REPLICA COUNT. The #258 gate ran single-replica and said so:
# the tier store is pod-local, so with N replicas it is N disjoint fragments and
# a read answers from whichever pod the relay's Service routed to. That gate
# could not have caught it. This one is built to.
#
# The two arms differ in exactly one variable, `NOETL_EHDB_TIER_QUERY_SOURCE`,
# set on the worker replicas. Images, replica count, mirror source, relay URL,
# tier mode and the writer's configuration are all held constant, so a
# difference in the verdict is attributable to that flag and to nothing else.
set -euo pipefail

export KIND_EXPERIMENTAL_PROVIDER=podman
SRV_IMG="${SRV_IMG:-localhost/noetl-server:pr4real}"
WK_IMG="${WK_IMG:-localhost/noetl-worker:pr4real}"

NS=noetl
WORKER_DEPLOY=noetl-worker-rust
WORKER_CTR=worker
WRITER_STS=noetl-cmdbus-writer
WRITER_CTR=noetl-worker
# Stable per-pod DNS for the writer: the tier service must resolve to ONE
# process, which is the entire premise. The headless service would round-robin.
TIER_ADDR="${TIER_ADDR:-noetl-cmdbus-writer-0.noetl.svc.cluster.local:9110}"
# Inside the writer's durable PVC, matching what prod would do — the writer is
# the process that owns ReadWriteOnce volumes, which is why it hosts this face.
TIER_DIR=/data/eventbus/tier
RELAY_SVC=http://noetl-worker-rust-metrics.noetl.svc.cluster.local:9090

k() { kubectl --context kind-noetl -n "$NS" "$@"; }

# `kubectl rollout status` returning is not the same as the endpoint serving.
# A gate that starts against a terminating pod reads empty bodies and reports
# them as failures of the thing under test.
wait_server() {
  local i
  for i in $(seq 1 60); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://localhost:8082/api/health)" = "200" ] \
      && { sleep 3; return 0; }
    sleep 2
  done
  echo "server never answered /api/health" >&2; return 1
}

load() {
  local tmp
  for img in "$SRV_IMG" "$WK_IMG"; do
    tmp=$(mktemp -t kindloadXXXXXX).tar
    podman save -o "$tmp" "$img"
    kind load image-archive "$tmp" --name noetl
    rm -f "$tmp"
    echo "loaded: $img"
  done
  # Positive control on the load itself. `kind load` has reported success for an
  # image the node did not end up with; naming both tags here means a silent
  # miss fails now rather than as an unexplained old-behaviour gate result.
  echo "-- present in the node --"
  local found
  found=$(podman exec noetl-control-plane crictl images | grep -c pr4real || true)
  podman exec noetl-control-plane crictl images | grep pr4real || true
  [ "$found" -ge 2 ] || { echo "FAILED: expected 2 pr4real images in the node, found $found" >&2; return 1; }
}

writer() {
  echo "-- writer: tier service up, store on the PVC --"
  k set image "sts/$WRITER_STS" "$WRITER_CTR=$WK_IMG"
  k set env "sts/$WRITER_STS" \
      NOETL_EHDB_ENABLED=true \
      NOETL_EHDB_TIER_SERVICE_BIND=0.0.0.0:9110 \
      NOETL_EHDB_TIER_SERVICE_DIR="$TIER_DIR"
  k rollout status "sts/$WRITER_STS" --timeout=240s
  echo "writer armed: :9110 -> $TIER_DIR"
}

arm() {
  local source="$1" replicas="${2:-3}"
  case "$source" in local|service) ;; *) echo "arm must be local|service" >&2; exit 2;; esac

  echo "-- worker pool: $replicas replicas, NOETL_EHDB_TIER_QUERY_SOURCE=$source --"
  k set image "deploy/$WORKER_DEPLOY" "$WORKER_CTR=$WK_IMG"
  k set env "deploy/$WORKER_DEPLOY" \
      NOETL_EHDB_ENABLED=true \
      NOETL_EHDB_CLIENT_ROLE=worker \
      NOETL_EHDB_EVENTLOG=shadow \
      NOETL_EHDB_LOCAL_REFERENCE_LOG=/tmp/ehdb/ref.jsonl \
      NOETL_EHDB_EVENTLOG_MIRROR_SOURCE=server \
      NOETL_EHDB_TIER_SERVICE_ADDR="$TIER_ADDR" \
      NOETL_EHDB_TIER_QUERY_SOURCE="$source"
  # NOT `kubectl scale`. A KEDA ScaledObject with
  # `autoscaling.keda.sh/paused-replicas: "0"` REVERTS a manual scale within
  # seconds, and a 0-replica Deployment reports "successfully rolled out" — so
  # the scale looks like it worked and the gate then runs at zero replicas.
  # Pinning through the annotation is the lever KEDA actually honours.
  k annotate scaledobject "$WORKER_DEPLOY" \
      "autoscaling.keda.sh/paused-replicas=$replicas" --overwrite
  # Positive control: assert the pods exist rather than trusting the rollout.
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
      NOETL_EHDB_CROSSSTORE_PARITY_ENABLED=true \
      NOETL_EHDB_CROSSSTORE_PARITY_INTERVAL_SECS=0 \
      NOETL_EHDB_WORKER_QUERY_URL="$RELAY_SVC" \
      NOETL_EHDB_EVENTLOG_MIRROR_SOURCE=server
  k rollout status deploy/noetl-server-rust --timeout=240s
  wait_server
  echo "armed: source=$source replicas=$replicas"
}

# Repoint the tier-service address without touching anything else. This is the
# mutation: aim the workers at a tier service whose store does NOT hold the
# execution, and the verdict must change. If it does not, the read never left
# the pod.
point() {
  local addr="$1"
  k set env "deploy/$WORKER_DEPLOY" NOETL_EHDB_TIER_SERVICE_ADDR="$addr"
  k rollout status "deploy/$WORKER_DEPLOY" --timeout=300s
  echo "tier-service address now: $addr"
}

# Pin the server's relay at ONE replica by pod IP. The headless Service picks a
# pod per connection, which is the failure being demonstrated but is useless for
# measuring it — "which replica answered" has to be the controlled variable.
relay() {
  local target="$1"
  k set env deploy/noetl-server-rust NOETL_EHDB_WORKER_QUERY_URL="$target"
  k rollout status deploy/noetl-server-rust --timeout=240s
  wait_server
  echo "relay pinned at: $target"
}

restore() {
  k set env "deploy/$WORKER_DEPLOY" \
      NOETL_EHDB_ENABLED- NOETL_EHDB_CLIENT_ROLE- NOETL_EHDB_EVENTLOG- \
      NOETL_EHDB_LOCAL_REFERENCE_LOG- NOETL_EHDB_EVENTLOG_MIRROR_SOURCE- \
      NOETL_EHDB_TIER_SERVICE_ADDR- NOETL_EHDB_TIER_QUERY_SOURCE- || true
  k set image "deploy/$WORKER_DEPLOY" "$WORKER_CTR=ghcr.io/noetl/worker:5.115.3-arm64"
  # Back to the paused-at-zero state the cluster was left in.
  k annotate scaledobject "$WORKER_DEPLOY" \
      "autoscaling.keda.sh/paused-replicas=0" --overwrite
  k scale "deploy/$WORKER_DEPLOY" --replicas=0

  k set env "sts/$WRITER_STS" \
      NOETL_EHDB_ENABLED- NOETL_EHDB_TIER_SERVICE_BIND- NOETL_EHDB_TIER_SERVICE_DIR- || true
  k set image "sts/$WRITER_STS" "$WRITER_CTR=ghcr.io/noetl/worker:5.115.3-arm64"

  k set env deploy/noetl-server-rust \
      NOETL_EHDB_CROSSSTORE_PARITY_ENABLED- NOETL_EHDB_CROSSSTORE_PARITY_INTERVAL_SECS- \
      NOETL_EHDB_EVENTLOG_MIRROR_SOURCE- || true
  k set env deploy/noetl-server-rust NOETL_EHDB_WORKER_QUERY_URL="$RELAY_SVC"
  k set image deploy/noetl-server-rust \
     "$(k get deploy noetl-server-rust -o jsonpath='{.spec.template.spec.containers[0].name}')=ghcr.io/noetl/server:3.79.2"
  k rollout status deploy/noetl-server-rust --timeout=240s
  k rollout status "sts/$WRITER_STS" --timeout=240s
  echo "restored"
}

case "${1:-}" in
  load)    load ;;
  writer)  writer ;;
  arm)     arm "${2:-service}" "${3:-3}" ;;
  point)   point "${2:?need host:port}" ;;
  relay)   relay "${2:?need a URL}" ;;
  restore) restore ;;
  *) echo "usage: deploy.sh {load|writer|arm <local|service> [N]|point <host:port>|relay <url>|restore}" >&2; exit 2 ;;
esac
