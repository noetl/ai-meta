#!/usr/bin/env bash
# Full B1 read-serve sweep, with the resets each arm needs between them.
#
# The resets are not housekeeping — three of them exist because an arm leaves
# state that would decide the NEXT arm's verdict:
#
#  * `reset-tier` before every mutation arm. The read path picks the newest
#    record by (version, sequence), so a crafted record left behind shadows the
#    next mutation and the gate reports the PREVIOUS arm's reason. Measured: the
#    `corrupt` arm scored `version_ahead` because the `ahead` arm's record was
#    still newest.
#  * `reset-tier` restarts the writer, it does not only truncate. worker#280's
#    runtime cache is not evicted by truncating the file underneath it — after
#    a truncate the file held 3 lines while the relay still served 15 records.
#  * `pin-incumbent` after any arm that ran `bump-incumbent`. A bumped version
#    SURVIVES a recompute (advance floors at the snapshot's own version), so the
#    incumbent stays above the event-log tip and every later arm turns into
#    `version_ahead`.
#
# Usage: run-read-gate.sh <settled_execution_id>
set -uo pipefail
E="${1:?usage: run-read-gate.sh <settled_execution_id>}"
cd "$(dirname "$0")"
TOK=$(kubectl --context kind-noetl -n noetl get secret noetl-internal-api-token -o jsonpath='{.data.token}' | base64 -d)
RELAY=http://noetl-worker-rust-metrics.noetl.svc.cluster.local:9090

remirror() {
  ./deploy.sh readmode postgres >/dev/null 2>&1
  curl -s --max-time 90 -X POST http://localhost:8082/api/internal/projection/advance \
    -H "Authorization: Bearer $TOK" -H 'content-type: application/json' \
    -d "{\"execution_ids\":[$E]}" >/dev/null
  EXEC_ID=$E ./deploy.sh pin-incumbent >/dev/null 2>&1
}
fresh() { EXEC_ID=$E ./deploy.sh pin-incumbent >/dev/null 2>&1; ./deploy.sh reset-tier >/dev/null 2>&1; remirror; }

declare -a RESULTS=()
run() {  # run <arm> <readmode>
  local arm="$1" mode="$2" out
  ./deploy.sh readmode "$mode" >/dev/null 2>&1
  out=$(EXEC_ID=$E LOAD_N="${LOAD_N:-48}" ./gate-read.sh "$arm" 2>&1)
  printf '%s\n' "$out"
  RESULTS+=("$(printf '%s' "$out" | tail -1)")
}

fresh;                        run baseline    postgres
fresh;                        run verify      verify
fresh;                        run tier        tier
fresh;                        run ahead       tier
fresh;                        run corrupt     tier
./deploy.sh reset-tier >/dev/null 2>&1; EXEC_ID=$E ./deploy.sh pin-incumbent >/dev/null 2>&1
                              run behind      verify
fresh
kubectl --context kind-noetl -n noetl set env deploy/noetl-server-rust \
  NOETL_EHDB_WORKER_QUERY_URL=http://10.255.255.1:9090 >/dev/null
kubectl --context kind-noetl -n noetl rollout status deploy/noetl-server-rust --timeout=300s >/dev/null
sleep 6;                      run unavailable tier
kubectl --context kind-noetl -n noetl set env deploy/noetl-server-rust \
  NOETL_EHDB_WORKER_QUERY_URL="$RELAY" >/dev/null
kubectl --context kind-noetl -n noetl rollout status deploy/noetl-server-rust --timeout=300s >/dev/null
sleep 8
fresh;                        run load        tier

echo; echo "================ SUMMARY ================"
printf '%s\n' "${RESULTS[@]}"
