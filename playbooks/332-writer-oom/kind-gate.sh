#!/usr/bin/env bash
# Kind gate for the writer OOM fix. RED must reproduce; GREEN must survive.
# bash 3.2 compatible (macOS).
set -uo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$1"; }
kc(){ kubectl --context kind-noetl -n noetl "$@"; }
restarts(){ kc get pod "$1" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo 0; }
# ⚠ BOTH state and lastState. With restartPolicy:Never a killed container never
# restarts, so the reason lives in `state.terminated` and `lastState` is empty —
# checking only lastState reports '' for a pod that was very much OOMKilled.
oomed(){
  r=$(kc get pod "$1" -o jsonpath='{.status.containerStatuses[0].state.terminated.reason}' 2>/dev/null)
  [ -n "$r" ] || r=$(kc get pod "$1" -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}' 2>/dev/null)
  echo "$r"
}
exitcode(){ kc get pod "$1" -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null; }
phase(){ kc get pod "$1" -o jsonpath='{.status.phase}' 2>/dev/null; }
ready(){ kc get pod "$1" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null; }
storemb(){ kc exec "$1" -c w -- sh -c 'du -sm /data/eventbus/tier 2>/dev/null | cut -f1' 2>/dev/null; }

RECS=${RECS:-4000}
CONC=${CONC:-20}
PAD=${PAD:-16384}

run_arm(){
  pod="sealgate-$1"
  echo "== $1 arm =="
  kc delete pod "$pod" --ignore-not-found --wait=true >/dev/null 2>&1
  kc apply -f "$SD/$1.json" >/dev/null
  for i in $(seq 1 60); do [ "$(ready "$pod")" = "true" ] && break; sleep 5; done
  [ "$(ready "$pod")" = "true" ] || { echo "  never ready"; kc logs "$pod" --tail=8 2>/dev/null; return 1; }

  echo "  growing the store: $RECS records x ${PAD}B ..."
  kc exec "$pod" -c w -- /app/ehdb-selfcheck tier-load --addr 127.0.0.1:9110 \
       --records "$RECS" --concurrency 1 --pad "$PAD" 2>/dev/null | tail -1 | sed 's/^/    /'
  echo "  store=$(storemb "$pod")MB phase=$(phase "$pod") restarts=$(restarts "$pod") oom='$(oomed "$pod")'"

  echo "  burst: $CONC concurrent clients (the KEDA 1->20 shape) ..."
  kc exec "$pod" -c w -- /app/ehdb-selfcheck tier-load --addr 127.0.0.1:9110 \
       --records 400 --concurrency "$CONC" --pad "$PAD" 2>/dev/null | tail -1 | sed 's/^/    /'
  sleep 8
  echo "  FINAL phase=$(phase "$pod") restarts=$(restarts "$pod") oom='$(oomed "$pod")'"
}

run_arm red
R_OOM="$(oomed sealgate-red)"; R_RST="$(restarts sealgate-red)"; R_PH="$(phase sealgate-red)"
echo
run_arm green
G_OOM="$(oomed sealgate-green)"; G_RST="$(restarts sealgate-green)"; G_PH="$(phase sealgate-green)"

echo
echo "== VERDICT =="
echo "  red  : phase=$R_PH restarts=${R_RST:-0} oom='$R_OOM'"
echo "  green: phase=$G_PH restarts=${G_RST:-0} oom='$G_OOM'"
echo
if [ "$R_OOM" = "OOMKilled" ]; then
  ok "RED reproduced the production failure EXACTLY: OOMKilled, exitCode=$(exitcode sealgate-red)"
elif [ "$R_PH" = "Failed" ]; then
  no "RED failed but NOT with OOMKilled (reason='$R_OOM') — that is a different bug, not this one"
else
  no "RED did NOT reproduce an OOM — GREEN proves nothing about the fix"
fi
if [ "$G_OOM" != "OOMKilled" ] && [ "$G_PH" = "Running" ] && [ "${G_RST:-0}" -eq 0 ]; then
  ok "GREEN survived the IDENTICAL load (arms differ by exactly 2 env vars)"
else
  no "GREEN also failed — the fix does not bound this"
fi
echo
echo "RESULT: $PASS pass / $FAIL fail"
[ "$FAIL" -eq 0 ]
