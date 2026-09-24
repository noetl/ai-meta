#!/usr/bin/env bash
# Does CPU-BOUND tier work starve the rest of the runtime?
#
# Saturation here costs REAL CPU on purpose: N concurrent reads of a ~973 MiB
# sealed segment, which is what prod's legacy segment costs. The probe is a
# read on an EMPTY tier (catalog) — it costs nothing, so if it is not answered
# the only explanation is that no runtime thread was free to answer it.
#
# RED  = origin/main (v6.1.7): spawn_blocking only. MAX_INFLIGHT=4 on a 2-cpu
#        cgroup -> 4 concurrent tier ops consume the whole runtime.
# GREEN= #341: clamps in-flight to available_parallelism()-1.
#
# ⚠ The arms are NOT cap-matched (RED 4, GREEN 1) — the clamp IS the change.
#   So this gate shows the clamp fixes it, NOT that concurrency is irrelevant.
set -uo pipefail
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$1"; }
S=/private/tmp/claude-501/-Volumes-X10-projects-noetl-ai-meta/104e3c0b-21d5-4636-8a03-d19c7127b4a4/scratchpad
kx(){ kubectl --context kind-noetl -n noetl "$@"; }

probe(){ kx exec mem-writer -c w -- /app/ehdb-selfcheck tier-load --addr 127.0.0.1:9110 \
          --tier catalog --read-only true --execution-id probe-none 2>/dev/null | tail -1; }

load(){
  # ⚠⚠ A reader CANNOT be held open: `tier-load` calls
  # TierClientConfig::build(Some(&addr), None, None) — both timeouts None — so it
  # uses the hardcoded 2s default and ignores NOETL_EHDB_TIER_SERVICE_TIMEOUT_MS
  # entirely. An earlier run therefore measured ZERO readers while believing it
  # had eight: every client had already given up before the count.
  #
  # So sustain load by RECONNECTING in a loop. The server keeps replaying the
  # 973 MiB segment per connection, which is the CPU under test.
  for i in $(seq 1 8); do
    kx exec mem-writer -c w -- sh -c 'while :; do /app/ehdb-selfcheck tier-load \
       --addr 127.0.0.1:9110 --tier eventlog --read-only true \
       --execution-id big >/dev/null 2>&1; done' >/dev/null 2>&1 &
  done
  sleep 12
  LIVE=$(kx exec mem-writer -c w -- sh -c 'ps -o args 2>/dev/null | grep -c "[e]hdb-selfcheck tier-load"' 2>/dev/null | tr -dc 0-9)
  LOOPS=$(kx exec mem-writer -c w -- sh -c 'ps -o args 2>/dev/null | grep -c "[w]hile :;"' 2>/dev/null | tr -dc 0-9)
  echo "     sustained load: ${LOOPS:-0} reconnect loops, ${LIVE:-0} reads in flight right now"
  HOLDERS_LIVE=${LOOPS:-0}
}
drain(){ kx exec mem-writer -c w -- sh -c 'pkill -f "while :;" 2>/dev/null; pkill -f "[t]ier-load" 2>/dev/null; true' >/dev/null 2>&1
  pkill -f "kubectl --context kind-noetl -n noetl exec mem-writer" 2>/dev/null; wait 2>/dev/null; }

arm(){ local label="$1" tag="$2"
  kx delete pod mem-writer --ignore-not-found --wait=true >/dev/null 2>&1
  sed -e "s/__TAG__/$tag/" -e 's/__CPU__/2/' -e 's/__SEAL__/1020000000/' $S/gate-pod.tmpl > $S/arm.yaml
  kubectl --context kind-noetl apply -f $S/arm.yaml >/dev/null 2>&1
  for i in $(seq 1 90); do
    [ "$(kx get pod mem-writer -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null)" = "true" ] && break
    sleep 2
  done
  sleep 10
  local cap; cap=$(kx logs mem-writer -c w 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | grep -oE "max_inflight=[0-9]+" | tail -1)
  local seg; seg=$(kx exec mem-writer -c w -- sh -c 'du -sm /data/eventbus/ehdb-tier 2>/dev/null' | awk '{print $1}')
  echo "  -- $label  ($cap, store=${seg}MB, cpu=2) --"
  local idle; idle=$(probe); echo "     idle probe      : $(echo "$idle" | cut -c1-120)"
  IDLE_OK=$(echo "$idle" | python3 -c "import json,sys;print(json.load(sys.stdin).get('ok'))" 2>/dev/null)
  load
  local sat; sat=$(probe); echo "     probe UNDER load: $(echo "$sat" | cut -c1-140)"
  SAT_OK=$(echo "$sat" | python3 -c "import json,sys;print(json.load(sys.stdin).get('ok'))" 2>/dev/null)
  SAT_ERR=$(echo "$sat" | python3 -c "import json,sys;print(json.load(sys.stdin).get('error',''))" 2>/dev/null)
  drain
}

echo "===== CPU-BOUND RUNTIME-STARVATION GATE ====="
arm "RED  origin/main (spawn_blocking only)" gate-red2
R_I=$IDLE_OK; R_S=$SAT_OK; R_E=$SAT_ERR; R_L=$HOLDERS_LIVE
arm "GREEN #341 (runtime headroom clamp)"    gate-green2
G_I=$IDLE_OK; G_S=$SAT_OK; G_E=$SAT_ERR; G_L=$HOLDERS_LIVE

echo; echo "  RED  : idle=$R_I under_load=$R_S err='$R_E' readers=$R_L"
echo "  GREEN: idle=$G_I under_load=$G_S err='$G_E' readers=$G_L"
[ "${R_L:-0}" -ge 4 ] && [ "${G_L:-0}" -ge 4 ] \
  && ok "SATURATION REALLY HAPPENED ($R_L / $G_L readers) — both arms were actually tested" \
  || no "saturation did not happen (red=$R_L green=$G_L) — the gate proved nothing"
[ "$R_I" = "True" ] && [ "$G_I" = "True" ] \
  && ok "POSITIVE CONTROL: the cost-free probe answers on BOTH arms when idle" \
  || no "idle probe failed on an arm (red=$R_I green=$G_I) — results meaningless"
[ "$R_S" = "False" ] \
  && ok "RED starved: the cost-free probe went unanswered ('$R_E') — prod's failure, reproduced" \
  || no "RED did NOT starve (under_load=$R_S) — spawn_blocking may already suffice; #341 unjustified"
[ "$G_S" = "True" ] \
  && ok "GREEN answered the cost-free probe under IDENTICAL CPU-bound load" \
  || no "GREEN still starved (under_load=$G_S err='$G_E') — the clamp does not fix it"
echo "  ---- $PASS passed / $FAIL failed ----"
