#!/usr/bin/env bash
# Kind gate for ai-meta#265 G3 — the async projection mirror and the window that
# pairs with it.
#
# Four claims, in order of consequence:
#
#   1. **The pair is enforced.** Async armed with a zero tolerance window
#      REFUSES to arm and stays inline, loudly. Not documented — measured, off
#      `..._async_enabled` and the log line.
#   2. **Async delivers everything.** Every snapshot the writer accepts reaches
#      the tier: `enqueued` == `drained`, pending returns to 0, and the tier's
#      record count equals the number of snapshots submitted. Never a drop.
#   3. **The window forgives lateness only.** A tier that is behind inside the
#      window scores `pending_mirror` and publishes NO divergence evidence; the
#      same tier outside the window scores `divergent`. A tier AHEAD scores
#      `divergent` at any window size.
#   4. **The read path agrees.** Behind-inside-window demotes as
#      `stale_within_window` (non-fault); behind-outside-window as
#      `stale_version` (fault). Same demote, different alerting.
#
# TWO-SIDED throughout: every arm moves exactly one variable against the arm it
# is compared with, and each claim is asserted in both directions so a check
# that always says one thing fails.
#
# Usage: gate-async.sh <arm> [execution_id]
#   arm ∈ { refusal, armed, delivery, window-in, window-out, ahead-in-window }
set -uo pipefail

SERVER="${SERVER:-http://localhost:8082}"
NS=noetl
ARM="${1:-refusal}"
EXEC_ID="${2:-${EXEC_ID:-}}"

PASS=0; FAIL=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL+1)); }
info() { printf '        %s\n' "$1"; }
k() { kubectl --context kind-noetl -n "$NS" "$@"; }
psql_() { kubectl --context kind-noetl -n postgres exec deploy/postgres -- \
            psql -U noetl -d noetl -At -c "$1" 2>/dev/null | tr -d '\r'; }
field() {
  local json="$1" path="$2" v
  v=$(printf '%s' "$json" | jq -r "$path" 2>/dev/null) || { printf '__ABSENT__'; return; }
  [ "$v" = "null" ] && printf '__ABSENT__' || printf '%s' "$v"
}
eq()  { if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1 — got '$2', want '$3'"; fi; }
gt0() { if [ "$2" != "__ABSENT__" ] && [ "${2:-0}" -gt 0 ] 2>/dev/null; then ok "$1 ($2)"; else bad "$1 — got '$2', want > 0"; fi; }

# Absence preserved: prometheus prunes empty families, so a series that never
# fired is ABSENT — a different fact from 0, and the difference between "this
# binary has no queue" and "the queue did not run".
# ⚠ `grep -v '^#'` FIRST. Without it a bare (unlabelled) metric name also
# matches its own `# HELP` line, and `awk '{print $NF}'` then returns the last
# WORD OF THE HELP TEXT as the value — this gate's first run reported the
# async_enabled gauge as `G3).`. The B1 gate never saw it because every needle
# there carried a `{outcome="..."}` that cannot appear in a HELP line.
#
# Absence is preserved: a series that never fired is ABSENT, which is a
# different fact from 0 — the difference between "this binary has no queue" and
# "the queue did not run".
srv_metric() {
  local needle="$1" v
  v=$(curl -s --max-time 15 "$SERVER/metrics" \
      | grep -v '^#' | grep -F "$needle" | awk '{print $NF}' | head -1 | tr -d '\r')
  [ -n "$v" ] && printf '%s' "$v" || printf '__ABSENT__'
}
# ⚠ Label order is ALPHABETICAL in the exporter's output, not declaration order.
# `{tier="projection",kind="stale_version"}` matches nothing while
# `{kind="stale_version",tier="projection"}` matches a series pinned at 0 — and
# the miss reads as __ABSENT__, i.e. as "no evidence published", which is the
# answer this gate was asking for. It would have passed for the wrong reason on
# the opposite arm.
q_total() { srv_metric "noetl_ehdb_projection_mirror_queue_total{outcome=\"$1\"}"; }
read_total() { srv_metric "noetl_ehdb_projection_read_total{outcome=\"$1\"}"; }
delta() {
  local b="$1" a="$2"
  [ "$a" = "__ABSENT__" ] && { printf '__ABSENT__'; return; }
  [ "$b" = "__ABSENT__" ] && b=0
  awk -v a="$b" -v c="$a" 'BEGIN{printf "%d", c-a}'
}

internal_token() { k get secret noetl-internal-api-token -o jsonpath='{.data.token}' | base64 -d; }
advance() {
  local e="$1" tok body n
  tok=$(internal_token)
  for _ in $(seq 1 10); do
    body=$(curl -s --max-time 60 -X POST "$SERVER/api/internal/projection/advance" \
            -H "Authorization: Bearer $tok" -H 'content-type: application/json' \
            -d "{\"execution_ids\":[$e]}")
    n=$(field "$body" '.advanced | length')
    [ "$n" != "__ABSENT__" ] && [ "${n:-0}" -ge 1 ] && { printf '%s' "$body"; return; }
    sleep 3
  done
  printf '%s' "$body"
}
tier_records() {
  local e="$1" wp
  wp=$(k get pod -l app=noetl-cmdbus-writer -o name | head -1)
  k exec "$wp" -- sh -c "wget -q -O - -T 20 \
    'http://noetl-worker-rust-metrics.noetl.svc.cluster.local:9090/ehdb/tiers/projection?execution=$e&limit=500' 2>/dev/null" 2>/dev/null \
    | python3 -c "
import json,sys
try: print(json.load(sys.stdin).get('record_count', 0))
except Exception: print('__ABSENT__')
"
}
parity() { curl -s --max-time 30 "$SERVER/api/ehdb/projection-parity/executions/$1"; }
parity_outcome() {
  local b; b=$(parity "$1")
  local o; o=$(field "$b" '.outcome')
  [ "$o" = "__ABSENT__" ] && o=$(field "$b" '.result.outcome')
  printf '%s' "$o"
}

echo
echo "=== ai-meta#265 G3 async-mirror gate — arm: $ARM ==="
echo

echo "-- 0. harness --"
health=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$SERVER/api/health")
eq "server answers /api/health" "$health" "200"
[ "$health" = "200" ] || { echo; echo "ABORT: server unreachable."; exit 2; }

envof() {
  k get deploy noetl-server-rust -o json | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(next((e.get('value','') for e in d['spec']['template']['spec']['containers'][0].get('env',[])
            if e['name']=='$1'), '<unset>'))"
}
info "MIRROR_ASYNC          = $(envof NOETL_EHDB_PROJECTION_MIRROR_ASYNC)"
info "PARITY_LAG_TOLERANCE  = $(envof NOETL_EHDB_PROJECTION_PARITY_LAG_TOLERANCE_SECS)"
info "READ_SOURCE           = $(envof NOETL_EHDB_PROJECTION_READ_SOURCE)"

armed=$(srv_metric 'noetl_ehdb_projection_mirror_async_enabled')
tol=$(srv_metric 'noetl_ehdb_projection_parity_lag_tolerance_seconds')
if [ "$armed" = "__ABSENT__" ]; then
  bad "the async_enabled gauge is ABSENT — this binary predates G3, or init never ran"
else
  ok "async_enabled gauge present ($armed)"
fi
info "published lag tolerance: $tol"

echo
echo "-- 1. projection comparator controls (before) --"
st=$(curl -s --max-time 15 "$SERVER/api/ehdb/projection-parity/self-test")
eq "controls_ok" "$(field "$st" '.controls_ok')" "true"
eq "controls unexpected" "$(field "$st" '[.controls[]? | select(.expected == false)] | length')" "0"
gt0 "controls expected > 0" "$(field "$st" '[.controls[]? | select(.expected == true)] | length')"

case "$ARM" in

# --- 1. THE PAIRING RULE --------------------------------------------------
# The claim this whole change rests on. Deployed with async ON and the window
# at 0, the process must stay INLINE and say so.
refusal)
  echo
  echo "-- 2. async armed with a ZERO window must REFUSE to arm --"
  eq "the flag really is on" "$(envof NOETL_EHDB_PROJECTION_MIRROR_ASYNC)" "true"
  eq "the window really is 0" "$(envof NOETL_EHDB_PROJECTION_PARITY_LAG_TOLERANCE_SECS)" "0"
  # The measurement, not the log line: a gauge an operator can read.
  eq "async_enabled is 0 — the queue did NOT arm" "$armed" "0"
  eq "published tolerance is 0" "$tol" "0"
  # ...and the refusal is attributable, not silent.
  refused=$(k logs deploy/noetl-server-rust --tail=4000 2>/dev/null \
            | grep -c 'REFUSING to arm the async projection mirror' || true)
  gt0 "the refusal is logged with its reason" "$refused"
  # Two-sided within the arm: refusing must not have broken the inline mirror.
  eq "queue outcome series are present at 0 (not absent)" "$(q_total enqueued)" "0"
  ;;

# --- 2. THE PAIR ARMS -----------------------------------------------------
# Same flag, a real window. The ONLY variable that moved is the tolerance.
armed)
  echo
  echo "-- 2. async + a real window ARMS --"
  eq "the flag is on" "$(envof NOETL_EHDB_PROJECTION_MIRROR_ASYNC)" "true"
  gt0 "the window is non-zero" "$(envof NOETL_EHDB_PROJECTION_PARITY_LAG_TOLERANCE_SECS)"
  eq "async_enabled is 1 — the queue ARMED" "$armed" "1"
  gt0 "the published tolerance matches a real window" "$tol"
  armlog=$(k logs deploy/noetl-server-rust --tail=4000 2>/dev/null \
           | grep -c 'async projection mirror queue ARMED' || true)
  gt0 "the arming is logged" "$armlog"
  refused=$(k logs deploy/noetl-server-rust --tail=4000 2>/dev/null \
            | grep -c 'REFUSING to arm the async projection mirror' || true)
  eq "and it did NOT also refuse" "$refused" "0"
  ;;

# --- 3. DELIVERY: never a drop -------------------------------------------
delivery)
  echo
  echo "-- 2. every accepted snapshot reaches the tier --"
  [ -n "$EXEC_ID" ] || { bad "delivery needs an execution id"; exit 2; }
  eq "async_enabled is 1" "$armed" "1"
  before_enq=$(q_total enqueued);  [ "$before_enq" = "__ABSENT__" ] && before_enq=0
  before_drn=$(q_total drained);   [ "$before_drn" = "__ABSENT__" ] && before_drn=0
  before_rec=$(tier_records "$EXEC_ID"); [ "$before_rec" = "__ABSENT__" ] && before_rec=0
  N="${LOAD_N:-32}"
  tok=$(internal_token)
  for _ in $(seq 1 "$N"); do
    curl -s --max-time 60 -X POST "$SERVER/api/internal/projection/advance" \
      -H "Authorization: Bearer $tok" -H 'content-type: application/json' \
      -d "{\"execution_ids\":[$EXEC_ID]}" >/dev/null &
  done
  wait
  # Let the drain finish. Settled on the PENDING GAUGE, not on a fixed sleep —
  # a sleep that is too short reports a drop that is really a race, which is
  # the most expensive way for this arm to be wrong.
  for _ in $(seq 1 60); do
    p=$(srv_metric 'noetl_ehdb_projection_mirror_pending_snapshots')
    [ "$p" = "0" ] && break
    sleep 1
  done
  enq=$(delta "$before_enq" "$(q_total enqueued)")
  drn=$(delta "$before_drn" "$(q_total drained)")
  inline_full=$(q_total queue_full_inline); [ "$inline_full" = "__ABSENT__" ] && inline_full=0
  after_rec=$(tier_records "$EXEC_ID")
  info "submitted=$N enqueued=+$enq drained=+$drn tier_records $before_rec -> $after_rec"
  gt0 "snapshots were enqueued (the async path really ran)" "$enq"
  eq  "everything enqueued was drained — NEVER a drop" "$drn" "$enq"
  eq  "pending returned to 0" "$(srv_metric 'noetl_ehdb_projection_mirror_pending_snapshots')" "0"
  eq  "tier gained exactly what was submitted" "$((after_rec - before_rec))" "$N"
  eq  "no snapshot was abandoned at shutdown" "$(q_total shutdown_abandoned)" "0"
  info "queue_full_inline (rung 3) so far: $inline_full"
  ;;

# --- 4. THE WINDOW, both sides -------------------------------------------
# The tier is made BEHIND by appending an older revision on a reset tier. The
# only difference between these two arms is the configured window, so a
# comparator that ignored it (or one that forgave everything) fails one.
window-in|window-out)
  echo
  echo "-- 2. a BEHIND tier, window $( [ "$ARM" = window-in ] && echo INSIDE || echo OUTSIDE ) --"
  [ -n "$EXEC_ID" ] || { bad "needs an execution id"; exit 2; }
  before_div=$(srv_metric 'noetl_ehdb_crossstore_divergence_total{kind="stale_version",tier="projection"}')
  [ "$before_div" = "__ABSENT__" ] && before_div=0
  before_pend=$(srv_metric 'noetl_ehdb_crossstore_pending_total{tier="projection"}')
  [ "$before_pend" = "__ABSENT__" ] && before_pend=0

  outcome=$(parity_outcome "$EXEC_ID")
  # The projection comparator answers NESTED under `.result`; the event-log one
  # answers FLAT. Reading the wrong envelope returns __ABSENT__ — which for an
  # age is merely a misleading log line, but for a VERDICT would be scored as
  # "the verdict moved". Both are tried, flat first, same as parity_outcome().
  pbody=$(parity "$EXEC_ID")
  age=$(field "$pbody" '.snapshot_age_seconds')
  [ "$age" = "__ABSENT__" ] && age=$(field "$pbody" '.result.snapshot_age_seconds')
  info "snapshot_age_seconds=$age  window=$tol  verdict=$outcome"

  if [ "$ARM" = "window-in" ]; then
    eq "verdict is pending_mirror, NOT divergent" "$outcome" "pending_mirror"
    # THE ASSERTION THAT MATTERS. An untaken comparison must publish no
    # divergence evidence: ai-meta#264 is the record of a probe inflating the
    # counter its own alert reads.
    eq "no divergence evidence was published" \
       "$(delta "$before_div" "$(srv_metric 'noetl_ehdb_crossstore_divergence_total{kind="stale_version",tier="projection"}')")" "0"
    gt0 "the window's COST was published (pending counter moved)" \
       "$(delta "$before_pend" "$(srv_metric 'noetl_ehdb_crossstore_pending_total{tier="projection"}')")"
  else
    eq "verdict is divergent once the window has passed" "$outcome" "divergent"
    gt0 "divergence evidence WAS published" \
       "$(delta "$before_div" "$(srv_metric 'noetl_ehdb_crossstore_divergence_total{kind="stale_version",tier="projection"}')")"
  fi

  echo
  echo "-- 3. the read path agrees with the comparator --"
  b_in=$(read_total stale_within_window);  [ "$b_in" = "__ABSENT__" ] && b_in=0
  b_out=$(read_total stale_version);       [ "$b_out" = "__ABSENT__" ] && b_out=0
  b_srv=$(read_total served_tier);         [ "$b_srv" = "__ABSENT__" ] && b_srv=0
  advance "$EXEC_ID" >/dev/null
  if [ "$ARM" = "window-in" ]; then
    gt0 "the read demoted as stale_within_window (non-fault)" "$(delta "$b_in" "$(read_total stale_within_window)")"
    eq  "and NOT as stale_version (which pages)" "$(delta "$b_out" "$(read_total stale_version)")" "0"
  else
    gt0 "the read demoted as stale_version (fault)" "$(delta "$b_out" "$(read_total stale_version)")"
    eq  "and NOT as stale_within_window" "$(delta "$b_in" "$(read_total stale_within_window)")" "0"
  fi
  eq "served_tier did NOT move — a behind tier is never served" "$(delta "$b_srv" "$(read_total served_tier)")" "0"
  ;;

# --- 5. THE WINDOW MUST NOT FORGIVE THE DANGEROUS CASE -------------------
ahead-in-window)
  echo
  echo "-- 2. a tier AHEAD of the event log, with a LARGE window --"
  [ -n "$EXEC_ID" ] || { bad "needs an execution id"; exit 2; }
  gt0 "the window is large" "$tol"
  outcome=$(parity_outcome "$EXEC_ID")
  # The whole point: no window size may turn `ahead_version` into a tolerated
  # state. A mirror that has not caught up cannot produce a record claiming an
  # event that does not exist.
  eq "verdict is divergent despite the window" "$outcome" "divergent"
  b_ah=$(read_total version_ahead); [ "$b_ah" = "__ABSENT__" ] && b_ah=0
  b_srv=$(read_total served_tier);  [ "$b_srv" = "__ABSENT__" ] && b_srv=0
  advance "$EXEC_ID" >/dev/null
  gt0 "the read demoted as version_ahead (fault) despite the window" "$(delta "$b_ah" "$(read_total version_ahead)")"
  eq  "served_tier did NOT move" "$(delta "$b_srv" "$(read_total served_tier)")" "0"
  ;;

*) echo "unknown arm: $ARM" >&2; exit 2 ;;
esac

echo
echo "-- 4. projection comparator controls (after) --"
st2=$(curl -s --max-time 15 "$SERVER/api/ehdb/projection-parity/self-test")
eq "controls_ok (after)" "$(field "$st2" '.controls_ok')" "true"
eq "controls unexpected (after)" "$(field "$st2" '[.controls[]? | select(.expected == false)] | length')" "0"

echo
echo "=== arm $ARM: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
