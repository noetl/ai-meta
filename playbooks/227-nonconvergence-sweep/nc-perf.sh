#!/usr/bin/env bash
# Hot-path perf: identical load with the non-convergence sweep OFF then ON.
#
# The claim under test is that detection and termination are entirely off the
# hot path — that nothing was added to publish, append, claim, ack or dispatch.
# The sweep is a background task, so the expected result is "no difference", and
# the job of this script is to be able to SEE a difference if one existed.
#
# Two things make that possible:
#
#   * The ON arm runs with the sweep at its most expensive: a short interval, so
#     several ticks land inside the measurement window, against the cluster's
#     full accumulated backlog. Measuring an idle sweep would prove nothing.
#   * Latency is measured per-execution end to end (submit -> terminal), and
#     reported as p50/p95/p99 rather than a mean, because a background query
#     stealing a connection would show up in the tail long before the mean.
#
# Usage: ./nc-perf.sh [n_execs] [concurrency]
set -uo pipefail

CTX="${CTX:-kind-noetl}"
NS=noetl
N="${1:-120}"
CONC="${2:-12}"
SWEEP_INTERVAL=20      # deliberately aggressive for the ON arm
RUN="${RUN:-/tmp/nc227-perf-$(date +%H%M%S)}"
PORT="${PORT:-18102}"
CMD_PORT="${CMD_PORT:-19112}"
PB="fixtures/playbooks/hello_world"

[[ "$CTX" == kind-* ]] || { echo "REFUSING: CTX=$CTX is not kind" >&2; exit 1; }
mkdir -p "$RUN"
k() { kubectl --context "$CTX" -n "$NS" "$@"; }

pf() {
  kill $(jobs -p) 2>/dev/null; sleep 1
  k port-forward svc/noetl-server-rust "${PORT}":8082    >/dev/null 2>&1 &
  k port-forward svc/noetl-cmdbus-writer "${CMD_PORT}":9102 >/dev/null 2>&1 &
  sleep 6
}
trap 'kill $(jobs -p) 2>/dev/null' EXIT

metric_sum() {
  curl -s --max-time 10 "$1" 2>/dev/null \
    | awk -v m="$2" 'index($1,m)==1 {s+=$NF; f=1} END{if(f) print s; else print "NA"}'
}

arm() { # arm <label>
  local label="$1"
  pf
  echo "  warming..."
  python3 - "$PORT" "$PB" 10 5 >/dev/null 2>&1 <<'PY'
import sys,json,urllib.request,concurrent.futures as cf
port,pb,n,c=sys.argv[1],sys.argv[2],int(sys.argv[3]),int(sys.argv[4])
def go(_):
    try:
        urllib.request.urlopen(urllib.request.Request(f"http://127.0.0.1:{port}/api/execute",
            data=json.dumps({"path":pb,"payload":{}}).encode(),
            headers={"content-type":"application/json"}),timeout=60).read()
    except Exception: pass
with cf.ThreadPoolExecutor(c) as ex: list(ex.map(go,range(n)))
PY
  local pub0 app0
  pub0=$(metric_sum "http://127.0.0.1:${PORT}/metrics" 'noetl_ehdb_events_published_total')
  app0=$(metric_sum "http://127.0.0.1:${CMD_PORT}/metrics" 'ehdb_l0_appends')
  local t0=$(python3 -c 'import time;print(time.time())')

  python3 - "$PORT" "$PB" "$N" "$CONC" >"$RUN/lat-$label.txt" <<'PY'
import sys,json,time,urllib.request,concurrent.futures as cf
port,pb,n,c=sys.argv[1],sys.argv[2],int(sys.argv[3]),int(sys.argv[4])
def go(_):
    t=time.perf_counter()
    try:
        r=urllib.request.urlopen(urllib.request.Request(f"http://127.0.0.1:{port}/api/execute",
            data=json.dumps({"path":pb,"payload":{}}).encode(),
            headers={"content-type":"application/json"}),timeout=120).read()
        eid=json.loads(r).get("execution_id")
    except Exception as e:
        return None
    # end-to-end: poll to terminal
    deadline=time.time()+120
    while time.time()<deadline:
        try:
            s=json.loads(urllib.request.urlopen(
                f"http://127.0.0.1:{port}/api/executions/{eid}/status",timeout=30).read())
            if s.get("status") in ("COMPLETED","FAILED","CANCELLED"): break
        except Exception: pass
        time.sleep(0.25)
    return (time.perf_counter()-t)*1000.0
with cf.ThreadPoolExecutor(c) as ex:
    out=[v for v in ex.map(go,range(n)) if v is not None]
for v in out: print(f"{v:.1f}")
PY
  local t1=$(python3 -c 'import time;print(time.time())')
  local pub1 app1
  pub1=$(metric_sum "http://127.0.0.1:${PORT}/metrics" 'noetl_ehdb_events_published_total')
  app1=$(metric_sum "http://127.0.0.1:${CMD_PORT}/metrics" 'ehdb_l0_appends')

  python3 - "$label" "$RUN/lat-$label.txt" "$t0" "$t1" "$pub0" "$pub1" "$app0" "$app1" <<'PY' | tee -a "$RUN/perf.txt"
import sys,statistics as st
label,f,t0,t1,p0,p1,a0,a1=sys.argv[1:9]
v=sorted(float(x) for x in open(f) if x.strip())
def q(p): return v[min(len(v)-1,int(len(v)*p))]
dur=float(t1)-float(t0)
def d(x,y):
    try: return int(float(y))-int(float(x))
    except Exception: return None
dp,da=d(p0,p1),d(a0,a1)
print(f"[{label}] n={len(v)} dur={dur:.1f}s "
      f"p50={q(.50):.0f}ms p95={q(.95):.0f}ms p99={q(.99):.0f}ms mean={st.mean(v):.0f}ms")
print(f"[{label}] published_delta={dp} appends_delta={da} "
      f"publish_tput={(dp/dur if dp else 0):.1f}/s append_tput={(da/dur if da else 0):.1f}/s")
PY
}

: >"$RUN/perf.txt"

echo "== ARM A: sweep OFF (default) =="
k set env deploy/noetl-server-rust NOETL_NONCONVERGENCE_SWEEP_ENABLED=false >/dev/null
k rollout status deploy/noetl-server-rust --timeout=180s
arm off

echo
echo "== ARM B: sweep ON, interval ${SWEEP_INTERVAL}s (ticks land inside the window) =="
k set env deploy/noetl-server-rust \
    NOETL_NONCONVERGENCE_SWEEP_ENABLED=true \
    NOETL_NONCONVERGENCE_GRACE_SECS=120 \
    NOETL_NONCONVERGENCE_SWEEP_INTERVAL_SECS="$SWEEP_INTERVAL" \
    NOETL_NONCONVERGENCE_SWEEP_MAX_PER_TICK=20 >/dev/null
k rollout status deploy/noetl-server-rust --timeout=180s
arm on

echo
echo "== restore default-off =="
k set env deploy/noetl-server-rust NOETL_NONCONVERGENCE_SWEEP_ENABLED=false >/dev/null
k rollout status deploy/noetl-server-rust --timeout=180s

echo
echo "== summary =="
cat "$RUN/perf.txt"
echo "artifacts: $RUN"
