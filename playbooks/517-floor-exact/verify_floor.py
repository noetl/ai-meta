#!/usr/bin/env python3
"""Check what arming NOETL_EHDB_FLOOR_EXACT actually did. READ-ONLY.

noetl/ai-meta#517. Pairs with predict_floor.py (run it first: `before` and
`after` read its prediction.json, which records every part's real members).

    ./verify_floor.py before OUT_DIR [--context noetl-prod]   # just before the roll
    ./verify_floor.py after  OUT_DIR [--context noetl-prod]   # after the first passes
    POD=... NS=... EHDB_ROOT=... ./verify_floor.py ... --context kind-noetl

`before` records the manifest's part ids, the oldest min, and the authoritative
(Postgres) event counts of up to 40 executions held by parts the prediction
called at risk.

`after` checks the INVARIANT, not the prediction. Executions go cold every minute,
so between the prediction and the check more parts legitimately become droppable;
comparing against the prediction's hot set would fail a correct roll (it did, on
kind, 2026-11-04). It passes only if ALL hold:
  1. the floor advanced (the oldest part's min moved up);
  2. every part that left the manifest held ONLY executions that are archived or
     out of coverage NOW (the server's archived-set snapshot) — no dropped part held
     an execution that is still hot;
  3. floor refinement ran and could read (refined > 0, and no `unreadable` since the
     roll: with the flag ON, unreadable means the exact read failed);
  4. every sampled execution's Postgres event count is unchanged — the prune
     touches engine parts only, never `noetl.event`.
The parts the prediction called certain are reported, not failed: a floor may need
more than one pass (32 refinements each).
"""
import json
import os
import re
import subprocess
import sys
import time

POD = os.environ.get("POD", "noetl-server-rust-embedded-0")
NS = os.environ.get("NS", "noetl")
ROOT = os.environ.get("EHDB_ROOT", "/data/ehdb-embedded")
mode, out_dir = sys.argv[1], sys.argv[2]
ctx = "noetl-prod"
if "--context" in sys.argv:
    ctx = sys.argv[sys.argv.index("--context") + 1]
KX = ["kubectl", "--context", ctx, "-n", NS, "exec", POD, "-c", "noetl-server", "--"]
PROXY = f"/api/v1/namespaces/{NS}/pods/{POD}:8082/proxy"


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
    return json.loads(cat(f"{ROOT}/substrate/manifest/d1_event_log/LATEST"))


def refinement():
    out = {}
    for o, v in re.findall(r'^noetl_ehdb_floor_refinement_total\{outcome="(\w+)"\} (\S+)',
                           raw("/metrics") or "", re.M):
        out[o] = float(v)
    return out


def hot_now():
    snap = json.loads(cat(f"{ROOT}/archive-known.json"))
    satisfied = {int(a["id"]) for a in snap["archived"]} | {int(x) for x in snap["out_of_coverage"]}
    rows, offset = [], 0
    while True:
        d = json.loads(raw(f"/api/executions?limit=100&offset={offset}") or "[]")
        page = d if isinstance(d, list) else d.get("executions") or []
        if not page or (rows and page[0]["execution_id"] == rows[0]["execution_id"]):
            break
        rows += page
        offset += 100
        time.sleep(0.15)
    return satisfied, {int(x["execution_id"]) for x in rows} - satisfied


pred = json.load(open(f"{out_dir}/prediction.json"))
if "parts" not in pred:
    raise SystemExit("prediction.json has no per-part members — re-run predict_floor.py")

if mode == "before":
    m = manifest()
    # Sample the at-risk parts first, then the oldest parts — the next to drop as holders
    # go cold. A prediction with nothing at risk would otherwise sample 0 executions and
    # the Postgres check would pass vacuously (it did, on kind).
    members = []
    for d in pred["droppable"] + sorted(pred["parts"], key=lambda p: p["min_sequence"]):
        for e in d["members"]:
            if e not in members and len(members) < 40:
                members.append(e)
    if not members:
        raise SystemExit("no executions to sample — the prediction holds no part members")
    state = {
        "manifest_version": m["version"],
        "part_ids": [p["part_id"] for p in m["parts"]],
        "oldest_min": min(p["min_sequence"] for p in m["parts"]),
        "event_counts": {str(e): event_count(e) for e in members},
        "refinement": refinement(),
    }
    unknown = [p for p in state["part_ids"] if p not in {x["part_id"] for x in pred["parts"]}]
    json.dump(state, open(f"{out_dir}/before.json", "w"), indent=1)
    print(f"before: manifest v{state['manifest_version']} parts={len(state['part_ids'])} "
          f"oldest_min={state['oldest_min']} sampled={len(state['event_counts'])} "
          f"refinement={state['refinement']}")
    if unknown:
        print(f"note: {len(unknown)} part(s) sealed after the prediction (not yet member-mapped)")
    sys.exit(0)

before = json.load(open(f"{out_dir}/before.json"))
m = manifest()
after_ids = {p["part_id"] for p in m["parts"]}
gone = [p for p in before["part_ids"] if p not in after_ids]
by_id = {p["part_id"]: p for p in pred["parts"]}
oldest_now = min(p["min_sequence"] for p in m["parts"])
satisfied, hot = hot_now()
ref = refinement()
ref0 = before.get("refinement", {})

ok = True
def check(cond, msg):
    global ok
    ok &= bool(cond)
    print(("PASS " if cond else "FAIL ") + msg)

check(oldest_now > before["oldest_min"],
      f"floor advanced: oldest part min {before['oldest_min']} -> {oldest_now}")
unmapped = [p for p in gone if p not in by_id]
check(not unmapped, f"every dropped part was member-mapped by the prediction "
      f"(unmapped: {unmapped[:3]})")
bad = []
for pid in gone:
    if pid not in by_id:
        continue
    mem = set(by_id[pid]["members"])
    if mem & hot or mem - satisfied:
        bad.append({"part_id": pid, "hot": sorted(mem & hot)[:3],
                    "unarchived": sorted(mem - satisfied)[:3]})
check(not bad, f"{len(gone)} dropped part(s) held only archived / out-of-coverage "
      f"executions, none hot (violations: {bad[:3]})")
check(ref.get("refined", 0) > 0,
      f"floor refinement ran: refined={ref.get('refined', 0):g}")
# With the flag OFF every pass counts one `unreadable` (the exact read returns None by
# construction), so the pre-roll value is meaningless. The env change restarts the pod,
# which resets the counter: after the roll, any `unreadable` is a real failed read.
check(ref.get("unreadable", 0) == 0,
      f"no exact read failed since the roll: unreadable={ref.get('unreadable', 0):g} "
      f"(pre-roll {ref0.get('unreadable', 0):g} counts the OFF passes)")
changed = {e: (c, event_count(e)) for e, c in before["event_counts"].items()}
changed = {e: v for e, v in changed.items() if v[0] != v[1]}
check(not changed, f"Postgres event counts unchanged for {len(before['event_counts'])} "
      f"sampled executions (changed: {list(changed.items())[:3]})")
certain = [d["part_id"] for d in pred["droppable"] if d.get("certain")]
print(f"info: {sum(1 for c in certain if c in gone)} of {len(certain)} predicted-certain "
      f"part(s) dropped so far; hot now={len(hot)}")
print("RESULT", "PASS" if ok else "FAIL — roll back (unset NOETL_EHDB_FLOOR_EXACT)")
sys.exit(0 if ok else 1)
