#!/usr/bin/env python3
"""How late do events arrive after an execution's terminal event? READ-ONLY.

noetl/ai-meta#506 RFC phase P0b. The settle window has to exceed the latest
plausible post-terminal event; this measures what prod actually does.

    ./measure_late_events.py [MAX_EXECUTIONS=600] [OUT=late_events.json]

Pages GET /api/executions (newest first, 100 per page) through the apiserver
proxy, then reads GET /api/executions/{id} for every terminal one and finds:

  - the FIRST terminal event (TERMINAL_EVENT_TYPES, copied from the server's
    src/db/queries/event_chain.rs);
  - every event created after it: count, types, and the delay of the latest.

Prints the denominator (executions listed, terminal, measured, failed reads)
before any finding. Spaced at ~4 req/s; the server has two Tokio workers.
"""
import collections
import datetime as dt
import json
import subprocess
import sys
import time

CTX = "noetl-prod"
POD = "noetl-server-rust-embedded-0"
PROXY = f"/api/v1/namespaces/noetl/pods/{POD}:8082/proxy"
# Keep in step with TERMINAL_EVENT_TYPES in noetl/server src/db/queries/event_chain.rs.
TERMINAL = {"execution.completed", "execution.failed", "execution.cancelled",
            "playbook.completed", "playbook.failed"}

max_execs = int(sys.argv[1]) if len(sys.argv) > 1 else 600
out_path = sys.argv[2] if len(sys.argv) > 2 else "late_events.json"


def get(path):
    r = subprocess.run(["kubectl", "--context", CTX, "get", "--raw", PROXY + path],
                       capture_output=True, text=True)
    if r.returncode != 0:
        return None
    try:
        return json.loads(r.stdout)
    except ValueError:
        return None


def ts(s):
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00"))


listed = []
for page in range(1, max_execs // 100 + 2):
    d = get(f"/api/executions?limit=100&page={page}&offset={(page - 1) * 100}")
    rows = d if isinstance(d, list) else (d or {}).get("items") or (d or {}).get("executions") or []
    if not rows or (listed and rows[0]["execution_id"] == listed[0]["execution_id"]):
        break
    listed += rows
    time.sleep(0.25)
listed = listed[:max_execs]
terminal = [e for e in listed if e.get("status") in ("COMPLETED", "FAILED", "CANCELLED")]

measured, failed, results = 0, 0, []
for e in terminal:
    d = get(f"/api/executions/{e['execution_id']}")
    time.sleep(0.25)
    evs = (d or {}).get("events")
    if not evs:
        failed += 1
        continue
    term = [x for x in evs if x["event_type"] in TERMINAL]
    if not term:
        results.append({"execution_id": str(e["execution_id"]), "path": e.get("path"),
                        "status": e.get("status"), "terminal_event": None})
        measured += 1
        continue
    t0 = min(ts(x["created_at"]) for x in term)
    late = [x for x in evs if ts(x["created_at"]) > t0]
    results.append({
        "execution_id": str(e["execution_id"]), "path": e.get("path"), "status": e.get("status"),
        "events": len(evs), "terminal_events": len(term),
        "late_count": len(late),
        "late_types": sorted(collections.Counter(x["event_type"] for x in late).items()),
        "max_delay_s": max(((ts(x["created_at"]) - t0).total_seconds() for x in late), default=0.0),
        "terminal_at": t0.isoformat(),
    })
    measured += 1

json.dump(results, open(out_path, "w"), indent=1)
with_term = [r for r in results if r.get("terminal_event", True) is not None and "late_count" in r]
late = [r for r in with_term if r["late_count"] > 0]
delays = sorted(r["max_delay_s"] for r in late)
print(f"listed={len(listed)} terminal={len(terminal)} measured={measured} read_failed={failed} "
      f"no_terminal_event={sum(1 for r in results if r.get('terminal_event', True) is None)}")
print(f"with_late_events={len(late)}/{len(with_term)}")
if delays:
    q = lambda p: delays[min(len(delays) - 1, int(p * len(delays)))]
    print(f"max_delay_s p50={q(.5):.3f} p90={q(.9):.3f} p99={q(.99):.3f} max={delays[-1]:.3f}")
    types = collections.Counter()
    for r in late:
        for t, n in r["late_types"]:
            types[t] += n
    print("late event types:", types.most_common(10))
    for r in sorted(late, key=lambda r: -r["max_delay_s"])[:5]:
        print("  worst:", r["execution_id"], r["path"], r["status"], f"{r['max_delay_s']:.1f}s", r["late_types"])
