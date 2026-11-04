#!/usr/bin/env python3
"""#516 product smoke: one travel planner turn + one ranch concierge turn.

Run before AND after every roll; any FAIL => roll back.

  python3 -I smoke.py LABEL [--server http://127.0.0.1:28182] [--out DIR]

* travel  — muno/playbooks/itinerary-planner via the server API (needs a
            port-forward to the prod server pod). The workload is copied from
            the latest COMPLETED planner execution with identity cleared and a
            `_smoke-516-<label>-<ts>` thread.
* ranch   — shastaranch/concierge/turn through the LIVE gateway as a guest
            session, exactly as mountshastaranch.com does it
            (POST /api/auth/guest -> GraphQL executePlaybook -> poll
            /noetl/executions/<id>), on a `_smoke-516-<label>-<ts>` thread.
            Pass = an object whose `messages` is a list of widget envelopes.

The e2e fixture smoke (`repos/e2e/scripts/prod_regression_validate.py --set
smoke`) is run separately; see README.md.

⚠ `kubectl port-forward` fails open: the script prints the server build_info so
the caller can confirm it reached PROD, and refuses if the metric is absent.
No token is printed or written anywhere.
"""
import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

GATEWAY = "https://gateway.mestumre.dev"
SITE_ORIGIN = "https://mountshastaranch.com"
PLANNER = "muno/playbooks/itinerary-planner"
TURN = "shastaranch/concierge/turn"
UA = {"User-Agent": "noetl-516-smoke"}


def req(url, data=None, headers=None, timeout=60):
    h = dict(UA)
    h.update(headers or {})
    body = None
    if data is not None:
        body = json.dumps(data).encode()
        h["Content-Type"] = "application/json"
    r = urllib.request.Request(url, data=body, headers=h, method="POST" if body else "GET")
    with urllib.request.urlopen(r, timeout=timeout) as resp:
        return resp.status, resp.read()


def jget(url, headers=None, timeout=30):
    return json.loads(req(url, headers=headers, timeout=timeout)[1])


def find_reply(v, depth=0):
    """Mirror of site/src/chat/gateway.rs find_reply."""
    if depth > 24:
        return None
    if isinstance(v, str):
        t = v.strip()
        if t.startswith("{") and t.endswith("}"):
            try:
                return find_reply(json.loads(t), depth + 1)
            except ValueError:
                return None
        return None
    if isinstance(v, list):
        for x in reversed(v):
            r = find_reply(x, depth + 1)
            if r is not None:
                return r
        return None
    if isinstance(v, dict):
        m = v.get("messages")
        if isinstance(m, list) and m and isinstance(m[0], dict) and "widget_type" in m[0]:
            return v
        for x in v.values():
            r = find_reply(x, depth + 1)
            if r is not None:
                return r
    return None


def travel(server, label, out):
    lst = jget(f"{server}/api/executions?path={urllib.parse.quote(PLANNER)}&limit=20")
    rows = lst if isinstance(lst, list) else lst.get("executions", lst.get("items", []))
    done = [r for r in rows if r.get("status") == "COMPLETED"]
    if not done:
        return False, "no recent COMPLETED planner execution to copy a workload from"
    src = jget(f"{server}/api/executions/{done[0]['execution_id']}")
    w = dict(src.get("workload") or {})
    if not w:
        return False, "source execution has no workload"
    w.update(thread_id=f"_smoke-516-{label}-{int(time.time())}", user_uid="", request_id="",
             gateway_url="", replay=False, replay_thread_id="",
             event_payload={"text": "Hotels in Paris from Dec 3 to Dec 6"})
    _, b = req(f"{server}/api/execute", {"path": PLANNER, "workload": w})
    eid = json.loads(b)["execution_id"]
    t = time.time()
    d = {}
    while time.time() - t < 180:
        try:
            d = jget(f"{server}/api/executions/{eid}")
        except urllib.error.HTTPError:
            time.sleep(1)
            continue
        if d.get("status") in ("COMPLETED", "FAILED", "CANCELLED"):
            break
        time.sleep(1)
    wall = time.time() - t
    json.dump(d, open(os.path.join(out, f"travel-{eid}.json"), "w"))
    ev = d.get("events", [])
    fails = [e["node_name"] for e in ev if "fail" in e.get("event_type", "") or e.get("event_type") == "call.error"]
    steps = {e["node_name"] for e in ev if e.get("event_type") == "call.done"}
    widgets = sorted(set(re.findall(r'widget_type[\\"]*:[\\ "]*([a-z_]+)', json.dumps(
        [e.get("result") for e in ev if e.get("node_name") == "final_result"]))))
    ok = d.get("status") == "COMPLETED" and not fails and "final_result" in steps
    return ok, f"{eid} {d.get('status')} wall {wall:.1f}s fails={fails} widgets={widgets}"


def ranch(label, out):
    hdr = {"Origin": SITE_ORIGIN}
    t0 = time.time()
    st, b = req(f"{GATEWAY}/api/auth/guest", {}, hdr, timeout=15)
    tok = json.loads(b)["session_token"]
    auth = dict(hdr, Authorization=f"Bearer {tok}")
    thread = f"_smoke-516-{label}-{int(time.time())}"
    q = ("mutation ExecutePlaybook($name: String!, $vars: JSON, $clientId: String) "
         "{ executePlaybook(name: $name, variables: $vars, clientId: $clientId) { executionId requestId status } }")
    vars_ = {"message": "What time is breakfast?", "history": [], "client_today": time.strftime("%Y-%m-%d"),
             "thread_id": thread, "stay": None, "user_uid": None, "known": None, "set_name": ""}
    _, b = req(f"{GATEWAY}/graphql", {"query": q, "variables": {"name": TURN, "vars": vars_, "clientId": None}},
               auth, timeout=30)
    v = json.loads(b)
    if v.get("errors"):
        return False, f"executePlaybook error: {v['errors'][0].get('message')}"
    eid = str(v["data"]["executePlaybook"]["executionId"])
    reply, d = None, {}
    while time.time() - t0 < 120:
        try:
            d = jget(f"{GATEWAY}/noetl/executions/{eid}?page_size=100", auth, timeout=15)
        except urllib.error.HTTPError:
            time.sleep(1.5)
            continue
        reply = find_reply(d)
        status = str(d.get("status", "")).upper()
        if reply is not None or status in ("COMPLETED", "FAILED", "ERROR", "CANCELLED"):
            break
        time.sleep(1.5)
    wall = time.time() - t0
    json.dump({"execution_id": eid, "thread_id": thread, "reply": reply, "status": d.get("status")},
              open(os.path.join(out, f"ranch-{eid}.json"), "w"))
    text = json.dumps(reply)[:160] if reply else ""
    return reply is not None, f"{eid} thread={thread} status={d.get('status')} wall {wall:.1f}s reply={text}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("label")
    ap.add_argument("--server", default="http://127.0.0.1:28182")
    ap.add_argument("--out", default=os.environ.get("SMOKE_OUT", "."))
    a = ap.parse_args()
    out = os.path.join(a.out, f"smoke-{a.label}")
    os.makedirs(out, exist_ok=True)
    m = req(f"{a.server}/metrics", timeout=20)[1].decode()
    bi = [l for l in m.splitlines() if l.startswith("noetl_server_build_info")]
    if not bi:
        sys.exit("REFUSE: no noetl_server_build_info at --server (wrong port-forward?)")
    print(bi[0])
    for u in ("https://travel.mestumre.dev/", f"{GATEWAY}/health", f"{SITE_ORIGIN}/"):
        t = time.time()
        print(u, req(u, timeout=30)[0], f"{time.time() - t:.2f}s")
    res = {}
    for name, fn in (("travel", lambda: travel(a.server, a.label, out)), ("ranch", lambda: ranch(a.label, out))):
        try:
            res[name] = fn()
        except Exception as e:  # noqa: BLE001 - report, never hide
            res[name] = (False, f"{type(e).__name__}: {e}")
        print(name, "PASS" if res[name][0] else "FAIL", res[name][1])
    ok = all(r[0] for r in res.values())
    print("SMOKE", a.label, "PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
