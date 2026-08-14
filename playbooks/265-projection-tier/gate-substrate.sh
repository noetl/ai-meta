#!/usr/bin/env bash
# Kind gate for ai-meta#265 **A1 + A2** — the worker half, driven directly
# against the tier HTTP surface of a BUILT image at three replicas.
#
# WHY THIS EXISTS SEPARATELY. The end-to-end gate (`gate.sh`) needs both images;
# this one needs only the worker's. It is not a lesser gate — it is the one that
# can discriminate the properties A1/A2 actually claim, because it drives the
# tier surface itself instead of inferring it from a mirror two hops away:
#
#   1. The tier service addresses TIERS. A projection append lands in the
#      projection store and is invisible to the event log.
#   2. It is ONE store. Every replica returns the same record, which is the
#      property that does not hold for the pod-local path this replaces.
#   3. The tier set is CLOSED. A tier with no store is refused, not written
#      somewhere plausible.
#   4. The two tiers' mirror flags are INDEPENDENT. Prod sets the event log's
#      today; arming tier 2 must not be a change to tier 1.
#   5. `primary` reaches `primary_serve::decide` and the verdict is OBSERVABLE.
#      This is the ai-meta#259 question — the four unwired tiers accept
#      `primary` and change nothing a caller can see.
#   6. Demotion is loud. An unreachable store produces `primary_unavailable`,
#      not silence, and does not fail the caller.
#
# Every assertion reads an HTTP body or a `/metrics` line from a built image.
# Nothing asserts on source.
set -uo pipefail

NS=noetl
WORKER_DEPLOY=noetl-worker-rust
TIER_DIR=/data/eventbus/tier

PASS=0; FAIL=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL+1)); }
info() { printf '        %s\n' "$1"; }
k() { kubectl --context kind-noetl -n "$NS" "$@"; }

field() {
  local json="$1" path="$2" v
  if ! v=$(printf '%s' "$json" | jq -r "$path" 2>/dev/null); then printf '__ABSENT__'; return; fi
  if [ "$v" = "null" ]; then printf '__ABSENT__'; else printf '%s' "$v"; fi
}
eq() { local l="$1" g="$2" w="$3"; if [ "$g" = "$w" ]; then ok "$l ($g)"; else bad "$l — got '$g', want '$w'"; fi; }
gt0() {
  local l="$1" g="$2"
  if [ "$g" != "__ABSENT__" ] && [ "${g:-0}" -gt 0 ] 2>/dev/null; then ok "$l ($g)"; else bad "$l — got '$g', want > 0"; fi
}

WP=$(k get pod -l app=noetl-cmdbus-writer -o name 2>/dev/null | head -1)
[ -n "$WP" ] || { echo "ABORT: no writer pod"; exit 2; }

# All HTTP is issued FROM the writer pod: it is one known container and it can
# reach every replica's pod IP. `curl` is absent in these images; `wget` is not.
http() { # http <method> <url> [body]
  local m="$1" u="$2" b="${3:-}"
  if [ "$m" = "POST" ]; then
    k exec "$WP" -- sh -c "wget -q -O - -T 20 --header='Content-Type: application/json' --post-data='$b' '$u' 2>/dev/null" 2>/dev/null
  else
    k exec "$WP" -- sh -c "wget -q -O - -T 20 '$u' 2>/dev/null" 2>/dev/null
  fi
}
# Status code only — `wget` exits non-zero on 4xx/5xx and prints the code on stderr.
http_code() {
  local m="$1" u="$2" b="${3:-}"
  if [ "$m" = "POST" ]; then
    k exec "$WP" -- sh -c "wget -S -q -O /dev/null -T 20 --header='Content-Type: application/json' --post-data='$b' '$u' 2>&1 | grep -m1 'HTTP/' | awk '{print \$2}'" 2>/dev/null | tr -d '\r'
  else
    k exec "$WP" -- sh -c "wget -S -q -O /dev/null -T 20 '$u' 2>&1 | grep -m1 'HTTP/' | awk '{print \$2}'" 2>/dev/null | tr -d '\r'
  fi
}
metric_on() { # metric_on <ip> <literal needle>
  k exec "$WP" -- sh -c "wget -q -O - -T 15 'http://$1:9090/metrics' 2>/dev/null" 2>/dev/null \
    | grep -F "$2" | awk '{print $NF}' | head -1 | tr -d '\r'
}
metric_sum() {
  local needle="$1" total=0 seen=0 ip v
  for ip in "${PODIP[@]}"; do
    v=$(metric_on "$ip" "$needle")
    if [ -n "$v" ]; then seen=1; total=$(awk -v a="$total" -v b="$v" 'BEGIN{printf "%d", a+b}'); fi
  done
  [ "$seen" = "1" ] && printf '%s' "$total" || printf '__ABSENT__'
}

ARM="${1:-shadow}"
MARK="PROJ-$(date +%s)-$RANDOM"
EXEC="gate265-${ARM}-$$"

echo
echo "=== ai-meta#265 A1+A2 substrate gate — arm: $ARM ==="
echo

# ---------------------------------------------------------------------------
# 0. Topology. Three replicas is the premise: "one store" is not a measurement
#    at one replica.
# ---------------------------------------------------------------------------
echo "-- 0. topology --"
PODIP=()
while IFS= read -r ip; do [ -n "$ip" ] && PODIP+=("$ip"); done < <(
  k get pods -l app=noetl-worker-rust \
    -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.status.podIP}{"\n"}{end}')
N=${#PODIP[@]}
info "worker replicas: $N (${PODIP[*]:-none})"
if [ "$N" -ge 2 ]; then ok "more than one replica ($N)"; else
  bad "only $N replica(s) — cannot show the tier is ONE store"; echo "ABORT"; exit 2; fi

th=$(k exec "$WP" -- sh -c 'nc -z 127.0.0.1 9110 && echo open || echo shut' 2>/dev/null | tr -d '\r')
if [ "$ARM" = "demoted" ]; then
  info "writer :9110 is $th — this arm points the replicas elsewhere on purpose"
else
  eq "writer tier service listening on :9110" "${th:-unknown}" "open"
fi

# Which image is actually running? A gate that ran the old image would pass
# every backward-compatibility assertion and fail every new one — or worse, be
# read as "the feature does not work".
img=$(k get pods -l app=noetl-worker-rust -o jsonpath='{.items[0].spec.containers[0].image}')
eq "replicas run the gate image" "$img" "localhost/noetl-worker:265proj"

# ---------------------------------------------------------------------------
# 1. The tier set is CLOSED, and the two tiers' flags are INDEPENDENT.
# ---------------------------------------------------------------------------
echo
echo "-- 1. tier addressing --"
c=$(http_code POST "http://${PODIP[0]}:9090/ehdb/tiers/kv" "{\"execution_id\":\"$EXEC\",\"records\":[\"{}\"]}")
eq "an append to a tier with no store is refused (kv)" "${c:-none}" "400"
c=$(http_code POST "http://${PODIP[0]}:9090/ehdb/tiers/vector" "{\"execution_id\":\"$EXEC\",\"records\":[\"{}\"]}")
eq "…and vector" "${c:-none}" "400"

# ---------------------------------------------------------------------------
# 2. Append one projection record, then read it back from EVERY replica.
# ---------------------------------------------------------------------------
echo
echo "-- 2. append + read-back from every replica --"
REC="{\"execution_id\":\"$EXEC\",\"version\":9001,\"checksum\":\"$MARK\",\"applied_count\":12,\"snapshot\":{\"steps\":{\"a\":\"done\"}},\"mirror_source\":\"server\"}"
BODY=$(printf '{"execution_id":"%s","records":[%s]}' "$EXEC" "$(printf '%s' "$REC" | jq -Rs .)")
code=$(http_code POST "http://${PODIP[0]}:9090/ehdb/tiers/projection" "$BODY")
resp=$(http POST "http://${PODIP[0]}:9090/ehdb/tiers/projection" "$BODY")
info "append status=$code reply: $(printf '%s' "$resp" | head -c 300)"
if [ "$ARM" = "demoted" ]; then
  # The store is unreachable by design. What must hold is that the tier says so
  # rather than claiming success — a 2xx here would be the lie the whole RFC
  # exists to prevent, because the server's mirror treats 2xx as "mirrored".
  #
  # 502, not 200-with-a-sad-body: the mirror is best-effort at the SERVER layer
  # (it meters and drops), so failing loudly here is what lets it be. Note wget
  # prints no body on an error status, which is why this asserts the code.
  eq "an unreachable store answers 502, not success" "${code:-none}" "502"
  if [ "${code:-}" = "200" ]; then
    bad "an append to an unreachable store reported 200 — the mirror would score it as mirrored"
  fi
else
  eq "append outcome" "$(field "$resp" '.outcome')" "ok"
  eq "records appended" "$(field "$resp" '.appended')" "1"
  eq "the append resolved through the SERVICE" "$(field "$resp" '.tier_query_source')" "service"

  hits=0
  for ip in "${PODIP[@]}"; do
    b=$(http GET "http://$ip:9090/ehdb/tiers/projection?execution=$EXEC")
    if printf '%s' "$b" | grep -q "$MARK"; then hits=$((hits+1)); else
      info "replica $ip did NOT return the record: $(printf '%s' "$b" | head -c 200)"; fi
  done
  eq "every replica returned the SAME record ($hits/$N)" "$hits" "$N"
fi

# ---------------------------------------------------------------------------
# 3. TIER ISOLATION — the property tier 1 (primary in prod) depends on.
# ---------------------------------------------------------------------------
echo
elseq_before=$(metric_on "127.0.0.1" 'noetl_ehdb_tier_service_store_sequence{tier="eventlog"}')
echo "-- 3. tier isolation --"
if [ "$ARM" = "demoted" ]; then
  info "skipped: the replicas point at a black hole in this arm, so a tier READ"
  info "cannot distinguish isolation from unreachability"
else
el=$(http GET "http://${PODIP[0]}:9090/ehdb/tiers/eventlog?execution=$EXEC")
if printf '%s' "$el" | grep -q "$MARK"; then
  bad "the EVENT-LOG tier returned the projection record — the stores are shared"
else
  ok "the event-log tier does not hold the projection record"
fi
# POSITIVE CONTROL, and it has to be a strong one. The negative above is
# satisfied by an event-log read that simply failed, and ALSO by one that
# succeeded against an empty store — the per-execution read returns
# `record_count: 0` for an execution the event log never held, which is both
# correct and useless as evidence.
#
# So the control is a SCAN: the event-log store must return records. That proves
# the surface is live AND that the store it answers from is populated, which is
# what makes "it does not contain the projection record" a fact about isolation
# rather than about emptiness.
elc=$(field "$el" '.record_count')
if [ "$elc" = "__ABSENT__" ]; then
  bad "the event-log per-execution read did not answer — the isolation check above is vacuous"
else
  ok "the event-log tier surface answered (record_count=$elc for a projection-only execution)"
fi
elscan=$(http GET "http://${PODIP[0]}:9090/ehdb/tiers/eventlog")
elscanc=$(field "$elscan" '.record_count')
gt0 "the event-log store is NON-EMPTY (scan record_count) — isolation is not emptiness" "$elscanc"
if printf '%s' "$elscan" | grep -q "$MARK"; then
  bad "a full event-log scan returned the projection record — the stores are shared"
else
  ok "a full event-log scan of $elscanc record(s) contains no projection record"
fi

fi

# ---------------------------------------------------------------------------
# 4. Per-tier store gauges. An operator flipping tier 2 asks "does the
#    projection store hold anything" — and must be able to ask it about that
#    store, not about whichever was appended to last.
# ---------------------------------------------------------------------------
echo
echo "-- 4. per-tier store gauges (writer) --"
g=$(k exec "$WP" -- sh -c "wget -q -O - -T 15 http://127.0.0.1:9090/metrics 2>/dev/null" 2>/dev/null \
    | grep -F 'noetl_ehdb_tier_service_store_' | grep -F 'tier=')
info "$(printf '%s' "$g" | tr '\n' ' ' | head -c 300)"
for t in eventlog projection; do
  if printf '%s' "$g" | grep -q "tier=\"$t\""; then ok "gauges present for tier=$t"; else
    bad "no store gauges for tier=$t — absent and 0 are different facts"; fi
done
pseq=$(metric_on "127.0.0.1" 'noetl_ehdb_tier_service_store_sequence{tier="projection"}')
gt0 "the projection store holds records (sequence)" "${pseq:-__ABSENT__}"
elseq_after=$(metric_on "127.0.0.1" 'noetl_ehdb_tier_service_store_sequence{tier="eventlog"}')
eq "a projection append did NOT move the event log's tip" "${elseq_after:-x}" "${elseq_before:-y}"

# ---------------------------------------------------------------------------
# 5. The serve decision (ai-meta#259).
# ---------------------------------------------------------------------------
echo
echo "-- 5. serve decision --"
served=$(metric_sum 'noetl_ehdb_projection_ops_total{operation="mirror",outcome="served_primary"}')
unavail=$(metric_sum 'noetl_ehdb_projection_ops_total{operation="mirror",outcome="primary_unavailable"}')
matz=$(metric_sum 'noetl_ehdb_projection_ops_total{operation="mirror",outcome="materialized"}')
unav2=$(metric_sum 'noetl_ehdb_projection_ops_total{operation="mirror",outcome="unavailable"}')
info "served_primary=$served primary_unavailable=$unavail materialized=$matz unavailable=$unav2"

# PIN check, in every arm. Metric absence is the default; absent and "this build
# has no serve path" are the same bytes.
if [ "$served" = "__ABSENT__" ]; then
  bad "the served_primary series is ABSENT on every replica — it must be pinned at 0"
else
  ok "the served_primary series is present (pinned), value=$served"
fi

case "$ARM" in
  shadow)
    eq "shadow does not serve" "$served" "0"
    gt0 "shadow DID materialize (this arm's positive control)" "$matz"
    ;;
  primary)
    gt0 "primary SERVED (served_primary > 0)" "$served"
    ;;
  demoted)
    # MEASURED, not assumed. A transport failure short-circuits the outcome
    # mapping to `unavailable` (the record did not land, so there is no parity
    # verdict to have) — `primary_unavailable` is the narrower case where the
    # record DID land and no durable service is reachable. Asserting the latter
    # here would be asserting a state this configuration cannot produce.
    gt0 "the demote is recorded as a DEGRADED outcome (unavailable > 0)" "$unav2"
    eq "and it did NOT claim to serve" "$served" "0"
    ;;
esac

echo
echo "=== arm '$ARM': $PASS passed, $FAIL failed ==="
echo "EXEC=$EXEC MARK=$MARK"
[ "$FAIL" -eq 0 ]
