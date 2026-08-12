#!/usr/bin/env bash
# Kind gate for noetl/ai-meta#258 — does the event-log tier hold the FULL
# authoritative event set?
#
# The claim under test is narrow and checkable: after moving the mirror to the
# server's write chokepoint, one execution's tier record set equals its
# authoritative event set — same count, same membership, same relative order,
# same identifying payload — where before it held 6 of 13.
#
# Read the gate design notes before changing an arm:
#
#   * every assertion is behaviour-level, against the HTTP surface of built
#     images in kind. Nothing here asserts on server source.
#   * a failed fetch is a FAILURE, never a zero that reads as a pass. Every
#     `jq` read goes through `field()`, which fails loud on absent.
#   * the flag-off arm must reproduce the pre-change numbers, or the gate
#     cannot discriminate and its pass means nothing.
#   * the controls that ship inside the binary are checked alongside every
#     verdict: `divergence == 0` is evidence only when the comparator has just
#     demonstrated, in that same process, that it can still detect divergence.
#
# Usage: gate.sh <arm>
#   arm ∈ { server, worker, mutated }
set -uo pipefail

SERVER="${SERVER:-http://localhost:8082}"
PROBE="${PROBE:-tests/gate_fast_probe}"
ARM="${1:-server}"

PASS=0
FAIL=0

ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL+1)); }
info() { printf '        %s\n' "$1"; }

# Read one field, or fail the gate. Never emits a default: a missing field and a
# field that is legitimately 0 must not produce the same string, because the
# whole point of this gate is a set of numbers that are supposed to be equal.
# NOT `jq -e`. `-e` sets a non-zero exit status when the LAST OUTPUT VALUE is
# `false` or `null`, so a field that is legitimately `false` — `holds` on a
# divergent verdict, which is the single most important value this gate reads —
# is indistinguishable from a field that is absent. This harness reported
# `holds: __ABSENT__` on the mutation arm for exactly that reason while the
# server's body plainly said `"holds":false`.
#
# Without `-e`, `jq -r` prints the string `null` for a missing path and exits 0,
# and a syntax error still exits non-zero. That separates the three cases
# correctly: absent, false, and broken query.
field() {
  local json="$1" path="$2" v
  if ! v=$(printf '%s' "$json" | jq -r "$path" 2>/dev/null); then
    printf '__ABSENT__'
    return
  fi
  if [ "$v" = "null" ]; then printf '__ABSENT__'; else printf '%s' "$v"; fi
}

eq() {
  local label="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then ok "$label ($got)"; else bad "$label — got '$got', want '$want'"; fi
}

echo
echo "=== ai-meta#258 gate — arm: $ARM ==="
echo

# ---------------------------------------------------------------------------
# 0. Positive control on the harness itself.
#
# Every check below reads a number out of an HTTP body. If the server were
# unreachable, an unguarded harness would read empty strings and could report
# whatever the comparison operator does with them. Prove the transport works
# before trusting anything it carries.
# ---------------------------------------------------------------------------
echo "-- 0. harness reachability --"
health=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$SERVER/api/health")
eq "server answers /api/health" "$health" "200"
if [ "$health" != "200" ]; then
  echo; echo "ABORT: server unreachable; every later zero would be an artefact."; exit 2
fi

# ---------------------------------------------------------------------------
# 1. The in-binary controls.
#
# Checked FIRST and checked again at the end. A comparator that cannot detect
# divergence reports zero divergence — and so does a healthy platform. The
# self-test drives one clean fixture and one deliberately corrupted fixture per
# divergence kind through the same `compare_cross_store` the live path uses.
# `unexpected == 0` alone is not enough: it is also 0 when nothing ran, so
# `expected > 0` is the half that makes the zero readable.
# ---------------------------------------------------------------------------
echo
echo "-- 1. in-binary controls (before) --"
st=$(curl -s --max-time 15 "$SERVER/api/ehdb/parity/self-test")
st_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$SERVER/api/ehdb/parity/self-test")
# The body carries `controls_ok` plus the per-control array; the two counts are
# derived from it rather than read from a summary field that does not exist.
controls_ok=$(field "$st" '.controls_ok')
expected=$(field "$st" '[.controls[]? | select(.expected == true)] | length')
unexpected=$(field "$st" '[.controls[]? | select(.expected == false)] | length')
eq "self-test HTTP" "$st_code" "200"
eq "controls_ok" "$controls_ok" "true"
eq "controls unexpected" "$unexpected" "0"
if [ "$expected" = "__ABSENT__" ] || [ "$expected" -le 0 ] 2>/dev/null; then
  bad "controls expected > 0 — got '$expected' (a suite that never ran proves nothing)"
else
  ok "controls expected > 0 ($expected)"
fi

# ---------------------------------------------------------------------------
# 2. Run one execution and let it settle.
# ---------------------------------------------------------------------------
echo
echo "-- 2. drive one execution of $PROBE --"
run=$(curl -s --max-time 60 -X POST "$SERVER/api/execute" \
        -H 'content-type: application/json' \
        -d "{\"path\":\"$PROBE\"}")
exec_id=$(field "$run" '.execution_id')
if [ "$exec_id" = "__ABSENT__" ] || [ -z "$exec_id" ]; then
  bad "execute returned no execution_id"
  info "body: $(printf '%s' "$run" | head -c 400)"
  echo; echo "ABORT: nothing to compare."; exit 2
fi
ok "execution_id=$exec_id"

# Settle on the quantity this gate actually compares — the authoritative event
# count — rather than on an execution-status field.
#
# Two reasons. `noetl.execution.status` is a frozen Python-era column that no
# Rust path writes (ai-meta#235), so a status poll can report a shape that has
# nothing to do with this run. And even a correct terminal signal would be the
# wrong trigger: what must be stable before comparing is the event set, so
# waiting for it directly removes a whole class of "compared mid-flight" flake.
prev=-1; stable=0
for _ in $(seq 1 60); do
  sleep 2
  n=$(curl -s --max-time 15 "$SERVER/api/ehdb/parity/executions/$exec_id" \
      | jq -r '.report.authoritative_count // 0' 2>/dev/null)
  n=${n:-0}
  if [ "$n" -gt 0 ] && [ "$n" = "$prev" ]; then
    stable=$((stable+1))
    [ "$stable" -ge 2 ] && break
  else
    stable=0
  fi
  prev=$n
done
info "authoritative event count settled at $prev"

# ---------------------------------------------------------------------------
# 3. The verdict.
# ---------------------------------------------------------------------------
echo
echo "-- 3. cross-store verdict --"
rep=$(curl -s --max-time 30 "$SERVER/api/ehdb/parity/executions/$exec_id")
printf '%s\n' "$rep" | jq '.' 2>/dev/null | head -40

outcome=$(field "$rep" '.outcome')
auth=$(field "$rep" '.report.authoritative_count')
expct=$(field "$rep" '.report.authoritative_expected')
unmir=$(field "$rep" '.report.unmirrored_by_design')
ehdb=$(field "$rep" '.report.ehdb_count')
matched=$(field "$rep" '.report.matched')
holds=$(field "$rep" '.report.holds')
ndiv=$(field "$rep" '.report.divergences | length')

case "$ARM" in
  server)
    # The closure. Every authoritative event is expected, present, and matched.
    eq "outcome" "$outcome" "match"
    eq "unmirrored_by_design" "$unmir" "0"
    eq "authoritative_expected == authoritative_total" "$expct" "$auth"
    eq "tier count == authoritative total" "$ehdb" "$auth"
    eq "matched == authoritative total" "$matched" "$auth"
    eq "divergences" "$ndiv" "0"
    eq "holds" "$holds" "true"
    if [ "$auth" != "__ABSENT__" ] && [ "${auth:-0}" -ge 10 ] 2>/dev/null; then
      ok "authoritative total is a real execution ($auth events)"
    else
      bad "authoritative total $auth is too small to be the probe — a 1==1 match is vacuous"
    fi
    ;;
  worker)
    # The discriminating half. If this arm ALSO showed a full-set match, the
    # flag would not be what produced the result in the `server` arm.
    eq "outcome" "$outcome" "match"
    eq "holds" "$holds" "true"
    if [ "$unmir" != "__ABSENT__" ] && [ "${unmir:-0}" -gt 0 ] 2>/dev/null; then
      ok "unmirrored_by_design > 0 — the pre-change scoping is reproduced ($unmir)"
    else
      bad "unmirrored_by_design is $unmir with the flag off; the arms do not differ"
    fi
    if [ "$ehdb" != "__ABSENT__" ] && [ "$ehdb" -lt "$auth" ] 2>/dev/null; then
      ok "tier holds a strict subset ($ehdb of $auth)"
    else
      bad "tier holds $ehdb of $auth with the flag off — expected a strict subset"
    fi
    ;;
  mutated)
    # A server-authored event is being dropped on purpose. The comparator must
    # say so, and must say it with the RIGHT kind: `missing_event`, not a bare
    # count difference, and not `missing_execution`.
    kinds=$(printf '%s' "$rep" | jq -r '[.report.divergences[]?.kind] | unique | join(",")' 2>/dev/null)
    info "divergence kinds: ${kinds:-<none>}"
    if printf '%s' "$kinds" | grep -q 'missing_event'; then
      ok "mutation detected as missing_event"
    else
      bad "mutation NOT reported as missing_event (kinds: ${kinds:-<none>})"
    fi
    eq "holds" "$holds" "false"
    ;;
esac

# ---------------------------------------------------------------------------
# 4. The mirror's own signal.
#
# The comparator says the two stores agree. This says the server actually did
# the mirroring — without it, "agree" would also be the verdict if some other
# producer had filled the tier.
# ---------------------------------------------------------------------------
echo
echo "-- 4. server-side mirror metric --"
met=$(curl -s --max-time 15 "$SERVER/metrics")
for lbl in mirrored unconfigured unavailable degraded; do
  line=$(printf '%s\n' "$met" | grep "^noetl_ehdb_eventlog_mirror_total{outcome=\"$lbl\"}" | head -1)
  if [ -n "$line" ]; then ok "pinned series present: $line"; else bad "series ABSENT for outcome=$lbl (a pruned family is indistinguishable from a mirror that is off)"; fi
done
mir=$(printf '%s\n' "$met" | grep '^noetl_ehdb_eventlog_mirror_total{outcome="mirrored"}' | awk '{print $2}')
case "$ARM" in
  server|mutated)
    if [ "${mir%%.*}" -gt 0 ] 2>/dev/null; then ok "server mirrored events (mirrored=$mir)"; else bad "server mirrored nothing (mirrored=$mir) — the tier was filled by something else"; fi
    ;;
  worker)
    if [ "${mir%%.*}" -eq 0 ] 2>/dev/null; then ok "server mirrored nothing with the flag off (mirrored=$mir)"; else bad "server mirrored $mir events with the flag off"; fi
    ;;
esac

# ---------------------------------------------------------------------------
# 5. Controls again, AFTER the live comparison.
#
# Arm F of the comparator's own gate found a broken membership check this way:
# a refactor that stopped detecting a deleted record left the live verdict
# looking clean and flipped the controls to unexpected=2. Re-reading them after
# the fact is what makes the clean verdict above load-bearing.
# ---------------------------------------------------------------------------
echo
echo "-- 5. in-binary controls (after) --"
st2=$(curl -s --max-time 15 "$SERVER/api/ehdb/parity/self-test")
eq "controls_ok" "$(field "$st2" '.controls_ok')" "true"
eq "controls unexpected" "$(field "$st2" '[.controls[]? | select(.expected == false)] | length')" "0"

echo
echo "=== arm $ARM: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
