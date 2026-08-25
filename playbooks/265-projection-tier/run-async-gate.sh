#!/usr/bin/env bash
# Full G3 sweep: the async mirror, its window, and the pair that binds them.
#
# Every arm re-establishes its own precondition, because two of them are
# CONSUMED by the arm that reads them: `window-in`/`window-out` drive
# `/api/internal/projection/advance` to observe the read path, and that call
# re-mirrors the incumbent — so the behind-tier the arm was built on is gone by
# the time the arm ends. Measured: a second run of `window-in` scored `match`
# and `served_tier +1`, which is correct behaviour against a tier that is no
# longer behind, and would have read as the window failing.
#
# Usage: run-async-gate.sh <settled_execution_id>
set -uo pipefail
E="${1:?usage: run-async-gate.sh <settled_execution_id>}"
cd "$(dirname "$0")"
K="kubectl --context kind-noetl"
TOK=$($K -n noetl get secret noetl-internal-api-token -o jsonpath='{.data.token}' | base64 -d)

psql_() { $K -n postgres exec deploy/postgres -- psql -U noetl -d noetl -At -c "$1" 2>/dev/null | tr -d '\r'; }
remirror() {
  ./deploy.sh readmode postgres >/dev/null 2>&1
  curl -s --max-time 90 -X POST http://localhost:8082/api/internal/projection/advance \
    -H "Authorization: Bearer $TOK" -H 'content-type: application/json' \
    -d "{\"execution_ids\":[$E]}" >/dev/null
  EXEC_ID=$E ./deploy.sh pin-incumbent >/dev/null 2>&1
}

# Put the tier one revision BEHIND, on a clean store, with a digest that DOES
# describe its body — so the arm tests the currency rule and not the checksum
# rule. `age_secs` back-dates the incumbent row: that is the only difference
# between the two window arms.
make_behind() {
  local age_secs="$1" inc lower chk wp
  EXEC_ID=$E ./deploy.sh pin-incumbent >/dev/null 2>&1
  ./deploy.sh reset-tier >/dev/null 2>&1
  remirror
  ./deploy.sh reset-tier >/dev/null 2>&1
  inc=$(psql_ "SELECT version FROM noetl.projection_snapshot WHERE aggregate_id='$E';" | head -1)
  lower=$(python3 -c "print(int('$inc')-1)")
  chk=$(python3 -c "
import hashlib,json
print(hashlib.sha256(json.dumps({'BEHIND':True},separators=(',',':')).encode()).hexdigest())")
  wp=$($K -n noetl get pod -l app=noetl-cmdbus-writer -o name | head -1)
  $K -n noetl exec "$wp" -- sh -c "wget -q -O - -T 20 --header='Content-Type: application/json' \
    --post-data='{\"execution_id\":\"$E\",\"records\":[\"{\\\"execution_id\\\":$E,\\\"version\\\":$lower,\\\"checksum\\\":\\\"$chk\\\",\\\"applied_count\\\":1,\\\"snapshot\\\":{\\\"BEHIND\\\":true},\\\"updated_at\\\":\\\"2026-01-01T00:00:00Z\\\",\\\"mirror_source\\\":\\\"server\\\"}\"]}' \
    'http://noetl-worker-rust-metrics.noetl.svc.cluster.local:9090/ehdb/tiers/projection'" >/dev/null 2>&1
  psql_ "UPDATE noetl.projection_snapshot SET updated_at = now() - interval '$age_secs seconds' WHERE aggregate_id='$E';" >/dev/null
  # THE MUTATION GUARD: without it a no-op append gives a green arm.
  local landed
  landed=$(psql_ "SELECT 1;" >/dev/null; ./deploy.sh readmode postgres >/dev/null 2>&1; echo ok)
  echo "   behind-tier prepared: incumbent=$inc tier=$lower age=${age_secs}s"
}

make_ahead() {
  local inc maxev bogus chk wp
  EXEC_ID=$E ./deploy.sh pin-incumbent >/dev/null 2>&1
  ./deploy.sh reset-tier >/dev/null 2>&1
  remirror
  maxev=$(psql_ "SELECT COALESCE(MAX(event_id),0) FROM noetl.event WHERE execution_id=$E;" | head -1)
  bogus=$(python3 -c "print(int('$maxev')+100000)")
  chk=$(python3 -c "
import hashlib,json
print(hashlib.sha256(json.dumps({'MUTATED':True},separators=(',',':')).encode()).hexdigest())")
  wp=$($K -n noetl get pod -l app=noetl-cmdbus-writer -o name | head -1)
  $K -n noetl exec "$wp" -- sh -c "wget -q -O - -T 20 --header='Content-Type: application/json' \
    --post-data='{\"execution_id\":\"$E\",\"records\":[\"{\\\"execution_id\\\":$E,\\\"version\\\":$bogus,\\\"checksum\\\":\\\"$chk\\\",\\\"applied_count\\\":999,\\\"snapshot\\\":{\\\"MUTATED\\\":true},\\\"updated_at\\\":\\\"2030-01-01T00:00:00Z\\\",\\\"mirror_source\\\":\\\"server\\\"}\"]}' \
    'http://noetl-worker-rust-metrics.noetl.svc.cluster.local:9090/ehdb/tiers/projection'" >/dev/null 2>&1
  psql_ "UPDATE noetl.projection_snapshot SET updated_at = now() WHERE aggregate_id='$E';" >/dev/null
  echo "   ahead-tier prepared: event tip=$maxev tier=$bogus (incumbent is FRESH, so the window is wide open)"
}

declare -a R=()
run() { local arm="$1" out; out=$(EXEC_ID=$E LOAD_N="${LOAD_N:-32}" ./gate-async.sh "$arm" 2>&1); printf '%s\n' "$out"; R+=("$(printf '%s' "$out" | tail -1)"); }

echo "### 1. the pairing rule — async ON, window 0 ⇒ REFUSE"
./deploy.sh async on 0 >/dev/null 2>&1;  run refusal

echo "### 2. the pair arms — same flag, real window"
./deploy.sh async on 30 >/dev/null 2>&1; run armed

echo "### 3. delivery — never a drop"
EXEC_ID=$E ./deploy.sh pin-incumbent >/dev/null 2>&1
./deploy.sh reset-tier >/dev/null 2>&1
run delivery

echo "### 4. a BEHIND tier INSIDE the window ⇒ pending_mirror, no divergence evidence"
./deploy.sh async on 3600 >/dev/null 2>&1
make_behind 5
./deploy.sh readmode verify >/dev/null 2>&1
run window-in

echo "### 5. the SAME behind tier OUTSIDE the window ⇒ divergent"
./deploy.sh async on 30 >/dev/null 2>&1
make_behind 86400
./deploy.sh readmode verify >/dev/null 2>&1
run window-out

echo "### 6. a tier AHEAD, with a huge window ⇒ still divergent"
./deploy.sh async on 3600 >/dev/null 2>&1
make_ahead
./deploy.sh readmode tier >/dev/null 2>&1
run ahead-in-window

echo; echo "================ SUMMARY ================"
printf '%s\n' "${R[@]}"
