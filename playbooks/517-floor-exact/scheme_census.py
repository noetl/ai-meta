"""Bloom-scheme census of one EHDB manifest read from stdin (see scheme_census.sh)."""
import json
import sys

path = sys.argv[1]
raw = sys.stdin.read()
if not raw:
    print(path + ": ABSENT")
    sys.exit(0)
d = json.loads(raw)
parts = d.get("parts", [])


def scheme(p):
    b = p.get("execution_bloom")
    if not isinstance(b, dict):
        return "none"
    if "scheme" not in b:
        return "legacy"
    return "scheme" + str(b["scheme"])


counts = {}
for p in parts:
    counts[scheme(p)] = counts.get(scheme(p), 0) + 1
newest = sorted(parts, key=lambda p: p.get("max_sequence", 0))[-5:]
name = path.split("/data/")[1]
print("%s: v%s parts=%d %s newest5=%s" % (name, d["version"], len(parts), counts, [scheme(p) for p in newest]))
