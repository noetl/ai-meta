#!/usr/bin/env python3
"""Predict what arming NOETL_EHDB_FLOOR_EXACT will do, and whether it is safe. READ-ONLY.

noetl/ai-meta#517. Today the prune floor comes from part blooms, and a bloom false
positive on an old part pins it there. Floor-exact replaces the floor holder's
bloom extent with its exact one, so the floor moves to where hot data REALLY
starts, and the next pass drops every part whose max_sequence is below it
(ehdb `plan_retention`: `part.max_sequence < keep_from`).

This computes that answer from the bytes, before arming:

  1. hot executions = every listed execution minus the satisfied set (archived +
     out-of-coverage) from the server's archived-set snapshot;
  2. read every part's bytes (oldest first) and find the parts holding a REAL
     record of a hot execution. The corrected floor `keep_from` is the lowest hot
     record's sequence, so it lies in [L, U], where L = the lowest min_sequence and
     U = the lowest max_sequence over those parts;
  3. AT RISK = every part with max_sequence < U and no hot member: the superset of
     what the prune can drop (the parts with max < L are certain to go). Every real
     member of every at-risk part must be in the satisfied set — otherwise arming
     would delete engine data with no verified archive: STOP (exit 2).
  4. noetl/ai-meta#520: sealed parts can overlap. If an at-risk part's range overlaps
     a part that will be KEPT, the drop would split records the kept part's
     neighbourhood depends on — STOP (exit 3) and decide #520 first.

    ./predict_floor.py OUT_DIR [--context noetl-prod]
    POD=... NS=... CONTAINER=... ./predict_floor.py OUT_DIR --context kind-noetl

Writes OUT_DIR/prediction.json. Prints the denominator (parts, hot, satisfied,
parts read) before any finding. Only `kubectl exec ... cat` and the executions
API are used; nothing is written to the cluster.
"""
import json
import os
import re
import subprocess
import sys
import time

POD = os.environ.get("POD", "noetl-server-rust-embedded-0")
NS = os.environ.get("NS", "noetl")
CONTAINER = os.environ.get("CONTAINER", "noetl-server")
ROOT = os.environ.get("EHDB_ROOT", "/data/ehdb-embedded")
MANIFEST = f"{ROOT}/substrate/manifest/d1_event_log/LATEST"
SNAPSHOT = f"{ROOT}/archive-known.json"
EXEC_ID = re.compile(rb'"execution_id"\s*:\s*"?(\d{15,20})"?')

out_dir = sys.argv[1]
ctx = "noetl-prod"
if "--context" in sys.argv:
    ctx = sys.argv[sys.argv.index("--context") + 1]
KX = ["kubectl", "--context", ctx, "-n", NS, "exec", POD, "-c", CONTAINER, "--"]
PROXY = f"/api/v1/namespaces/{NS}/pods/{POD}:8082/proxy"


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
listed = {int(x["execution_id"]) for x in rows}
satisfied = {int(x) for x in satisfied}
hot = listed - satisfied

parts = sorted(manifest["parts"], key=lambda p: p["min_sequence"])
print(f"denominator: ctx={ctx} manifest v{manifest['version']} parts={len(parts)} "
      f"listed={len(listed)} satisfied={len(satisfied)} hot={len(hot)} "
      f"snapshot_written={snap['written_at']}")

def try_cat(path: str):
    r = subprocess.run(KX + ["cat", path], capture_output=True)
    return r.stdout if r.returncode == 0 else None


members_of, vanished = {}, []
for p in parts:
    key = p["replicas"][0]["key"]
    raw = try_cat(f"{ROOT}/substrate/{key}")
    if raw is None and p.get("local_path"):
        raw = try_cat(p["local_path"])
    if raw is None:
        vanished.append(p["part_id"])
        continue
    members = {int(m) for m in EXEC_ID.findall(raw)}
    if not members:
        raise SystemExit(f"read 0 execution ids from {p['part_id']} — the parse is broken, stop")
    members_of[p["part_id"]] = members
if vanished:
    # A live prune can drop a part between the manifest read and the part read. That is
    # fine only if the part is gone from the CURRENT manifest too; anything else is a read
    # failure and the prediction would be computed over a hole.
    now_ids = {p["part_id"] for p in json.loads(cat(MANIFEST))["parts"]}
    still = [v for v in vanished if v in now_ids]
    if still:
        raise SystemExit(f"cannot read {len(still)} part(s) still in the manifest: {still[:3]}")
    print(f"note: {len(vanished)} part(s) pruned during the read, excluded: {vanished[:3]}")
    parts = [p for p in parts if p["part_id"] in members_of]
print(f"parts read: {len(members_of)} of {len(parts)}")

hot_parts = [p for p in parts if members_of[p["part_id"]] & hot]
if hot_parts:
    L = min(p["min_sequence"] for p in hot_parts)
    U = min(p["max_sequence"] for p in hot_parts)
    first = min(hot_parts, key=lambda p: p["min_sequence"])
    floor_part = {"part_id": first["part_id"], "min_sequence": L, "upper_bound": U,
                  "hot_members": sorted(members_of[first["part_id"]] & hot)[:5]}
else:
    L = U = None
    floor_part = None

at_risk, unsafe = [], []
for p in parts:
    mem = members_of[p["part_id"]]
    if mem & hot:
        continue
    if U is not None and p["max_sequence"] >= U:
        continue
    not_sat = sorted(mem - satisfied)
    if not_sat:
        unsafe.append({"part_id": p["part_id"], "unsatisfied": not_sat[:5]})
    at_risk.append({"part_id": p["part_id"], "min_sequence": p["min_sequence"],
                    "max_sequence": p["max_sequence"], "byte_size": p["byte_size"],
                    "certain": L is None or p["max_sequence"] < L,
                    "members": sorted(mem)})

# #520: an at-risk part must not overlap a part that stays.
risk_ids = {a["part_id"] for a in at_risk}
kept = [p for p in parts if p["part_id"] not in risk_ids]
overlaps = [(a["part_id"], k["part_id"]) for a in at_risk for k in kept
            if a["min_sequence"] <= k["max_sequence"] and k["min_sequence"] <= a["max_sequence"]]
all_overlaps = [(a["part_id"], b["part_id"]) for i, a in enumerate(parts) for b in parts[i + 1:]
                if b["min_sequence"] <= a["max_sequence"]]

pred = {
    "context": ctx,
    "manifest_version": manifest["version"],
    "current_bloom_floor_part": parts[0]["part_id"] if parts else None,
    "predicted_floor": floor_part,
    "droppable_parts": len(at_risk),
    "certain_parts": sum(1 for a in at_risk if a["certain"]),
    "droppable_bytes": sum(a["byte_size"] for a in at_risk),
    "unsafe": unsafe,
    "overlaps_with_kept": overlaps,
    "overlapping_pairs_in_store": all_overlaps,
    "droppable": at_risk,
    # Every part's real members, so verify_floor.py can check the parts that are GONE
    # after the roll against the archived set at verify time (the hot set shrinks
    # continuously, so a check against this snapshot's hot set would be wrong).
    "parts": [{"part_id": p["part_id"], "min_sequence": p["min_sequence"],
               "max_sequence": p["max_sequence"], "members": sorted(members_of[p["part_id"]])}
              for p in parts],
}
json.dump(pred, open(f"{out_dir}/prediction.json", "w"), indent=1)
print(f"predicted corrected floor in [{L}, {U}]: {floor_part}")
print(f"parts at risk (max < U, no hot member): {pred['droppable_parts']} "
      f"({pred['certain_parts']} certain), {pred['droppable_bytes'] / 1e6:.1f} MB")
print(f"overlapping part pairs in the store (#520): {len(all_overlaps)}")
if unsafe:
    print(f"⚠⚠ UNSAFE: {len(unsafe)} at-risk part(s) hold executions that are NOT archived: "
          f"{unsafe[:3]} — do NOT arm floor-exact")
    sys.exit(2)
if overlaps:
    print(f"⚠⚠ OVERLAP: {len(overlaps)} at-risk part(s) overlap a kept part: {overlaps[:3]} "
          f"— decide noetl/ai-meta#520 before arming")
    sys.exit(3)
print("SAFE: every real member of every at-risk part is archived or out of coverage, "
      "and no at-risk part overlaps a kept part")
