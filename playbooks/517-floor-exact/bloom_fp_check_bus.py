#!/usr/bin/env python3
"""BUS VARIANT of bloom_fp_check.py (noetl/ai-meta#517 Release B, 2026-11-07).

Differences: --root is the bus substrate itself (e.g. /data/cmdbus, no `substrate/`
subdirectory), and only the scheme-2 parts plus the newest 200 legacy parts are
checked, because a bus manifest holds ~10^5 parts. Run with POD=noetl-cmdbus-writer-0
CONTAINER=noetl-worker. Everything below is the original description.

Count bloom false positives in a part manifest, from the bytes. READ-ONLY.

noetl/ai-meta#517. For every part, compares what its `execution_bloom` CLAIMS
(maybe-present) against what the part's bytes ACTUALLY hold, over a probe set of
execution ids, and reports false positives by bloom scheme:

  scheme 0 (legacy): probe i = (h1 + i*h2) mod m           — collapses for some keys
  scheme 2 (mixed):  probe i = splitmix64(h1 ^ rotl(h2,32) ^ i*GOLDEN) mod m

h1/h2 are XXH64 of the key with seeds 0 and 0x9E3779B97F4A7C15, as in
ehdb-l0 `crates/ehdb-l0/src/bloom.rs` (v0.15.0). Scheme-2 bits arrive as
base64 of little-endian u64 words.

    POD=... NS=... CONTAINER=... ./bloom_fp_check.py --context kind-noetl \\
        --root /data/ehdb-k517b IDS.json [IDS.json ...]

IDS.json files hold {"ids": [...]} (the driver scripts write that). Every part's
real members are added to the probe set, so the run also proves there is no false
NEGATIVE (a real member the bloom rejects) — the positive control. Exit 1 on any
false negative, else 0. Prints the denominator first.
"""
import base64
import json
import os
import re
import subprocess
import sys

M64 = (1 << 64) - 1
P1, P2, P3, P4, P5 = (0x9E3779B185EBCA87, 0xC2B2AE3D27D4EB4F, 0x165667B19E3779F9,
                      0x85EBCA77C2B2AE63, 0x27D4EB2F165667C5)
GOLDEN = 0x9E3779B97F4A7C15


def _rotl(x, r):
    return ((x << r) | (x >> (64 - r))) & M64


def _round(acc, lane):
    acc = (acc + lane * P2) & M64
    return (_rotl(acc, 31) * P1) & M64


def _merge(acc, val):
    acc ^= _round(0, val)
    return (acc * P1 + P4) & M64


def xxh64(data: bytes, seed: int = 0) -> int:
    n = len(data)
    i = 0
    if n >= 32:
        v1 = (seed + P1 + P2) & M64
        v2 = (seed + P2) & M64
        v3 = seed
        v4 = (seed - P1) & M64
        while i + 32 <= n:
            v1 = _round(v1, int.from_bytes(data[i:i + 8], "little"))
            v2 = _round(v2, int.from_bytes(data[i + 8:i + 16], "little"))
            v3 = _round(v3, int.from_bytes(data[i + 16:i + 24], "little"))
            v4 = _round(v4, int.from_bytes(data[i + 24:i + 32], "little"))
            i += 32
        h = (_rotl(v1, 1) + _rotl(v2, 7) + _rotl(v3, 12) + _rotl(v4, 18)) & M64
        for v in (v1, v2, v3, v4):
            h = _merge(h, v)
    else:
        h = (seed + P5) & M64
    h = (h + n) & M64
    while i + 8 <= n:
        h ^= _round(0, int.from_bytes(data[i:i + 8], "little"))
        h = (_rotl(h, 27) * P1 + P4) & M64
        i += 8
    if i + 4 <= n:
        h ^= (int.from_bytes(data[i:i + 4], "little") * P1) & M64
        h = (_rotl(h, 23) * P2 + P3) & M64
        i += 4
    while i < n:
        h ^= (data[i] * P5) & M64
        h = (_rotl(h, 11) * P1) & M64
        i += 1
    h ^= h >> 33
    h = (h * P2) & M64
    h ^= h >> 29
    h = (h * P3) & M64
    h ^= h >> 32
    return h


def splitmix64(z):
    z = (z + GOLDEN) & M64
    z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & M64
    z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & M64
    return z ^ (z >> 31)


def words_of(bloom):
    if bloom.get("scheme", 0) == 2:
        raw = base64.b64decode(bloom["b64"])
        return [int.from_bytes(raw[j:j + 8], "little") for j in range(0, len(raw), 8)]
    return bloom["words"]


def maybe_contains(bloom, key: str) -> bool:
    words, m, k = words_of(bloom), bloom["m_bits"], bloom["k"]
    scheme = bloom.get("scheme", 0)
    h1 = xxh64(key.encode(), 0)
    h2 = xxh64(key.encode(), GOLDEN)
    for i in range(k):
        if scheme == 2:
            g = splitmix64(h1 ^ _rotl(h2, 32) ^ ((i * GOLDEN) & M64))
        else:
            g = (h1 + i * h2) & M64
        bit = g % m
        if not (words[bit // 64] >> (bit % 64)) & 1:
            return False
    return True


def main():
    assert xxh64(b"", 0) == 0xEF46DB3751D8E999, "xxh64 port is wrong"
    args = sys.argv[1:]
    ctx = args[args.index("--context") + 1] if "--context" in args else "kind-noetl"
    root = args[args.index("--root") + 1] if "--root" in args else "/data/ehdb-embedded"
    files = [a for a in args if a.endswith(".json")]
    pod = os.environ["POD"]
    kx = ["kubectl", "--context", ctx, "-n", os.environ.get("NS", "noetl"), "exec", pod,
          "-c", os.environ.get("CONTAINER", "noetl-server"), "--"]

    def cat(path):
        r = subprocess.run(kx + ["cat", path], capture_output=True)
        if r.returncode != 0:
            raise SystemExit(f"cannot read {path}")
        return r.stdout

    manifest = json.loads(cat(f"{root}/manifest/d1_event_log/LATEST"))
    _ps = manifest["parts"]
    _s2 = [p for p in _ps if (p.get("execution_bloom") or {}).get("scheme") == 2]
    _lg = [p for p in sorted(_ps, key=lambda p: p["max_sequence"]) if (p.get("execution_bloom") or {}).get("scheme") != 2][-200:]
    manifest["parts"] = _s2 + _lg
    probe = set()
    for f in files:
        probe |= {str(x) for x in json.load(open(f))["ids"]}
    members = {}
    for p in manifest["parts"]:
        raw = cat(f"{root}/{p['replicas'][0]['key']}")
        members[p["part_id"]] = set(re.findall(rb'"execution_id"\s*:\s*"?(\d{15,20})"?', raw))
        members[p["part_id"]] = {m.decode() for m in members[p["part_id"]]}
        probe |= members[p["part_id"]]

    stats = {}
    false_neg = []
    for p in manifest["parts"]:
        b = p.get("execution_bloom")
        if not b:
            continue
        s = stats.setdefault(b.get("scheme", 0), {"parts": 0, "tests": 0, "fp": 0, "neg": 0})
        s["parts"] += 1
        for key in probe:
            hit = maybe_contains(b, key)
            real = key in members[p["part_id"]]
            if real and not hit:
                false_neg.append((p["part_id"], key))
            if not real:
                s["neg"] += 1
                s["fp"] += hit
            s["tests"] += 1
    print(f"denominator: manifest v{manifest['version']} parts={len(manifest['parts'])} "
          f"probe ids={len(probe)}")
    for scheme, s in sorted(stats.items()):
        rate = s["fp"] / s["neg"] if s["neg"] else 0.0
        print(f"scheme {scheme}: parts={s['parts']} negative tests={s['neg']} "
              f"false positives={s['fp']} ({rate:.4%})")
    if false_neg:
        print(f"⚠⚠ FALSE NEGATIVES: {false_neg[:5]}")
        sys.exit(1)
    print("no false negatives: every real member tests present")


if __name__ == "__main__":
    main()
