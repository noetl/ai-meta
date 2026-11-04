#!/usr/bin/env python3
"""Check what arming NOETL_EHDB_FLOOR_EXACT actually did. READ-ONLY.

noetl/ai-meta#517. Pairs with predict_floor.py.

    ./verify_floor.py before OUT_DIR [--context noetl-prod]   # just before the roll
    ./verify_floor.py after  OUT_DIR [--context noetl-prod]   # after the first passes

`before` records the manifest's part ids and the authoritative (Postgres) event
counts of up to 40 executions that live in the predicted-droppable parts.

`after` passes only if ALL hold, and prints each:
  1. the floor advanced above the stuck bloom floor, and not past the predicted
     corrected floor (the exact check can only raise the floor to where hot data
     really starts, never above it);
  2. every part that left the manifest was in the predicted-droppable set;
  3. floor refinement actually ran (noetl_ehdb_floor_refinement_total{refined} > 0);
  4. every sampled execution's Postgres event count is unchanged — the prune
     touches engine parts only, never `noetl.event`.
"""
import json
import re
import subprocess
import sys

POD = "noetl-server-rust-embedded-0"
mode, out_dir = sys.argv[1], sys.argv[2]
ctx = "noetl-prod"
if "--context" in sys.argv:
    ctx = sys.argv[sys.argv.index("--context") + 1]
KX = ["kubectl", "--context", ctx, "-n", "noetl", "exec", POD, "-c", "noetl-server", "--"]
PROXY = f"/api/v1/namespaces/noetl/pods/{POD}:8082/proxy"


def cat(path):
    r = subprocess.run(KX + ["cat", path], capture_output=True)
    if r.returncode != 0:
        raise SystemExit(f"cannot read {path}")
    return r.stdout


def raw(path):
    r = subprocess.run(["kubectl", "--context", ctx, "get", "--raw", PROXY + path],
                       capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else None


def event_count(eid):
    d = json.loads(raw(f"/api/executions/{eid}") or "{}")
    return len(d.get("events") or [])


def manifest():
    return json.loads(cat("/data/ehdb-embedded/substrate/manifest/d1_event_log/LATEST"))


pred = json.load(open(f"{out_dir}/prediction.json"))

if mode == "before":
    m = manifest()
    members = sorted({e for d in pred["droppable"] for e in d["members"]})[:40]
    state = {
        "manifest_version": m["version"],
        "part_ids": [p["part_id"] for p in m["parts"]],
        "oldest_min": min(p["min_sequence"] for p in m["parts"]),
        "event_counts": {str(e): event_count(e) for e in members},
    }
    json.dump(state, open(f"{out_dir}/before.json", "w"), indent=1)
    print(f"before: manifest v{state['manifest_version']} parts={len(state['part_ids'])} "
          f"oldest_min={state['oldest_min']} sampled={len(state['event_counts'])}")
    sys.exit(0)

before = json.load(open(f"{out_dir}/before.json"))
m = manifest()
after_ids = {p["part_id"] for p in m["parts"]}
gone = [p for p in before["part_ids"] if p not in after_ids]
droppable = {d["part_id"] for d in pred["droppable"]}
predicted_floor = (pred["predicted_floor"] or {}).get("min_sequence")
oldest_now = min(p["min_sequence"] for p in m["parts"])
metrics = raw("/metrics") or ""
refined = sum(float(x) for x in re.findall(
    r'^noetl_ehdb_floor_refinement_total\{outcome="refined"\} (\S+)', metrics, re.M))

ok = True
def check(cond, msg):
    global ok
    ok &= bool(cond)
    print(("PASS " if cond else "FAIL ") + msg)

check(oldest_now > before["oldest_min"],
      f"floor advanced: oldest part min {before['oldest_min']} -> {oldest_now}")
check(predicted_floor is None or oldest_now <= predicted_floor,
      f"not past the predicted floor {predicted_floor}")
outside = [p for p in gone if p not in droppable]
check(not outside, f"{len(gone)} part(s) dropped, all predicted-droppable "
      f"(outside the prediction: {outside[:3]})")
check(refined > 0, f"floor refinement ran: refined={refined:g}")
changed = {e: (c, event_count(e)) for e, c in before["event_counts"].items()}
changed = {e: v for e, v in changed.items() if v[0] != v[1]}
check(not changed, f"Postgres event counts unchanged for {len(before['event_counts'])} "
      f"sampled executions (changed: {list(changed.items())[:3]})")
print("RESULT", "PASS" if ok else "FAIL — roll back (unset NOETL_EHDB_FLOOR_EXACT)")
sys.exit(0 if ok else 1)
