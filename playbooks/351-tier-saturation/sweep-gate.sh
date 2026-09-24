#!/usr/bin/env bash
# Load SWEEP, because a single load level cannot separate the clamp from the
# waiter budget. max_waiters = 8 * cap, so RED (cap 4) has 32 waiter slots and
# GREEN (cap 1) has 8. At exactly 8 concurrent loops GREEN's queue is full BY
# CONSTRUCTION, and its refusal says nothing about the clamp.
set -uo pipefail
S=/private/tmp/claude-501/-Volumes-X10-projects-noetl-ai-meta/104e3c0b-21d5-4636-8a03-d19c7127b4a4/scratchpad
kx(){ kubectl --context kind-noetl -n noetl "$@"; }
probe(){ kx exec mem-writer -c w -- /app/ehdb-selfcheck tier-load --addr 127.0.0.1:9110 \
          --tier catalog --read-only true --execution-id probe-none 2>/dev/null | tail -1; }
start_load(){ for i in $(seq 1 "$1"); do
    kx exec mem-writer -c w -- sh -c 'while :; do /app/ehdb-selfcheck tier-load \
       --addr 127.0.0.1:9110 --tier eventlog --read-only true \
       --execution-id big >/dev/null 2>&1; done' >/dev/null 2>&1 &
  done; sleep 12; }
stop_load(){ kx exec mem-writer -c w -- sh -c 'pkill -f "while :;" 2>/dev/null; pkill -f "[t]ier-load" 2>/dev/null; true' >/dev/null 2>&1
  pkill -f "exec mem-writer" 2>/dev/null; sleep 4; }

arm(){ local label="$1" tag="$2"
  kx delete pod mem-writer --ignore-not-found --wait=true >/dev/null 2>&1
  sed -e "s/__TAG__/$tag/" -e 's/__CPU__/2/' -e 's/__SEAL__/1020000000/' $S/gate-pod.tmpl > $S/sweep.yaml
  kubectl --context kind-noetl apply -f $S/sweep.yaml >/dev/null 2>&1
  for i in $(seq 1 90); do
    [ "$(kx get pod mem-writer -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null)" = "true" ] && break
    sleep 2; done
  sleep 10
  local cap; cap=$(kx logs mem-writer -c w 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | grep -oE "max_inflight=[0-9]+ max_waiters=[0-9]+" | tail -1)
  echo "  == $label ($cap) =="
  for n in 1 2 4 8; do
    start_load $n
    local live; live=$(kx exec mem-writer -c w -- sh -c 'ps -o args 2>/dev/null | grep -c "[w]hile :;"' 2>/dev/null | tr -dc 0-9)
    local r; r=$(probe)
    # ⚠⚠ `tier-load` reports ok:true for an explicit `err ...` reply, so ok
    # alone counts a REFUSAL as a success. TIER_BUSY_REPLY is exactly 173 bytes;
    # classify on the payload instead.
    local ok; ok=$(echo "$r" | python3 -c "
import json,sys
d=json.load(sys.stdin); b=d.get('bytes'); sec=d.get('seconds'); e=d.get('error','')
if e: verdict='TIMEOUT/ERR'
elif b==173: verdict='SHED (busy reply)'
else: verdict='SERVED (%d bytes)'%b
print('%-22s %ss %s'%(verdict,sec,e[:30]))" 2>/dev/null)
    printf "     load=%-2s loops=%-2s -> %s\n" "$n" "${live:-0}" "$ok"
    stop_load
  done
}
echo "===== TIER STARVATION LOAD SWEEP (973 MiB sealed segment, cpu=2) ====="
arm "RED  origin/main"      gate-red2
arm "GREEN #341 clamp"      gate-green2
