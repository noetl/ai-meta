#!/usr/bin/env bash
# writer-env-roll.sh <NAME=VALUE> : add/override ONE env var on the writer (rolls it; image unchanged).
#   ONE template change: image + env NOETL_EHDB_TIER_PRUNE_MODE=dry_run.
#   NO safe-to-evict annotation (it forces extended-duration node affinity).
#   Auto-rollback: new pod Pending > 60 s -> rollout undo + replace pod.
set -uo pipefail
KV="$1"
K="kubectl --context noetl-prod -n noetl"
OLD_UID=$($K get pod noetl-cmdbus-writer-0 -o jsonpath='{.metadata.uid}')
PATCH=$(python3 - "$KV" <<'PY'
import json,sys
n,v=sys.argv[1].split('=',1)
print(json.dumps({"spec":{"template":{"spec":{"containers":[{"name":"noetl-worker","env":[{"name":n,"value":v}]}]}}}}))
PY
)
T0=$(date +%s)
$K patch sts noetl-cmdbus-writer --type=strategic -p "$PATCH" >/dev/null || { echo "PATCH FAILED"; exit 9; }
echo "+0s patched sts env $KV (image unchanged; no annotation)"
pend=""; up=""
for i in $(seq 1 100); do
  now=$(( $(date +%s) - T0 ))
  st=$($K get pod noetl-cmdbus-writer-0 -o jsonpath='{.metadata.uid} {.status.phase} node={.spec.nodeName} ready={.status.containerStatuses[0].ready} restarts={.status.containerStatuses[0].restartCount}' 2>/dev/null || echo "absent")
  uid=${st%% *}; phase=$(echo "$st" | awk '{print $2}')
  echo "+${now}s ${st/$OLD_UID/OLD}" | cut -c1-140
  if [ "$uid" != "$OLD_UID" ] && [ "$phase" = "Pending" ]; then
    [ -z "$pend" ] && pend=$now
    if [ $((now-pend)) -gt 60 ]; then
      echo "+${now}s ROLLBACK: new writer Pending >60s"
      $K get events --field-selector involvedObject.name=noetl-cmdbus-writer-0 --sort-by=.lastTimestamp 2>/dev/null | tail -3 | cut -c1-220
      $K rollout undo sts/noetl-cmdbus-writer >/dev/null; $K delete pod noetl-cmdbus-writer-0 --wait=false >/dev/null
      exit 3
    fi
  else pend=""; fi
  if [ "$uid" != "$OLD_UID" ] && echo "$st" | grep -q 'ready=true'; then up=$now; echo "+${now}s writer READY"; break; fi
  sleep 3
done
[ -n "$up" ] || { echo "WRITER NOT READY IN WATCH WINDOW (not Pending) — caller decides"; exit 2; }
