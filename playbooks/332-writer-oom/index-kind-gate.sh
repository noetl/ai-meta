#!/usr/bin/env bash
# RED->GREEN for the sealed-segment index at a prod-shaped sealed store.
#
# RED  = sealed store, NO indexes  -> a cross-segment read must replay the
#        sealed segment and blows the 2s tier read timeout (the prod symptom).
# GREEN= same store, indexes built -> the read skips the segment and completes.
#
# ⚠ The arms differ ONLY by whether the index files exist. Same image, same
# store, same timeout.
set -uo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$1"; }
kc(){ kubectl --context kind-noetl -n noetl "$@"; }
POD=idx-writer

read_probe(){ # $1 execution id -> prints the JSON
  kc exec $POD -c w -- /app/ehdb-selfcheck tier-load --addr 127.0.0.1:9110 \
     --tier eventlog --read-only true --timeout-ms 250 --execution-id "$1" 2>/dev/null | tail -1
}

echo "== stand up =="
kc delete pod $POD --ignore-not-found --wait=true >/dev/null 2>&1
kc apply -f "$SD/idxwriter.json" >/dev/null
for i in $(seq 1 60); do [ "$(kc get pod $POD -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null)" = "true" ] && break; sleep 5; done
[ "$(kc get pod $POD -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null)" = "true" ] || { echo "not ready"; kc logs $POD --tail=10; exit 1; }

echo "== build a sealed store: an OLD execution, then many others =="
kc exec $POD -c w -- /app/ehdb-selfcheck tier-load --addr 127.0.0.1:9110 \
   --tier eventlog --records 400 --concurrency 1 --pad 4096 --execution-id exec-old 2>/dev/null | tail -1 | sed 's/^/  /'
kc exec $POD -c w -- /app/ehdb-selfcheck tier-load --addr 127.0.0.1:9110 \
   --tier eventlog --records 2500 --concurrency 1 --pad 16384 --execution-id exec-new 2>/dev/null | tail -1 | sed 's/^/  /'
echo "  segments: $(kc exec $POD -c w -- sh -c 'ls /data/eventbus/tier/eventlog.jsonl.[0-9]* 2>/dev/null | grep -vc idx' 2>/dev/null) sealed"

echo
echo "== RED — no indexes =="
kc exec $POD -c w -- sh -c 'rm -f /data/eventbus/tier/*.idx' 2>/dev/null
R=$(read_probe exec-old); echo "  $R"
R_OK=$(echo "$R" | python3 -c "import json,sys; print(json.load(sys.stdin).get('ok'))" 2>/dev/null)
R_S=$(echo "$R" | python3 -c "import json,sys; print(json.load(sys.stdin).get('seconds'))" 2>/dev/null)

echo
echo "== GREEN — build the indexes, same store, same timeout =="
kc exec $POD -c w -- sh -c 'kill 1' 2>/dev/null || true
for i in $(seq 1 60); do [ "$(kc get pod $POD -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null)" = "true" ] && break; sleep 5; done
sleep 25   # let the startup backfill finish
echo "  index files: $(kc exec $POD -c w -- sh -c 'ls /data/eventbus/tier/*.idx 2>/dev/null | wc -l' 2>/dev/null)"
G=$(read_probe exec-old); echo "  $G"
G_OK=$(echo "$G" | python3 -c "import json,sys; print(json.load(sys.stdin).get('ok'))" 2>/dev/null)
G_S=$(echo "$G" | python3 -c "import json,sys; print(json.load(sys.stdin).get('seconds'))" 2>/dev/null)
G_B=$(echo "$G" | python3 -c "import json,sys; print(json.load(sys.stdin).get('bytes'))" 2>/dev/null)

echo
echo "== VERDICT =="
echo "  RED : ok=$R_OK seconds=$R_S"
echo "  GREEN: ok=$G_OK seconds=$G_S bytes=$G_B"
[ "$R_OK" = "False" ] && ok "RED reproduced the failure (read did not succeed)" || no "RED did NOT fail — GREEN proves nothing"
[ "$G_OK" = "True" ] && ok "GREEN read succeeded with indexes present" || no "GREEN read still failed"
[ "${G_B:-0}" -gt 0 ] 2>/dev/null && ok "GREEN returned actual records ($G_B bytes) — not an empty success" || no "GREEN returned no bytes; an empty 'ok' is the vacuous pass"
echo
echo "RESULT: $PASS pass / $FAIL fail"
[ "$FAIL" -eq 0 ]
