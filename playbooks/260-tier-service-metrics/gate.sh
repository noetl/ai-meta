#!/usr/bin/env bash
# Kind gate for noetl/ai-meta#260 — is the tier service's SERVER half observable?
#
# The claim under test: after instrumenting `src/ehdb/tier_service.rs`, driving
# real operations over the real length-framed socket moves the right
# `noetl_ehdb_dataplane_ops_total{operation="tier_service.*"}` series and the
# `noetl_ehdb_tier_service_duration_seconds` histogram — and, before any traffic,
# every one of those series READS 0 rather than being absent.
#
# Gate design notes; read before changing an arm:
#
#   * every assertion is behaviour-level, against the `/metrics` endpoint of a
#     built image in kind, driven through the actual TCP protocol. Nothing here
#     asserts on worker source.
#   * a failed fetch is a FAILURE, never a zero that reads as a pass. `metric()`
#     returns the sentinel `__ABSENT__` for a series that is not present, and
#     `__ABSENT__` never compares equal to `0`. That distinction IS the feature
#     under test, so collapsing it would make the gate unable to see its own
#     subject.
#   * the `off` arm must show the series ENTIRELY ABSENT, or the gate cannot
#     discriminate: if the renderer emitted these lines unconditionally, the
#     `up` arm's pinned zeros would prove nothing about the pin.
#   * the mutation arm must FAIL. A gate that has never once failed is
#     indistinguishable from a gate that cannot fail.
#
# Usage: gate.sh <arm>
#   arm ∈ { up, off, mutated }
set -uo pipefail

METRICS="${METRICS:-http://127.0.0.1:19090/metrics}"
TIER="${TIER:-127.0.0.1:19110}"
TIERCTL="${TIERCTL:-$(dirname "$0")/tierctl.py}"
ARM="${1:-up}"

PASS=0
FAIL=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL+1)); }
info() { printf '        %s\n' "$1"; }

SNAP=""
snapshot() {
  SNAP=$(curl -s --max-time 15 "$METRICS")
  [ -n "$SNAP" ]
}

# Read one metric out of the current snapshot by EXACT line prefix.
#
# Emits `__ABSENT__` when the series does not exist. This is the single most
# important helper in the file: "the series is missing" and "the series is 0"
# are the two states #260 exists to separate, and a helper that defaulted a
# missing series to 0 would report a pass on precisely the bug.
metric() {
  local name="$1" v
  v=$(printf '%s' "$SNAP" | awk -v k="$name" '$1 == k { print $2; found=1 } END { if (!found) print "__ABSENT__" }')
  [ -z "$v" ] && v="__ABSENT__"
  printf '%s' "$v"
}

# Counter with labels, written as the renderer emits it (labels sorted).
ops() { metric "noetl_ehdb_dataplane_ops_total{operation=\"tier_service.$1\",outcome=\"$2\"}"; }
hcount() { metric "noetl_ehdb_tier_service_duration_seconds_count{operation=\"$1\"}"; }
hsum()   { metric "noetl_ehdb_tier_service_duration_seconds_sum{operation=\"$1\"}"; }
hinf()   { metric "noetl_ehdb_tier_service_duration_seconds_bucket{le=\"+Inf\",operation=\"$1\"}"; }

eq() {
  local label="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then ok "$label ($got)"; else bad "$label — got '$got', want '$want'"; fi
}

# Closed label set, mirroring TIER_SERVICE_SERIES in src/ehdb/metrics.rs. The
# gate enumerates it independently ON PURPOSE: if someone deletes a pin, this
# list still demands it, and the gate fails.
SERIES=(
  "health ok"
  "append ok" "append invalid" "append unavailable" "append error"
  "read_execution hit" "read_execution miss" "read_execution invalid"
  "read_execution unavailable" "read_execution error"
  "scan hit" "scan miss" "scan unavailable" "scan error"
  "unsupported unsupported"
  "conn accepted" "conn closed" "conn protocol_error" "conn write_error" "conn accept_error"
)
OPS=(health append read_execution scan unsupported)

echo
echo "=== ai-meta#260 gate — arm: $ARM ==="
echo

# ---------------------------------------------------------------------------
# 0. Positive control on the harness.
#
# Every check below reads a number out of an HTTP body. Prove the transport
# works and that we are talking to a worker at all before trusting any zero it
# carries — an unreachable endpoint yields an empty body, and an unguarded
# harness would read `__ABSENT__` everywhere and, on the `off` arm, PASS.
# ---------------------------------------------------------------------------
echo "-- 0. harness reachability --"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$METRICS")
eq "/metrics answers" "$code" "200"
snapshot || { echo; echo "ABORT: empty /metrics body; every later reading would be an artefact."; exit 2; }
bi=$(printf '%s' "$SNAP" | grep -c '^noetl_worker_build_info{')
if [ "$bi" -ge 1 ]; then
  ok "build_info present ($(printf '%s' "$SNAP" | grep -m1 '^noetl_worker_build_info{' | sed 's/noetl_worker_build_info//'))"
else
  bad "build_info absent — cannot tell whether this pod predates the metric"
fi
info "snapshot: $(printf '%s' "$SNAP" | wc -l | tr -d ' ') lines"

# ---------------------------------------------------------------------------
# 1. The `off` arm: no listener ⇒ the series must not exist AT ALL.
#
# This is the discriminating half. It proves the pinned zeros in the `up` arm
# come from the listener existing, not from a renderer that always emits them.
# ---------------------------------------------------------------------------
if [ "$ARM" = "off" ]; then
  echo
  echo "-- 1. no listener ⇒ no tier-service series --"
  leaked=0
  for pair in "${SERIES[@]}"; do
    set -- $pair
    v=$(ops "$1" "$2")
    [ "$v" != "__ABSENT__" ] && { bad "tier_service.$1/$2 leaked into a process with no listener (=$v)"; leaked=1; }
  done
  [ "$leaked" -eq 0 ] && ok "all ${#SERIES[@]} request series absent"
  for op in "${OPS[@]}"; do
    v=$(hcount "$op")
    eq "histogram $op absent" "$v" "__ABSENT__"
  done
  eq "store_appends_total absent" "$(metric noetl_ehdb_tier_service_store_appends_total)" "__ABSENT__"
  eq "store_bytes absent"         "$(metric noetl_ehdb_tier_service_store_bytes)" "__ABSENT__"
  eq "store_sequence absent"      "$(metric noetl_ehdb_tier_service_store_sequence)" "__ABSENT__"
  echo
  echo "=== arm $ARM: $PASS passed, $FAIL failed ==="
  [ "$FAIL" -eq 0 ] || exit 1
  exit 0
fi

# ---------------------------------------------------------------------------
# 2. Listener up, NO traffic yet: every series must READ 0.
#
# The positive control the whole issue is about. `rate(...) == 0` on a dashboard
# has to mean "nothing is calling the tier service"; it must not also mean "the
# metric does not exist here".
# ---------------------------------------------------------------------------
echo
echo "-- 2. pinned at zero before any traffic --"
missing=0
for pair in "${SERIES[@]}"; do
  set -- $pair
  v=$(ops "$1" "$2")
  if [ "$v" = "__ABSENT__" ]; then
    bad "tier_service.$1/$2 is ABSENT — a zero here would be unreadable"
    missing=1
  elif [ "$v" != "0" ]; then
    # Non-zero before traffic is not automatically wrong (the writer serves the
    # platform), but it must be reported: the deltas below are computed from it.
    info "tier_service.$1/$2 starts at $v (delta-checked below)"
  fi
done
[ "$missing" -eq 0 ] && ok "all ${#SERIES[@]} request series exist before any traffic"
for op in "${OPS[@]}"; do
  v=$(hcount "$op")
  [ "$v" = "__ABSENT__" ] && bad "histogram $op ABSENT before traffic" || ok "histogram $op exists before traffic ($v)"
done
for m in noetl_ehdb_tier_service_store_appends_total noetl_ehdb_tier_service_store_bytes noetl_ehdb_tier_service_store_sequence; do
  v=$(metric "$m")
  [ "$v" = "__ABSENT__" ] && bad "$m ABSENT" || ok "$m exists ($v)"
done

# Baselines for the delta assertions.
B_HEALTH=$(ops health ok);                B_APPEND_OK=$(ops append ok)
B_APPEND_INV=$(ops append invalid);       B_HIT=$(ops read_execution hit)
B_MISS=$(ops read_execution miss);        B_SCAN_HIT=$(ops scan hit)
B_UNSUP=$(ops unsupported unsupported);   B_PROTO=$(ops conn protocol_error)
B_ACCEPTED=$(ops conn accepted)
B_H_HEALTH=$(hcount health);              B_H_APPEND=$(hcount append)
B_H_READ=$(hcount read_execution)
B_APPENDS=$(metric noetl_ehdb_tier_service_store_appends_total)

# ---------------------------------------------------------------------------
# 3. Drive real operations over the real socket.
# ---------------------------------------------------------------------------
echo
echo "-- 3. drive real tier-service operations --"
EXEC="gate260-$$"
run() { python3 "$TIERCTL" "$TIER" "$@" 2>&1; }

h=$(run health);            info "health           -> $h"
case "$h" in ok\ tier-service\ v*) ok "health answered" ;; *) bad "health answered '$h'" ;; esac

a=$(run append "$EXEC" '{"marker":"GATE260"}');  info "append           -> $a"
case "$a" in *appended*) ok "append accepted" ;; *) bad "append answered '$a'" ;; esac

ai=$(run append "" '{"x":1}');                   info "append(empty id) -> $ai"
case "$ai" in invalid*|unavailable*) ok "malformed append refused ($(echo "$ai" | cut -d' ' -f1))" ;; *) bad "malformed append answered '$ai'" ;; esac

rh=$(run read "$EXEC");     info "read(hit)        -> $(echo "$rh" | cut -c1-90)"
case "$rh" in *GATE260*) ok "read returned the appended record" ;; *) bad "read(hit) answered '$rh'" ;; esac

rm_=$(run read "no-such-execution-$$"); info "read(miss)       -> $(echo "$rm_" | cut -c1-90)"
case "$rm_" in *GATE260*) bad "read(miss) returned another execution's data" ;; *) ok "read(miss) returned no records" ;; esac

s=$(run scan 50);           info "scan             -> $(echo "$s" | cut -c1-90)"
u=$(run raw '{"op":"nonsense"}'); info "unsupported      -> $u"
case "$u" in unsupported*) ok "unknown op answered, not dropped" ;; *) bad "unsupported answered '$u'" ;; esac

bf=$(run badframe);         info "badframe         -> $bf"
eq "over-long frame closed the connection" "$bf" "closed"

sleep 2
snapshot || { echo "ABORT: /metrics unreachable after driving traffic"; exit 2; }

# ---------------------------------------------------------------------------
# 4. The counters moved, on the right labels.
# ---------------------------------------------------------------------------
echo
echo "-- 4. counters moved on the right labels --"
delta() { echo $(( $(ops "$1" "$2") - $3 )); }

eq "health/ok +1"                  "$(delta health ok "$B_HEALTH")" "1"
eq "append/ok +1"                  "$(delta append ok "$B_APPEND_OK")" "1"
eq "read_execution/hit +1"         "$(delta read_execution hit "$B_HIT")" "1"
eq "read_execution/miss +1"        "$(delta read_execution miss "$B_MISS")" "1"
eq "scan/hit +1"                   "$(delta scan hit "$B_SCAN_HIT")" "1"
eq "unsupported/unsupported +1"    "$(delta unsupported unsupported "$B_UNSUP")" "1"
eq "conn/protocol_error +1"        "$(delta conn protocol_error "$B_PROTO")" "1"
# The malformed append lands on `invalid` when a store is configured. Reported
# rather than asserted equal to 1, because with no store it is `unavailable` —
# and the gate should not pretend to know which one the deployment chose.
info "append/invalid delta: $(delta append invalid "$B_APPEND_INV") (0 is correct only if no store is configured)"
# Seven connections were opened above; assert it grew, not the exact count, so
# the check does not fight the writer's own platform traffic.
ad=$(delta conn accepted "$B_ACCEPTED")
if [ "$ad" -ge 7 ] 2>/dev/null; then ok "conn/accepted +$ad (≥7 connections driven)"; else bad "conn/accepted +$ad, want ≥7"; fi

# ---------------------------------------------------------------------------
# 5. The histogram moved with the counter, and is internally consistent.
#
# The counter and the histogram are incremented by ONE function so they cannot
# drift — this asserts that property from the outside rather than trusting it.
# ---------------------------------------------------------------------------
echo
echo "-- 5. latency histogram --"
eq "health count +1"          "$(( $(hcount health) - B_H_HEALTH ))" "1"
eq "append count +2"          "$(( $(hcount append) - B_H_APPEND ))" "2"
eq "read_execution count +2"  "$(( $(hcount read_execution) - B_H_READ ))" "2"
for op in health append read_execution scan; do
  c=$(hcount "$op"); i=$(hinf "$op"); s=$(hsum "$op")
  eq "+Inf bucket == count for $op" "$i" "$c"
  # A histogram whose sum is 0 while its count is not is a recorder that fires
  # with a hardcoded 0.0 — it looks alive and measures nothing.
  if [ "$c" -gt 0 ] 2>/dev/null; then
    awk -v s="$s" 'BEGIN { exit !(s > 0) }' \
      && ok "$op sum > 0 ($s)" \
      || bad "$op has count=$c but sum=$s — the duration is not being measured"
  fi
done

# ---------------------------------------------------------------------------
# 6. Store state — observable without reading the tier.
# ---------------------------------------------------------------------------
echo
echo "-- 6. durable store state --"
ap=$(metric noetl_ehdb_tier_service_store_appends_total)
by=$(metric noetl_ehdb_tier_service_store_bytes)
sq=$(metric noetl_ehdb_tier_service_store_sequence)
eq "store_appends_total +1" "$(( ap - B_APPENDS ))" "1"
if [ "$by" -gt 0 ] 2>/dev/null; then ok "store_bytes > 0 ($by)"; else bad "store_bytes is $by after a successful append"; fi
if [ "$sq" -gt 0 ] 2>/dev/null; then ok "store_sequence > 0 ($sq)"; else bad "store_sequence is $sq after a successful append"; fi

# ---------------------------------------------------------------------------
# 7. Re-check the harness. A transport that died mid-run would have turned
#    every delta above into a misleading number.
# ---------------------------------------------------------------------------
echo
echo "-- 7. harness still healthy --"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$METRICS")
eq "/metrics still answers" "$code" "200"

echo
echo "=== arm $ARM: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
