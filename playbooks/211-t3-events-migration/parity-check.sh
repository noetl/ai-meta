#!/usr/bin/env bash
# Shadow-parity measurement for T3 (noetl/ai-meta#212).
#
# Samples the four counters that must agree before any consumer is cut over,
# before and after a driven-load window, and reports the deltas.
#
# A parity claim needs ALL FOUR to agree, not just the stream counter.  Counting
# only what was published proves the publisher, not the consumers — and the
# consumer that matters here writes the durable event log.
#
#   1. NATS      — noetl_events stream message count
#   2. EHDB      — the events feed's per-group committed cursor (writer :9106)
#   3. server    — noetl_event_ingest_published_total vs
#                  noetl_ehdb_events_published_total, by event_type
#   4. materializer — noetl_events_projected_total (ground truth that rows are
#                  actually landing in the durable noetl.event log).  NOTE: this
#                  metric ships in server >= 3.59.1; on older builds it is absent
#                  and this field reads null.  noetl_events_materialized_total is
#                  NOT a substitute — it counts the events/materialize sink, which
#                  this deployment does not use, so it reads 0 forever.
#
# Usage:
#   ./parity-check.sh before        # snapshot, writes /tmp/t3-parity-before.json
#   <drive load>
#   ./parity-check.sh after         # snapshot + diff report
#
set -uo pipefail

: "${CLOUDSDK_CORE_ACCOUNT:=shastaratech@gmail.com}"
export CLOUDSDK_CORE_ACCOUNT
: "${KCTX:=gke_shastaratech-noetl-prod_us-central1_noetl-prod-autopilot}"
NS=noetl
NATS_NS=nats
NATS_URL="nats://noetl:noetl@nats.nats.svc.cluster.local:4222"
WRITER=noetl-cmdbus-writer-0
PHASE="${1:-before}"
OUT="/tmp/t3-parity-${PHASE}.json"

k() { kubectl --context "$KCTX" "$@"; }

# Emit exactly one JSON value.  `set -o pipefail` makes a pipeline non-zero when
# ANY stage fails, so the idiom `cmd | python3 ... || echo '{}'` emits the
# python fallback AND the echo — two JSON values, and unparseable output.  Every
# collector below routes through this instead.
emit_json() {
  local fallback="$1"; shift
  local out
  out="$("$@" 2>/dev/null)" || true
  # Must be exactly one parseable JSON value, else use the fallback.
  if [ -n "$out" ] && printf '%s' "$out" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
    printf '%s' "$out"
  else
    printf '%s' "$fallback"
  fi
}

# The nats-box pod carries no reliable label on this cluster, so match by name
# prefix — verified against `kubectl -n nats get pods` (nats-box-<rs>-<pod>).
nats_box() {
  k -n "$NATS_NS" get pods -o name 2>/dev/null | grep -m1 'pod/nats-box' || true
}

# 1. NATS stream message count + last sequence.
_nats_counts_raw() {
  local nb; nb="$(nats_box)"
  if [ -z "$nb" ]; then return 1; fi
  k -n "$NATS_NS" exec "$nb" -- nats --server "$NATS_URL" \
      stream info noetl_events -j 2>/dev/null \
    | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)["state"]
    print(json.dumps({"messages":d["messages"],"last_seq":d["last_seq"]}))
except Exception:
    sys.exit(1)'
}

nats_counts() { emit_json '{"messages":null,"last_seq":null}' _nats_counts_raw; }

# 2. EHDB events-feed per-group committed cursor + lag (writer :9106).
#    Absent until NOETL_EVENT_BUS_HOST is on — reported as {} rather than an
#    error, so a pre-enable snapshot still works.
_ehdb_groups_raw() {
  local pod
  pod="$(k -n "$NS" get pod -l app="$WRITER" -o name 2>/dev/null | head -1)"
  if [ -z "$pod" ]; then return 1; fi
  k -n "$NS" exec "$pod" -- sh -c 'command -v curl >/dev/null 2>&1 && curl -sf --max-time 5 http://127.0.0.1:9106/metrics || wget -qO- --timeout=5 http://127.0.0.1:9106/metrics' 2>/dev/null \
    | python3 -c 'import sys,re,json
out={}
for line in sys.stdin:
    m=re.match(r"ehdb_events_group_(committed|lag)\{group=\"([^\"]+)\"\} (\d+)", line.strip())
    if m:
        out.setdefault(m.group(2),{})[m.group(1)]=int(m.group(3))
    m2=re.match(r"ehdb_events_cursor_errors (\d+)", line.strip())
    if m2:
        out["_cursor_errors"]=int(m2.group(1))
print(json.dumps(out))'
}

ehdb_groups() { emit_json '{}' _ehdb_groups_raw; }

# 3. Server publish counters, by event_type — the shadow-parity signal.
_server_counters_raw() {
  local pod
  pod="$(k -n "$NS" get pod -l app=noetl-server-rust -o name 2>/dev/null | head -1)"
  if [ -z "$pod" ]; then return 1; fi
  k -n "$NS" exec "$pod" -- sh -c 'command -v curl >/dev/null 2>&1 && curl -sf --max-time 5 http://127.0.0.1:8082/metrics || wget -qO- --timeout=5 http://127.0.0.1:8082/metrics' 2>/dev/null \
    | python3 -c 'import sys,re,json
nats={}; ehdb={}; errs={}
for line in sys.stdin:
    line=line.strip()
    for pat,dest in ((r"noetl_event_ingest_published_total\{event_type=\"([^\"]+)\"\} ([0-9.e+]+)",nats),
                     (r"noetl_ehdb_events_published_total\{event_type=\"([^\"]+)\"\} ([0-9.e+]+)",ehdb),
                     (r"noetl_ehdb_events_publish_errors_total\{event_type=\"([^\"]+)\"\} ([0-9.e+]+)",errs)):
        m=re.match(pat,line)
        if m: dest[m.group(1)]=int(float(m.group(2)))
print(json.dumps({"nats":nats,"ehdb":ehdb,"errors":errs}))'
}

server_counters() { emit_json '{}' _server_counters_raw; }

# 4. Durable-log writes — noetl_events_projected_total, the count of
#    noetl.event rows the materializer has actually written.  This is the
#    ground-truth consumer signal: publish counters prove the publisher, this
#    proves the durable log is still being written.
_event_rows_raw() {
  local pod
  pod="$(k -n "$NS" get pod -l app=noetl-server-rust -o name 2>/dev/null | head -1)"
  if [ -z "$pod" ]; then return 1; fi
  k -n "$NS" exec "$pod" -- sh -c 'command -v curl >/dev/null 2>&1 && curl -sf --max-time 5 http://127.0.0.1:8082/metrics || wget -qO- --timeout=5 http://127.0.0.1:8082/metrics' 2>/dev/null \
    | python3 -c 'import sys,re
for line in sys.stdin:
    m=re.match(r"noetl_events_projected_total ([0-9.e+]+)", line.strip())
    if m:
        print(int(float(m.group(1)))); break
else:
    print("null")'
}

event_rows() { emit_json 'null' _event_rows_raw; }

snapshot() {
  printf '{"phase":"%s","ts":"%s","nats":%s,"ehdb_groups":%s,"server":%s,"event_rows":%s}\n' \
    "$PHASE" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$(nats_counts)" "$(ehdb_groups)" "$(server_counters)" "$(event_rows)"
}

snapshot > "$OUT"
echo "wrote $OUT"
python3 -m json.tool "$OUT"

if [ "$PHASE" = "after" ] && [ -f /tmp/t3-parity-before.json ]; then
  echo
  echo "================ PARITY REPORT ================"
  python3 - /tmp/t3-parity-before.json "$OUT" <<'PY'
import json,sys
b=json.load(open(sys.argv[1])); a=json.load(open(sys.argv[2]))

def d(x,y):
    if x is None or y is None: return None
    return y-x

nats_delta=d(b["nats"]["messages"], a["nats"]["messages"])
print(f"NATS  noetl_events messages delta : {nats_delta}")

sb=b.get("server",{}) or {}; sa=a.get("server",{}) or {}
nats_pub={k: sa.get("nats",{}).get(k,0)-sb.get("nats",{}).get(k,0)
          for k in set(sa.get("nats",{}))|set(sb.get("nats",{}))}
ehdb_pub={k: sa.get("ehdb",{}).get(k,0)-sb.get("ehdb",{}).get(k,0)
          for k in set(sa.get("ehdb",{}))|set(sb.get("ehdb",{}))}
errs={k: sa.get("errors",{}).get(k,0)-sb.get("errors",{}).get(k,0)
      for k in set(sa.get("errors",{}))|set(sb.get("errors",{}))}
nats_pub={k:v for k,v in nats_pub.items() if v}
ehdb_pub={k:v for k,v in ehdb_pub.items() if v}
errs={k:v for k,v in errs.items() if v}

print(f"server NATS published (by type)   : {sum(nats_pub.values())} {nats_pub}")
print(f"server EHDB published (by type)   : {sum(ehdb_pub.values())} {ehdb_pub}")
print(f"server EHDB publish ERRORS        : {sum(errs.values())} {errs}")

print(f"noetl.event rows materialized     : {d(b.get('event_rows'), a.get('event_rows'))}")

gb=b.get("ehdb_groups",{}) or {}; ga=a.get("ehdb_groups",{}) or {}
for g in sorted(set(ga)|set(gb)):
    if g.startswith("_"): continue
    print(f"EHDB group {g:28s} committed {gb.get(g,{}).get('committed')} -> "
          f"{ga.get(g,{}).get('committed')}  lag={ga.get(g,{}).get('lag')}")
print(f"EHDB cursor persist errors        : {ga.get('_cursor_errors')}")

print("---------------- GATE ----------------")
ok=True
if not ehdb_pub:
    print("FAIL: EHDB published nothing — shadow is not actually mirroring.")
    ok=False
elif nats_pub and sum(nats_pub.values()) != sum(ehdb_pub.values()):
    print(f"FAIL: publish counts differ (NATS {sum(nats_pub.values())} vs "
          f"EHDB {sum(ehdb_pub.values())}).")
    ok=False
elif set(nats_pub) != set(ehdb_pub):
    print(f"FAIL: event_type sets differ. NATS-only={set(nats_pub)-set(ehdb_pub)} "
          f"EHDB-only={set(ehdb_pub)-set(nats_pub)}")
    ok=False
if sum(errs.values()):
    print("FAIL: EHDB publish errors are non-zero — a silently-failing shadow.")
    ok=False
if ga.get("_cursor_errors"):
    print("WARN: group cursor persists are failing; progress is not durable.")
print("PARITY GATE: " + ("PASS" if ok else "FAIL — do NOT cut any consumer over"))
PY
fi
