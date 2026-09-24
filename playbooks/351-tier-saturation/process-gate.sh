#!/usr/bin/env bash
# Does the PROCESS stay responsive under CPU-bound tier load?
#
# This is the property #341 exists for. What failed in prod was not a tier read:
# it was worker registration starving past a HARDCODED 30s timeout and the
# metrics scrape going unanswered, on the pod hosting both buses. The tier-read
# probe used by the earlier gate tests head-of-line blocking INSIDE the tier,
# which a cap of 1 makes strictly worse by construction.
set -uo pipefail
S=/private/tmp/claude-501/-Volumes-X10-projects-noetl-ai-meta/104e3c0b-21d5-4636-8a03-d19c7127b4a4/scratchpad
kx(){ kubectl --context kind-noetl -n noetl "$@"; }
start_load(){ for i in $(seq 1 "$1"); do
    kx exec mem-writer -c w -- sh -c 'while :; do /app/ehdb-selfcheck tier-load \
       --addr 127.0.0.1:9110 --tier eventlog --read-only true \
       --execution-id big >/dev/null 2>&1; done' >/dev/null 2>&1 & done; sleep 12; }
stop_load(){ kx exec mem-writer -c w -- sh -c 'pkill -f "while :;" 2>/dev/null; pkill -f "[t]ier-load" 2>/dev/null; true' >/dev/null 2>&1
  pkill -f "exec mem-writer" 2>/dev/null; sleep 4; }

# Scrape the worker's own /metrics (9090) from the host. curl/wget are ABSENT
# from the image, so this must be measured from outside the pod.
scrape(){ local t0 t1
  kx port-forward pod/mem-writer 19090:9090 >/dev/null 2>&1 & local pf=$!; sleep 4
  t0=$(date +%s%N)
  local n; n=$(curl -s --max-time 30 http://127.0.0.1:19090/metrics 2>/dev/null | wc -l)
  t1=$(date +%s%N); kill $pf 2>/dev/null
  echo "$(( (t1-t0)/1000000 ))ms lines=$n"
}

arm(){ local label="$1" tag="$2"
  kx delete pod mem-writer --ignore-not-found --wait=true >/dev/null 2>&1
  sed -e "s/__TAG__/$tag/" -e 's/__CPU__/2/' -e 's/__SEAL__/1020000000/' $S/gate-pod.tmpl > $S/pg.yaml
  kubectl --context kind-noetl apply -f $S/pg.yaml >/dev/null 2>&1
  for i in $(seq 1 90); do
    [ "$(kx get pod mem-writer -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null)" = "true" ] && break
    sleep 2; done
  sleep 10
  local cap; cap=$(kx logs mem-writer -c w 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | grep -oE "max_inflight=[0-9]+" | tail -1)
  echo "  == $label ($cap) =="
  # ⚠ POSITIVE CONTROL, enforced: the metrics face binds LATE (the eventbus one
  # ~37s late in prod). A first-run idle scrape returned 0 lines on one arm,
  # which would have made the arms non-comparable. Wait until idle actually
  # serves before measuring anything, and fail loudly if it never does.
  local idle="" ; local i
  for i in $(seq 1 12); do
    idle=$(scrape)
    case "$idle" in *"lines=0") sleep 10;; *) break;; esac
  done
  echo "     idle            : $idle"
  case "$idle" in *"lines=0") echo "     ❌ IDLE CONTROL FAILED on this arm — results not comparable";; esac
  start_load 8
  local live; live=$(kx exec mem-writer -c w -- sh -c 'ps -o args 2>/dev/null | grep -c "[w]hile :;"' 2>/dev/null | tr -dc 0-9)
  echo "     under 8 loops(${live:-0}): $(scrape)"
  stop_load
}
echo "===== PROCESS RESPONSIVENESS UNDER CPU-BOUND TIER LOAD ====="
arm "RED  origin/main" gate-red2
arm "GREEN #341 clamp" gate-green2
