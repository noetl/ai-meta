#!/usr/bin/env python3
"""Predict what arming NOETL_EHDB_FLOOR_EXACT will do, and whether it is safe. READ-ONLY.

noetl/ai-meta#517. Today the prune floor comes from part blooms, and a bloom false
positive on an old part pins it there. Floor-exact replaces the floor holder's
bloom extent with its exact one, so the floor moves to where hot data REALLY
starts, and the next pass drops every part entirely below it.

This computes that answer from the bytes, before arming:

  1. hot executions = every listed execution minus the satisfied set (archived +
     out-of-coverage) from the server's archived-set snapshot;
  2. walk the manifest's parts oldest-first, reading each part's actual bytes,
     until one holds a REAL record of a hot execution: its min_sequence is the
     predicted corrected floor;
  3. every part before it is what the prune will drop. Each of its real member
     executions must be in the satisfied set — if any is not, arming would delete
     engine data that has no verified archive, and the answer is STOP.

    ./predict_floor.py OUT_DIR [--context noetl-prod]

Writes OUT_DIR/prediction.json. Prints the denominator (parts, hot, satisfied,
parts read) before any finding. Only `kubectl exec ... cat` and the executions
API are used; nothing is written to the cluster.
"""
import json
import re
import subprocess
import sys
import time

POD = "noetl-server-rust-embedded-0"
CONTAINER = "noetl-server"
ROOT = "/data/ehdb-embedded"
MANIFEST = f"{ROOT}/substrate/manifest/d1_event_log/LATEST"
SNAPSHOT = f"{ROOT}/archive-known.json"
EXEC_ID = re.compile(rb'"execution_id"\s*:\s*"?(\d{15,20})"?')

out_dir = sys.argv[1]
ctx = "noetl-prod"
if "--context" in sys.argv:
    ctx = sys.argv[sys.argv.index("--context") + 1]
KX = ["kubectl", "--context", ctx, "-n", "noetl", "exec", POD, "-c", CONTAINER, "--"]
PROXY = f"/api/v1/namespaces/noetl/pods/{POD}:8082/proxy"


def cat(path: str) -> bytes:
    r = subprocess.run(KX + ["cat", path], capture_output=True)
    if r.returncode != 0:
        raise SystemExit(f"cannot read {path}: {r.stderr.decode()[:200]}")
    return r.stdout


def api(path: str):
    r = subprocess.run(["kubectl", "--context", ctx, "get", "--raw", PROXY + path],
                       capture_output=True, text=True)
    return json.loads(r.stdout) if r.returncode == 0 else None


manifest = json.loads(cat(MANIFEST))
snap = json.loads(cat(SNAPSHOT))
satisfied = {a["id"] for a in snap["archived"]} | set(snap["out_of_coverage"])

rows, offset = [], 0
while True:
    d = api(f"/api/executions?limit=100&offset={offset}")
    page = d if isinstance(d, list) else (d or {}).get("executions") or []
    if not page or (rows and page[0]["execution_id"] == rows[0]["execution_id"]):
        break
    rows += page
    offset += 100
    time.sleep(0.15)
hot = {x["execution_id"] for x in rows if x["execution_id"] not in satisfied}

parts = sorted(manifest["parts"], key=lambda p: p["min_sequence"])
print(f"denominator: manifest v{manifest['version']} parts={len(parts)} listed={len(rows)} "
      f"satisfied={len(satisfied)} hot={len(hot)} snapshot_written={snap['written_at']}")

droppable, unsafe, floor_part = [], [], None
for i, p in enumerate(parts):
    key = p["replicas"][0]["key"]
    members = {int(m) for m in EXEC_ID.findall(cat(f"{ROOT}/substrate/{key}"))}
    if not members:
        raise SystemExit(f"read 0 execution ids from {p['part_id']} — the parse is broken, stop")
    hot_here = sorted(members & hot)
    if hot_here:
        floor_part = {"part_id": p["part_id"], "min_sequence": p["min_sequence"],
                      "hot_members": hot_here[:5], "parts_read": i + 1}
        break
    not_sat = sorted(members - satisfied)
    if not_sat:
        unsafe.append({"part_id": p["part_id"], "unsatisfied": not_sat[:5]})
    droppable.append({"part_id": p["part_id"], "min_sequence": p["min_sequence"],
                      "max_sequence": p["max_sequence"], "byte_size": p["byte_size"],
                      "members": sorted(members)})

pred = {
    "context": ctx,
    "manifest_version": manifest["version"],
    "current_bloom_floor_part": parts[0]["part_id"] if parts else None,
    "predicted_floor": floor_part,
    "droppable_parts": len(droppable),
    "droppable_bytes": sum(d["byte_size"] for d in droppable),
    "unsafe": unsafe,
    "droppable": droppable,
}
json.dump(pred, open(f"{out_dir}/prediction.json", "w"), indent=1)
print(f"predicted corrected floor: {floor_part}")
print(f"parts the next pass would drop: {pred['droppable_parts']} "
      f"({pred['droppable_bytes'] / 1e6:.1f} MB)")
if unsafe:
    print(f"⚠⚠ UNSAFE: {len(unsafe)} droppable part(s) hold executions that are NOT archived: "
          f"{unsafe[:3]} — do NOT arm floor-exact")
    sys.exit(2)
print("SAFE: every real member of every droppable part is archived or out of coverage")
