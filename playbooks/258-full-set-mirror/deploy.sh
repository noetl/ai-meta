#!/usr/bin/env bash
# Put the ai-meta#258 gate images and env on the kind cluster.
#
#   deploy.sh load            — load both gate images into the kind node
#   deploy.sh arm server      — server mirrors the full authoritative set
#   deploy.sh arm worker      — pre-change behaviour (the discriminating half)
#   deploy.sh restore         — back to the released images with no EHDB env
#
# The two arms differ in exactly one variable, `NOETL_EHDB_EVENTLOG_MIRROR_SOURCE`,
# set identically on the server and on the worker that receives its appends.
# Everything else — images, tier mode, relay URL — is held constant, so a
# difference in the verdict is attributable to the flag and to nothing else.
set -euo pipefail

export KIND_EXPERIMENTAL_PROVIDER=podman
K="kubectl --context kind-noetl -n noetl"
SRV_IMG="${SRV_IMG:-localhost/noetl-server:258full}"
WK_IMG="${WK_IMG:-localhost/noetl-worker:258full}"

# The user pool is the single worker that holds the tier store AND answers the
# server's relay. One replica is not incidental: with N replicas the pod-local
# store is N disjoint fragments and the comparator reads whichever one the
# service happens to route to (ai-meta#257 §1.3).
#
# Worth noting what changes under `server` mode: the server becomes the sole
# producer and sends every append to one relay endpoint, so the tier stops being
# N fragments by construction rather than by replica count. This deployment
# still pins one replica because the RELAY target must be stable, not because
# the mirror needs it.
WORKER_DEPLOY=noetl-worker-rust
WORKER_CTR=worker
RELAY_URL=http://noetl-worker-rust-metrics.noetl.svc.cluster.local:9090

# `kind load docker-image` reports "not present locally" for these images under
# the podman provider even when `podman image inspect` resolves them, with or
# without the `localhost/` prefix. The archive path works, so use it rather than
# spend the gate's time on kind's image lookup.
load() {
  local tmp
  for img in "$SRV_IMG" "$WK_IMG"; do
    tmp=$(mktemp -t kindload).tar
    podman save -o "$tmp" "$img"
    kind load image-archive "$tmp" --name noetl
    rm -f "$tmp"
    echo "loaded: $img"
  done
  echo "-- present in the node --"
  podman exec noetl-control-plane crictl images | grep 258full || {
    echo "FAILED: images are not in the node" >&2; return 1; }
}

arm() {
  local source="$1"
  case "$source" in server|worker) ;; *) echo "arm must be server|worker" >&2; exit 2;; esac

  echo "-- worker ($WORKER_DEPLOY) --"
  $K scale deploy/$WORKER_DEPLOY --replicas=1
  $K set image deploy/$WORKER_DEPLOY $WORKER_CTR="$WK_IMG"
  $K set env deploy/$WORKER_DEPLOY \
      NOETL_EHDB_ENABLED=true \
      NOETL_EHDB_CLIENT_ROLE=worker \
      NOETL_EHDB_EVENTLOG=shadow \
      NOETL_EHDB_LOCAL_REFERENCE_LOG=/tmp/ehdb/ref.jsonl \
      NOETL_EHDB_EVENTLOG_MIRROR_SOURCE="$source"

  echo "-- server --"
  $K set image deploy/noetl-server-rust noetl-server-rust="$SRV_IMG" 2>/dev/null \
    || $K set image deploy/noetl-server-rust "$($K get deploy noetl-server-rust -o jsonpath='{.spec.template.spec.containers[0].name}')=$SRV_IMG"
  $K set env deploy/noetl-server-rust \
      NOETL_EHDB_CROSSSTORE_PARITY_ENABLED=true \
      NOETL_EHDB_CROSSSTORE_PARITY_INTERVAL_SECS=0 \
      NOETL_EHDB_WORKER_QUERY_URL="$RELAY_URL" \
      NOETL_EHDB_EVENTLOG_MIRROR_SOURCE="$source"

  $K rollout status deploy/$WORKER_DEPLOY --timeout=180s
  $K rollout status deploy/noetl-server-rust --timeout=180s
  echo "armed: NOETL_EHDB_EVENTLOG_MIRROR_SOURCE=$source"
}

restore() {
  # Back to what the previous session left: released images, zero EHDB env, no
  # tier promoted, user pool scaled to zero.
  $K set env deploy/$WORKER_DEPLOY \
      NOETL_EHDB_ENABLED- NOETL_EHDB_CLIENT_ROLE- NOETL_EHDB_EVENTLOG- \
      NOETL_EHDB_LOCAL_REFERENCE_LOG- NOETL_EHDB_EVENTLOG_MIRROR_SOURCE- || true
  $K set image deploy/$WORKER_DEPLOY $WORKER_CTR=ghcr.io/noetl/worker:5.115.3-arm64
  $K scale deploy/$WORKER_DEPLOY --replicas=0
  $K set env deploy/noetl-server-rust \
      NOETL_EHDB_CROSSSTORE_PARITY_ENABLED- NOETL_EHDB_CROSSSTORE_PARITY_INTERVAL_SECS- \
      NOETL_EHDB_EVENTLOG_MIRROR_SOURCE- || true
  $K set env deploy/noetl-server-rust \
      NOETL_EHDB_WORKER_QUERY_URL="$RELAY_URL"
  $K set image deploy/noetl-server-rust \
      "$($K get deploy noetl-server-rust -o jsonpath='{.spec.template.spec.containers[0].name}')=ghcr.io/noetl/server:3.79.2"
  $K rollout status deploy/noetl-server-rust --timeout=180s
  echo "restored"
}

case "${1:-}" in
  load)    load ;;
  arm)     arm "${2:-server}" ;;
  restore) restore ;;
  *) echo "usage: deploy.sh {load|arm <server|worker>|restore}" >&2; exit 2 ;;
esac
