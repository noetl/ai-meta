#!/usr/bin/env python3
"""Exercise the EHDB networked KV face (:9107) — the NATS-KV replacement.

Why this exists: the KV face's only real client is the gateway, and the gateway
is not in this kind rig (its GHCR images are amd64-only and its KV traffic is
sessions/requests, which needs real Auth0 login flow). Without a client the face
is *bound but idle*, and "bound" is not evidence — that is precisely the kind of
thing the EHDB-only cutover kept mistaking for working.

So this speaks the wire protocol directly: 4-byte big-endian length prefix +
externally-tagged JSON (`ehdb-feed/src/kv.rs`, `read_frame` in `lib.rs:144`).
It drives the two buckets the gateway actually uses — `sessions` and `requests`
— concurrently, and verifies round-tripped VALUES, not just status flags. A
face that connects and round-trips nothing is the failure a success flag hides.

Usage: kv-exercise.py <host:port> [ops] [concurrency]
"""
import json
import socket
import struct
import sys
import threading
import time

ADDR = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1:19107"
OPS = int(sys.argv[2]) if len(sys.argv) > 2 else 400
CONC = int(sys.argv[3]) if len(sys.argv) > 3 else 20
HOST, PORT = ADDR.rsplit(":", 1)
PORT = int(PORT)

stats = {"put": 0, "get": 0, "scan": 0, "delete": 0, "mismatch": 0, "err": 0}
lock = threading.Lock()
latencies = []


def call(sock, req):
    body = json.dumps(req).encode()
    sock.sendall(struct.pack(">I", len(body)) + body)
    (n,) = struct.unpack(">I", _recv_exact(sock, 4))
    return json.loads(_recv_exact(sock, n))


def _recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("KV face closed the connection mid-frame")
        buf += chunk
    return buf


def worker(wid, ops):
    local = {"put": 0, "get": 0, "scan": 0, "delete": 0, "mismatch": 0, "err": 0}
    lats = []
    try:
        s = socket.create_connection((HOST, PORT), timeout=20)
        s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    except Exception as e:  # noqa: BLE001
        with lock:
            stats["err"] += ops
        print(f"worker {wid}: connect failed: {e}", file=sys.stderr)
        return

    for i in range(ops):
        bucket = "sessions" if i % 2 == 0 else "requests"
        key = f"soak-w{wid}-{i}"
        val = f"value-{wid}-{i}-{'x' * 64}"
        try:
            t0 = time.perf_counter()
            r = call(s, {"Put": {"bucket": bucket, "key": key, "value": val, "ttl_ms": 600000}})
            if not r.get("ok"):
                local["err"] += 1
                continue
            local["put"] += 1

            r = call(s, {"Get": {"bucket": bucket, "key": key}})
            lats.append((time.perf_counter() - t0) * 1000)
            if not r.get("ok"):
                local["err"] += 1
                continue
            local["get"] += 1
            # Verify the VALUE round-tripped. A KV that stores nothing but
            # answers ok:true is exactly the shape a status check misses.
            if r.get("value") != val:
                local["mismatch"] += 1

            if i % 25 == 0:
                r = call(s, {"Scan": {"bucket": bucket}})
                if r.get("ok"):
                    local["scan"] += 1
                else:
                    local["err"] += 1
            if i % 7 == 0:
                r = call(s, {"Delete": {"bucket": bucket, "key": key}})
                if r.get("ok"):
                    local["delete"] += 1
                else:
                    local["err"] += 1
        except Exception:  # noqa: BLE001
            local["err"] += 1
            try:
                s = socket.create_connection((HOST, PORT), timeout=20)
            except Exception:  # noqa: BLE001
                break
    s.close()
    with lock:
        for k, v in local.items():
            stats[k] += v
        latencies.extend(lats)


per = max(1, OPS // CONC)
threads = [threading.Thread(target=worker, args=(w, per)) for w in range(CONC)]
t0 = time.perf_counter()
for t in threads:
    t.start()
for t in threads:
    t.join()
elapsed = time.perf_counter() - t0

latencies.sort()


def pct(p):
    if not latencies:
        return float("nan")
    return latencies[min(len(latencies) - 1, int(len(latencies) * p))]


total = stats["put"] + stats["get"] + stats["scan"] + stats["delete"]
print(f"kv_ops_total={total}")
for k in ("put", "get", "scan", "delete", "mismatch", "err"):
    print(f"kv_{k}={stats[k]}")
print(f"kv_elapsed_s={elapsed:.2f}")
print(f"kv_ops_per_s={total / elapsed:.1f}" if elapsed > 0 else "kv_ops_per_s=NA")
print(f"kv_put_get_p50_ms={pct(0.50):.2f}")
print(f"kv_put_get_p99_ms={pct(0.99):.2f}")

# A value mismatch or any error means the face is not usable, regardless of
# how many ops "succeeded".
sys.exit(1 if (stats["mismatch"] or stats["err"]) else 0)

