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
#   deploy.sh readmode <m>          — B1: NOETL_EHDB_PROJECTION_READ_SOURCE on the server
#   deploy.sh bump-incumbent        — B1: raise the incumbent's version above the tier's
#   deploy.sh unbump                — undo bump-incumbent
#   deploy.sh async <on|off> <secs> — G3: the async mirror + its window, as a PAIR
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
SRV_IMG="${SRV_IMG:-localhost/noetl-server:265b1}"
WK_IMG="${WK_IMG:-localhost/noetl-worker:265b1}"

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
  podman exec noetl-control-plane crictl images | grep -E '265proj|265b1' || true
  found=$(podman exec noetl-control-plane crictl images | grep -cE '265b1' || true)
  [ "$found" -ge 2 ] || { echo "FAILED: expected 2 265b1 images in the node, found $found" >&2; return 1; }
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

# MUTATION 1 — make the two stores disagree on CONTENT at the same version.
#
# This is the corruption the comparator exists for and the one a count-based
# check cannot see: every record is present, the versions line up, and the two
# stores hold different content for the revision they both claim. Expected
# verdict: `checksum`, NOT `stale_version`.
#
# ⚠ THE FIRST VERSION OF THIS MUTATION DID NOTHING, and it is worth recording
# why. It ran `sed` over the tier store's JSONL looking for `"checksum":"..."`.
# The store does not hold payloads as text — `LocalJsonlTransactionLog` writes
# them as a JSON **byte array** (`"payload":[123,34,97,...]`), so the pattern
# never matched, `sed` exited 0, and the gate reported `match` against an
# unmutated store. A mutation that compiles is not the same as a mutation that
# mutates, and only the store dump showed the difference.
#
# So the mutation moves to the INCUMBENT side, where the value is a plain
# column: rewrite `noetl.projection_snapshot.checksum` for one execution. The
# divergence is identical in shape (same version, different content) and the
# mutation is one statement, reversible, and — critically — VERIFIED below.
# `corrupt` now fails loudly if the value did not change.
corrupt() {
  local e="${EXEC_ID:?EXEC_ID must name the execution to corrupt}"
  local before after
  before=$(kubectl --context kind-noetl -n postgres exec deploy/postgres -- \
    psql -U noetl -d noetl -At -c \
    "SELECT checksum FROM noetl.projection_snapshot WHERE aggregate_id='$e';" | tr -d '\r' | head -1)
  [ -n "$before" ] || { echo "NOTHING TO CORRUPT: no snapshot row for $e" >&2; return 3; }
  kubectl --context kind-noetl -n postgres exec deploy/postgres -- \
    psql -U noetl -d noetl -At -c \
    "UPDATE noetl.projection_snapshot SET checksum='deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef' WHERE aggregate_id='$e';" >/dev/null
  after=$(kubectl --context kind-noetl -n postgres exec deploy/postgres -- \
    psql -U noetl -d noetl -At -c \
    "SELECT checksum FROM noetl.projection_snapshot WHERE aggregate_id='$e';" | tr -d '\r' | head -1)
  # THE GUARD THE FIRST VERSION LACKED. Without it a no-op mutation produces a
  # green gate that proves nothing.
  [ "$before" != "$after" ] || { echo "MUTATION DID NOT TAKE: checksum unchanged ($before)" >&2; return 3; }
  echo "incumbent checksum for $e: ${before:0:16}… -> ${after:0:16}…"
}

# Undo MUTATION 1 by re-deriving the incumbent's row from the event log. The
# projector's own endpoint recomputes and re-saves, so the restore uses the same
# shipped path the gate uses to create the row.
uncorrupt() {
  local e="${EXEC_ID:?EXEC_ID required}"
  local tn tk tok
  read -r tn tk <<EOF
$(kubectl --context kind-noetl -n noetl get deploy noetl-server-rust -o json | python3 -c "
import json,sys
d=json.load(sys.stdin)
for x in d['spec']['template']['spec']['containers'][0].get('env',[]):
    if x['name']=='NOETL_INTERNAL_API_TOKEN':
        r=x['valueFrom']['secretKeyRef']; print(r['name'], r['key'])
")
EOF
  tok=$(kubectl --context kind-noetl -n noetl get secret "$tn" -o jsonpath="{.data.$tk}" | base64 -d)
  curl -s --max-time 60 -X POST http://localhost:8082/api/internal/projection/advance \
    -H "Authorization: Bearer $tok" -H 'content-type: application/json' \
    -d "{\"execution_ids\":[$e]}" | head -c 200
  echo
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


# --- ai-meta#265 phase B1 --------------------------------------------------

# The read-serve mode. The ONLY variable the B1 serve arms move.
#
# `postgres` is not "unset": it is set explicitly so the arm is legible in
# `kubectl get deploy -o yaml`, and so the difference between the baseline arm
# and an un-armed cluster is visible rather than inferred.
readmode() {
  local m="$1"
  case "$m" in postgres|verify|tier) ;; *) echo "readmode must be postgres|verify|tier" >&2; exit 2;; esac
  k set env deploy/noetl-server-rust NOETL_EHDB_PROJECTION_READ_SOURCE="$m"
  k rollout status deploy/noetl-server-rust --timeout=300s
  wait_server
  echo "read source: $m"
}

# MUTATION 4 (B1) — make the tier BEHIND the incumbent.
#
# On the incumbent side, for the same reason `corrupt` is: the tier store holds
# payloads as a JSON byte array, so an edit there cannot be made reliably — and
# the one attempt to do it with `sed` exited 0 having changed nothing. Here the
# value is a plain column, the change is one statement, it is reversible, and it
# is VERIFIED below.
#
# Shape-wise this is exactly "the mirror fell behind a newer incumbent save",
# which is the state a relay outage leaves. Expected verdict in `verify` mode:
# `stale_version` — correct to serve (folding forward gives the same answer) and
# still refused, because `verify`'s contract is agreement.
# ⚠ STICKY. Measured: a bumped version SURVIVES a recompute. `advance` takes the
# snapshot's own version as a floor, so `UPDATE ... version = version + 1`
# followed by /api/internal/projection/advance returns the BUMPED value, not the
# event-log tip — and the incumbent is then permanently above `max(event_id)`,
# which turns every later arm into `version_ahead` instead of whatever it was
# testing. Use `unbump` or `deploy.sh pin-incumbent` to put it back; do not
# assume a recompute cleans up after this.
bump_incumbent() {
  local e="${EXEC_ID:?EXEC_ID must name the execution}"
  local before after
  before=$(kubectl --context kind-noetl -n postgres exec deploy/postgres -- \
    psql -U noetl -d noetl -At -c \
    "SELECT version FROM noetl.projection_snapshot WHERE aggregate_id='$e';" | tr -d '\r' | head -1)
  [ -n "$before" ] || { echo "NOTHING TO BUMP: no snapshot row for $e" >&2; return 3; }
  kubectl --context kind-noetl -n postgres exec deploy/postgres -- \
    psql -U noetl -d noetl -At -c \
    "UPDATE noetl.projection_snapshot SET version = version + 1 WHERE aggregate_id='$e';" >/dev/null
  after=$(kubectl --context kind-noetl -n postgres exec deploy/postgres -- \
    psql -U noetl -d noetl -At -c \
    "SELECT version FROM noetl.projection_snapshot WHERE aggregate_id='$e';" | tr -d '\r' | head -1)
  [ "$before" != "$after" ] || { echo "MUTATION DID NOT TAKE: version unchanged ($before)" >&2; return 3; }
  echo "incumbent version for $e: $before -> $after (tier now behind)"
}

# Force the incumbent's version back to the event-log tip. The honest undo for
# `bump_incumbent`, since a recompute will not do it (see above).
pin_incumbent() {
  local e="${EXEC_ID:?EXEC_ID required}"
  kubectl --context kind-noetl -n postgres exec deploy/postgres -- \
    psql -U noetl -d noetl -At -c \
    "UPDATE noetl.projection_snapshot s SET version = (SELECT MAX(event_id) FROM noetl.event WHERE execution_id = $e) WHERE s.aggregate_id='$e';" >/dev/null
  kubectl --context kind-noetl -n postgres exec deploy/postgres -- \
    psql -U noetl -d noetl -At -c \
    "SELECT 'incumbent version now ' || version FROM noetl.projection_snapshot WHERE aggregate_id='$e';" | tr -d '\r'
}

unbump() {
  local e="${EXEC_ID:?EXEC_ID required}"
  kubectl --context kind-noetl -n postgres exec deploy/postgres -- \
    psql -U noetl -d noetl -At -c \
    "UPDATE noetl.projection_snapshot SET version = version - 1 WHERE aggregate_id='$e';" >/dev/null
  echo "incumbent version restored"
}


# Empty the projection tier FOR REAL — truncate AND restart the writer.
#
# ⚠ TRUNCATING THE FILE IS NOT ENOUGH ANYMORE, and this invalidates the phase-A
# `drop` arm on worker >= v5.121.0. worker#280 gave the tier store a runtime
# cache; after `: > projection.jsonl` the file held 3 lines while the relay
# still served 15 records for one execution, because the cache is not evicted by
# someone truncating the file underneath it.
#
# Which is the theme of this whole issue arriving one level down: the store FILE
# is a representation of what the tier serves, and nothing forces the two to
# agree once a cache sits between them. A gate that emptied the file and scored
# `missing_execution` would be reading the file, not the tier.
#
# Not a durability bug — the truncate is what desynchronised them. But any arm
# that needs an empty tier must restart the writer, and any arm that reads the
# file to decide what the tier holds is measuring the wrong thing.
reset_tier() {
  local pod
  pod=$(writer_pod)
  k exec "$pod" -- sh -c ": > $TIER_DIR/projection.jsonl"
  k delete pod "${WRITER_STS}-0" --wait=true >/dev/null 2>&1 || true
  k rollout status "sts/$WRITER_STS" --timeout=300s | tail -1
  sleep 8
  echo "projection tier emptied (file truncated AND writer restarted)"
}


# G3 — the async mirror and its tolerance window, set TOGETHER.
#
# Deliberately one command taking both. The two are a pair (#155, #265 G3) and
# a helper that could set one without the other is a helper that invites the
# misconfiguration the code refuses to arm on. The `refusal` arm is the one
# place they are set apart, and it does so explicitly.
async_pair() {
  local mode="$1" secs="${2:-0}"
  case "$mode" in on|off) ;; *) echo "async must be on|off" >&2; exit 2;; esac
  local flag=false
  [ "$mode" = "on" ] && flag=true
  k set env deploy/noetl-server-rust \
      NOETL_EHDB_PROJECTION_MIRROR_ASYNC="$flag" \
      NOETL_EHDB_PROJECTION_PARITY_LAG_TOLERANCE_SECS="$secs"
  k rollout status deploy/noetl-server-rust --timeout=300s | tail -1
  wait_server
  echo "async mirror: $flag, lag tolerance: ${secs}s"
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
  uncorrupt) uncorrupt ;;
  drop) drop ;;
  bypass) bypass ;;
  readmode) readmode "$@" ;;
  bump-incumbent) bump_incumbent ;;
  unbump) unbump ;;
  pin-incumbent) pin_incumbent ;;
  reset-tier) reset_tier ;;
  async) async_pair "$@" ;;
  restore) restore ;;
  *) sed -n '2,20p' "$0"; exit 2 ;;
esac
