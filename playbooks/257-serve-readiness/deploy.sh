#!/usr/bin/env bash
# Put the ai-meta#257 CONSOLIDATED serve-readiness gate on the kind cluster.
#
# This composes four separately-proven pieces onto ONE pair of built images and
# runs them TOGETHER at multiple worker replicas:
#
#   * cross-store comparator          server#343 / worker#265
#   * server-authored mirror          feat/258-server-authored-mirror
#   * tier-service observability      feat/260-tier-service-metrics   (#260)
#   * tier-query-service read path    feat/257-pr4-tier-query-service (RFC PR 4)
#
# Each was gated alone. Alone is not the question a flip asks.
#
#   deploy.sh load                     — load the gate images into the kind node
#   deploy.sh writer                   — arm the writer's tier service (:9110 + PVC store)
#   deploy.sh arm <local|service> [N]  — N worker replicas, tier reads resolve local|service
#   deploy.sh mode <shadow|primary>    — THE FLIP. Only NOETL_EHDB_EVENTLOG moves.
#   deploy.sh tierdown                 — remove the writer's tier-service face (arm E kill)
#   deploy.sh tierup                   — put it back (arm E recovery)
#   deploy.sh blackhole                — point workers at an unreachable tier service
#   deploy.sh point <host:port>        — repoint ONLY the tier-service address
#   deploy.sh relay <url|pod-ip>       — pin the server's relay at one replica
#   deploy.sh poolimg <image>          — swap ONLY the pool's image (the mutation lever)
#   deploy.sh restore                  — released images, zero EHDB env, pool back to 0
#
# Every lever moves exactly one variable. A gate whose arms differ in two things
# cannot attribute its own result.
set -euo pipefail

export KIND_EXPERIMENTAL_PROVIDER=podman
SRV_IMG="${SRV_IMG:-localhost/noetl-server:pr4real}"
WK_IMG="${WK_IMG:-localhost/noetl-worker:capreal}"

NS=noetl
WORKER_DEPLOY=noetl-worker-rust
WORKER_CTR=worker
WRITER_STS=noetl-cmdbus-writer
WRITER_CTR=noetl-worker
# Stable per-pod DNS. The tier service must resolve to ONE process — that is the
# entire premise of the writer-fronted design; the headless service round-robins.
TIER_ADDR="${TIER_ADDR:-noetl-cmdbus-writer-0.noetl.svc.cluster.local:9110}"
TIER_DIR=/data/eventbus/tier
RELAY_SVC=http://noetl-worker-rust-metrics.noetl.svc.cluster.local:9090
# RFC 5737 TEST-NET-1: routed nowhere, so a connect attempt times out rather
# than being refused. "Configured but unusable" is the state arm D was about.
BLACKHOLE="${BLACKHOLE:-192.0.2.1:9110}"

k() { kubectl --context kind-noetl -n "$NS" "$@"; }

# `kubectl rollout status` returning is not the same as the endpoint serving:
# the OLD server pod answers /api/health with 200 while it terminates, so a
# single probe passes and the next request lands in the gap.
wait_server() {
  local i pods streak=0
  for i in $(seq 1 90); do
    pods=$(k get pods -l app=noetl-server-rust --no-headers 2>/dev/null | grep -c Running || true)
    if [ "${pods:-0}" -eq 1 ] \
       && [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://localhost:8082/api/health)" = "200" ]; then
      streak=$((streak+1)); [ "$streak" -ge 3 ] && return 0
    else
      streak=0
    fi
    sleep 2
  done
  echo "server never answered /api/health three times running" >&2; return 1
}

# Assert the pool really has N ready pods. NOT `kubectl scale`: the ScaledObject
# carries `autoscaling.keda.sh/paused-replicas`, which reverts a manual scale
# within seconds — and a 0-replica Deployment reports "successfully rolled out".
pin_replicas() {
  local replicas="$1" ready
  k annotate scaledobject "$WORKER_DEPLOY" \
      "autoscaling.keda.sh/paused-replicas=$replicas" --overwrite >/dev/null
  for _ in $(seq 1 60); do
    ready=$(k get deploy "$WORKER_DEPLOY" -o jsonpath='{.status.readyReplicas}')
    [ "${ready:-0}" -ge "$replicas" ] && break
    sleep 5
  done
  ready=$(k get deploy "$WORKER_DEPLOY" -o jsonpath='{.status.readyReplicas}')
  [ "${ready:-0}" -ge "$replicas" ] || {
    echo "FAILED: wanted $replicas ready replicas, have ${ready:-0}" >&2; exit 1; }
  echo "   $ready replicas ready"
}

load() {
  local tmp found imgs=("$WK_IMG")
  [ -n "${SRV_IMG_LOAD:-}" ] && imgs+=("$SRV_IMG_LOAD")
  [ -n "${EXTRA_IMG:-}" ] && imgs+=("$EXTRA_IMG")
  for img in "${imgs[@]}"; do
    tmp=$(mktemp -t kindloadXXXXXX).tar
    podman save -o "$tmp" "$img"
    kind load image-archive "$tmp" --name noetl
    rm -f "$tmp"
    echo "loaded: $img"
  done
  # Positive control on the load itself: `kind load` has reported success for an
  # image the node did not end up with. Naming the tag here makes a silent miss
  # fail now, rather than later as an unexplained old-behaviour gate result.
  echo "-- present in the node --"
  for img in "${imgs[@]}"; do
    local tag="${img##*:}"
    found=$(podman exec noetl-control-plane crictl images | grep -c "$tag" || true)
    [ "$found" -ge 1 ] || { echo "FAILED: $img not in the kind node" >&2; return 1; }
    podman exec noetl-control-plane crictl images | grep "$tag"
  done
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
  local source="$1" replicas="${2:-3}" mode="${3:-shadow}"
  case "$source" in local|service) ;; *) echo "arm must be local|service" >&2; exit 2;; esac

  echo "-- worker pool: $replicas replicas, TIER_QUERY_SOURCE=$source, EVENTLOG=$mode --"
  k set image "deploy/$WORKER_DEPLOY" "$WORKER_CTR=$WK_IMG"
  k set env "deploy/$WORKER_DEPLOY" \
      NOETL_EHDB_ENABLED=true \
      NOETL_EHDB_CLIENT_ROLE=worker \
      NOETL_EHDB_EVENTLOG="$mode" \
      NOETL_EHDB_LOCAL_REFERENCE_LOG=/tmp/ehdb/ref.jsonl \
      NOETL_EHDB_EVENTLOG_MIRROR_SOURCE=server \
      NOETL_EHDB_TIER_SERVICE_ADDR="$TIER_ADDR" \
      NOETL_EHDB_TIER_QUERY_SOURCE="$source"
  pin_replicas "$replicas"

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
  echo "armed: source=$source replicas=$replicas eventlog=$mode"
}

# THE FLIP, and its rollback. One variable, on one workload. This is the exact
# command pair the cutover runbook documents; keeping it here means the runbook
# cites something that has been executed rather than something composed by hand.
mode() {
  local m="$1" replicas
  case "$m" in shadow|primary) ;; *) echo "mode must be shadow|primary" >&2; exit 2;; esac
  replicas=$(k get scaledobject "$WORKER_DEPLOY" \
      -o jsonpath='{.metadata.annotations.autoscaling\.keda\.sh/paused-replicas}')
  k set env "deploy/$WORKER_DEPLOY" NOETL_EHDB_EVENTLOG="$m"
  k rollout status "deploy/$WORKER_DEPLOY" --timeout=300s
  pin_replicas "${replicas:-3}"
  # The roll gives every replica a new pod IP. If a previous gate run left the
  # server's relay pinned at an old one, the comparator would answer
  # `ehdb_unavailable` for reasons that have nothing to do with the flip.
  k set env deploy/noetl-server-rust NOETL_EHDB_WORKER_QUERY_URL="$RELAY_SVC" >/dev/null
  k rollout status deploy/noetl-server-rust --timeout=240s >/dev/null 2>&1
  wait_server
  echo "event-log tier mode: $m"
}

# Arm E — take the tier-service face away while leaving every other writer face
# (cmdbus, events, SSE, KV) up. Removing the whole writer would stop dispatch and
# measure the wrong thing: the availability brief's point is that the tier is the
# ONE writer dependency with a fallback.
tierdown() {
  k set env "sts/$WRITER_STS" NOETL_EHDB_TIER_SERVICE_BIND-
  k rollout status "sts/$WRITER_STS" --timeout=240s
  echo "tier-service face removed (store on the PVC is untouched)"
}
tierup() {
  k set env "sts/$WRITER_STS" NOETL_EHDB_TIER_SERVICE_BIND=0.0.0.0:9110
  k rollout status "sts/$WRITER_STS" --timeout=240s
  echo "tier-service face restored"
}

# Configured but unusable. `is_reachable()` must be false here — an address that
# is merely SET is what arm D wrongly counted as a durable service.
blackhole() { point "$BLACKHOLE"; }

point() {
  local addr="$1" replicas
  replicas=$(k get scaledobject "$WORKER_DEPLOY" \
      -o jsonpath='{.metadata.annotations.autoscaling\.keda\.sh/paused-replicas}')
  k set env "deploy/$WORKER_DEPLOY" NOETL_EHDB_TIER_SERVICE_ADDR="$addr"
  k rollout status "deploy/$WORKER_DEPLOY" --timeout=300s
  pin_replicas "${replicas:-3}"
  echo "tier-service address now: $addr"
}

# Swap ONLY the worker pool's image, keeping every env var and the replica count.
#
# This is the mutation lever for the P0 arm. The serve decision runs in the pool's
# append handler, so the mutation lives entirely on that side — swapping the
# writer too would move a second variable for no reason, and the writer's tier
# store is identical in both images.
poolimg() {
  local img="$1" replicas
  replicas=$(k get scaledobject "$WORKER_DEPLOY" \
      -o jsonpath='{.metadata.annotations.autoscaling\.keda\.sh/paused-replicas}')
  k set image "deploy/$WORKER_DEPLOY" "$WORKER_CTR=$img"
  k rollout status "deploy/$WORKER_DEPLOY" --timeout=300s
  pin_replicas "${replicas:-3}"
  # The roll gives every replica a new pod IP; un-pin the relay so the comparator
  # is not aimed at a dead pod for reasons unrelated to the image.
  k set env deploy/noetl-server-rust NOETL_EHDB_WORKER_QUERY_URL="$RELAY_SVC" >/dev/null
  k rollout status deploy/noetl-server-rust --timeout=240s >/dev/null 2>&1
  wait_server
  echo "worker pool image: $img"
}

relay() {
  k set env deploy/noetl-server-rust NOETL_EHDB_WORKER_QUERY_URL="$1"
  k rollout status deploy/noetl-server-rust --timeout=240s
  wait_server
  echo "relay pinned at: $1"
}

restore() {
  k set env "deploy/$WORKER_DEPLOY" \
      NOETL_EHDB_ENABLED- NOETL_EHDB_CLIENT_ROLE- NOETL_EHDB_EVENTLOG- \
      NOETL_EHDB_LOCAL_REFERENCE_LOG- NOETL_EHDB_EVENTLOG_MIRROR_SOURCE- \
      NOETL_EHDB_TIER_SERVICE_ADDR- NOETL_EHDB_TIER_QUERY_SOURCE- || true
  k set image "deploy/$WORKER_DEPLOY" "$WORKER_CTR=ghcr.io/noetl/worker:5.115.3-arm64"
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
  load)      load ;;
  writer)    writer ;;
  arm)       arm "${2:-service}" "${3:-3}" "${4:-shadow}" ;;
  mode)      mode "${2:?need shadow|primary}" ;;
  tierdown)  tierdown ;;
  tierup)    tierup ;;
  blackhole) blackhole ;;
  point)     point "${2:?need host:port}" ;;
  poolimg)   poolimg "${2:?need an image}" ;;
  relay)     relay "${2:?need a URL}" ;;
  restore)   restore ;;
  *) echo "usage: deploy.sh {load|writer|arm <local|service> [N] [shadow|primary]|mode <shadow|primary>|tierdown|tierup|blackhole|point <addr>|relay <url>|poolimg <image>|restore}" >&2; exit 2 ;;
esac
