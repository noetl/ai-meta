"""Public fns in metrics.rs whose body mutates a metric (.inc/.set/.observe/...).

Split out of drift-audit.sh check 11: an accessor that merely returns a metric
handle is called only from the record_* wrappers in the same file, so treating
every `pub fn` as a recorder reported 51 of the server's 66 as orphaned.
"""
import sys, re

L = sys.stdin.read().split("\n")
MUT = re.compile(r"\.(inc|inc_by|set|observe|add|dec|dec_by|start_timer)\(")
cur, body, out = None, [], []

def flush():
    if cur and any(MUT.search(b) for b in body):
        out.append(cur)

for l in L:
    m = re.match(r"pub fn ([a-z_][a-z0-9_]*)\s*[(<]", l)
    if m:
        flush(); cur, body = m.group(1), []
        continue
    if cur is not None:
        if l.startswith("pub ") or (l and not l[0].isspace() and not l.startswith("}")):
            flush(); cur, body = None, []
        else:
            body.append(l)
flush()
print("\n".join(sorted(set(out))))
