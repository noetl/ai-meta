#!/usr/bin/env python3
"""Explain the retention floor from the manifest blooms. READ-ONLY.

noetl/ai-meta#506 RFC phase P0b. The prune floor is
min(min_sequence) over the hot executions' footprint, and the footprint comes
from `hot_footprint` (noetl/server src/handlers/ehdb_embedded.rs), which counts
an execution as present in every part whose `execution_bloom` says *maybe*.
So a bloom false positive on an old part pins the floor at that part.

    ./floor_bloom_check.py MANIFEST.json HOT_IDS.txt [KNOWN_MEMBER_ID]

Reimplements ehdb-l0's Bloom::maybe_contains (crates/ehdb-l0/src/bloom.rs,
v0.13.4): two XXH64 base hashes (seeds 0 and 0x9E3779B97F4A7C15), probe
i = (h1 + i*h2) mod m_bits for i in 0..k. Pass KNOWN_MEMBER_ID (an execution
actually stored in the oldest part) as the positive control: if it does not
test true, the port is wrong and nothing below it means anything.
"""
import json
import sys

M64 = (1 << 64) - 1
P1, P2, P3, P4, P5 = (0x9E3779B185EBCA87, 0xC2B2AE3D27D4EB4F, 0x165667B19E3779F9,
                      0x85EBCA77C2B2AE63, 0x27D4EB2F165667C5)


def _rotl(x, r):
    return ((x << r) | (x >> (64 - r))) & M64


def _round(acc, lane):
    acc = (acc + lane * P2) & M64
    return (_rotl(acc, 31) * P1) & M64


def _merge(acc, val):
    acc ^= _round(0, val)
    return (acc * P1 + P4) & M64


def xxh64(data: bytes, seed: int = 0) -> int:
    n, i = len(data), 0
    if n >= 32:
        v1 = (seed + P1 + P2) & M64
        v2 = (seed + P2) & M64
        v3 = seed & M64
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
        k1 = _round(0, int.from_bytes(data[i:i + 8], "little"))
        h = ((_rotl(h ^ k1, 27) * P1) + P4) & M64
        i += 8
    if i + 4 <= n:
        h = ((_rotl(h ^ ((int.from_bytes(data[i:i + 4], "little") * P1) & M64), 23) * P2) + P3) & M64
        i += 4
    while i < n:
        h = (_rotl(h ^ ((data[i] * P5) & M64), 11) * P1) & M64
        i += 1
    h ^= h >> 33
    h = (h * P2) & M64
    h ^= h >> 29
    h = (h * P3) & M64
    h ^= h >> 32
    return h


def maybe_contains(bloom, key: str) -> bool:
    words, m, k = bloom["words"], bloom["m_bits"], bloom["k"]
    h1 = xxh64(key.encode(), 0)
    h2 = xxh64(key.encode(), 0x9E3779B97F4A7C15)
    for i in range(k):
        bit = ((h1 + i * h2) & M64) % m
        if not (words[bit // 64] >> (bit % 64)) & 1:
            return False
    return True


def main():
    manifest = json.load(open(sys.argv[1]))
    hot = [l.strip() for l in open(sys.argv[2]) if l.strip()]
    parts = sorted(manifest["parts"], key=lambda p: p["min_sequence"])
    oldest = parts[0]

    # Known-answer test for the hash port (XXH64 of b"" with seed 0).
    assert xxh64(b"", 0) == 0xEF46DB3751D8E999, "xxh64 port is wrong"
    if len(sys.argv) > 3:
        member = sys.argv[3]
        ok = maybe_contains(oldest["execution_bloom"], member)
        print(f"positive control: known member {member} in oldest part -> {ok}")
        if not ok:
            sys.exit("port disagrees with the engine; stop")

    print(f"parts={len(parts)} hot_ids={len(hot)} oldest_part={oldest['part_id']} "
          f"records={oldest['record_count']} m_bits={oldest['execution_bloom']['m_bits']} "
          f"k={oldest['execution_bloom']['k']}")
    false_hits = [h for h in hot if maybe_contains(oldest["execution_bloom"], h)]
    print(f"hot ids the OLDEST part's bloom says 'maybe': {len(false_hits)} {false_hits[:10]}")

    # The floor hot_footprint would compute: min min_sequence over hot ids that hit any part.
    floor, holder, per_part_hits = None, None, 0
    for p in parts:
        hits = [h for h in hot if maybe_contains(p["execution_bloom"], h)]
        if hits:
            per_part_hits += 1
            if floor is None or p["min_sequence"] < floor:
                floor, holder = p["min_sequence"], (p["part_id"], hits[:3])
    print(f"reconstructed floor={floor} from part {holder}")
    print(f"parts with at least one hot-id bloom hit: {per_part_hits}/{len(parts)}")


if __name__ == "__main__":
    main()
