#!/usr/bin/env bash
# Put the ai-meta#260 gate image and env on the kind cluster.
#
#   deploy.sh load                 — load the gate image(s) into the kind node
#   deploy.sh arm up   [image]     — tier service listening, store configured
#   deploy.sh arm off  [image]     — same image, NO listener (the discriminating arm)
#   deploy.sh forward              — port-forward :9090 metrics + :9110 tier
#   deploy.sh restore              — back to the released image with no tier env
#
# The tier service is hosted by the process that sets NOETL_EVENT_BUS_HOST — the
# writer — because that is the process holding the durable volumes. In kind that
# is the `noetl-cmdbus-writer` StatefulSet, whose Service ALREADY publishes 9110
# (the ops#255 port declaration) and 9090 (metrics). So this gate needs no
# manifest change: it sets the env that makes the listener exist, and nothing
# else.
#
# The two arms differ in exactly ONE variable, NOETL_EHDB_TIER_SERVICE_BIND.
# Same image, same store dir, same everything else — so a difference in the
# verdict is attributable to the listener existing and to nothing else.
set -euo pipefail

export KIND_EXPERIMENTAL_PROVIDER=podman
kctl() { kubectl --context kind-noetl -n noetl "$@"; }

STS=noetl-cmdbus-writer
CTR=noetl-worker
# `260real` is the provenance-checked build: made from a COMMITTED tree, and
# verified to share an image ID with an independent rebuild. `260mut` is the same
# source plus mutation.patch.
IMG="${IMG:-localhost/noetl-worker:260real}"
RELEASED="${RELEASED:-ghcr.io/noetl/worker:5.115.3-arm64}"
# Inside the writer's existing eventbus PVC — the same shape prod would use, and
# the reason the writer hosts this face at all (RWO volumes cannot be shared).
STORE_DIR=/data/eventbus/tier260

load() {
  local tmp
  for img in "$@"; do
    # `kind load docker-image` reports "not present locally" under the podman
    # provider even when `podman image inspect` resolves the name. The archive
    # path works, so use it rather than spend the gate's time on kind's lookup.
    # `-t kindload` alone is rejected by BSD mktemp ("too few X's in
    # template"); the template needs the placeholder explicitly.
    tmp=$(mktemp -t kindload.XXXXXX).tar
    podman save -o "$tmp" "$img"
    kind load image-archive "$tmp" --name noetl
    rm -f "$tmp"
    echo "loaded: $img"
  done
  # Positive control on the load itself: a load that silently no-ops would leave
  # the cluster running the OLD image and every gate result would describe it.
  #
  # Checks each requested tag BY NAME. An earlier version grepped a hardcoded
  # pattern, which silently verified only one of the two images passed — a
  # control that does not cover what it was handed is not a control.
  echo "-- present in the node --"
  local present
  present=$(podman exec noetl-control-plane crictl images)
  for img in "$@"; do
    local tag="${img##*:}"
    if printf '%s' "$present" | grep -q "[[:space:]]${tag}[[:space:]]"; then
      echo "  in node: $img"
    else
      echo "FAILED: $img is not in the kind node" >&2; return 1
    fi
  done
}

arm() {
  local mode="$1" img="${2:-$IMG}"
  case "$mode" in up|off) ;; *) echo "arm must be up|off" >&2; exit 2;; esac

  kctl set image "sts/$STS" "$CTR=$img"
  # The store is configured in BOTH arms. Only the listener differs, so the
  # `off` arm cannot be explained away by "there was nothing to serve from".
  kctl set env "sts/$STS" NOETL_EHDB_TIER_SERVICE_DIR="$STORE_DIR"
  if [ "$mode" = up ]; then
    kctl set env "sts/$STS" NOETL_EHDB_TIER_SERVICE_BIND=0.0.0.0:9110
  else
    kctl set env "sts/$STS" NOETL_EHDB_TIER_SERVICE_BIND-
  fi
  # Force the pod out. A StatefulSet RollingUpdate will not evict a pod already
  # wedged in `ErrImageNeverPull` from a previous template, so `set image` alone
  # leaves the OLD image running while `rollout status` times out — and the gate
  # would then describe a pod that is not the one under test.
  kctl delete pod "$STS-0" --grace-period=5 >/dev/null 2>&1 || true
  kctl rollout status "sts/$STS" --timeout=240s
  echo "armed: $mode  image=$img"
  kctl get pod "$STS-0" -o jsonpath='{.spec.containers[0].image}{"\n"}'
}

forward() {
  pkill -f "port-forward.*$STS-0" 2>/dev/null || true
  sleep 1
  kctl port-forward "pod/$STS-0" 19090:9090 19110:9110 > /tmp/pf-260.log 2>&1 &
  sleep 3
  curl -s -o /dev/null -w 'metrics:%{http_code}\n' --max-time 10 http://127.0.0.1:19090/metrics
}

restore() {
  pkill -f "port-forward.*$STS-0" 2>/dev/null || true
  kctl set env "sts/$STS" NOETL_EHDB_TIER_SERVICE_BIND- NOETL_EHDB_TIER_SERVICE_DIR- || true
  kctl set image "sts/$STS" "$CTR=$RELEASED"
  kctl rollout status "sts/$STS" --timeout=180s
  echo "restored to $RELEASED with no tier-service env"
  kctl get pod "$STS-0" -o jsonpath='{.spec.containers[0].image}{"\n"}'
}

case "${1:-}" in
  load)    shift; load "$@" ;;
  arm)     arm "${2:-up}" "${3:-$IMG}" ;;
  forward) forward ;;
  restore) restore ;;
  *) echo "usage: deploy.sh {load <img>...|arm <up|off> [img]|forward|restore}" >&2; exit 2 ;;
esac
