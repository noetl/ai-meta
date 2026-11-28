#!/usr/bin/env bash
# enable-prune.sh : flip the writer to NOETL_EHDB_TIER_PRUNE_MODE=enabled (clean env roll),
# watch the startup prune pass, and compare what it unlinked to the approved plan.
# ANOMALY (anything pruned outside the plan) -> immediately revert to dry_run so no
# further hourly pass deletes more, and exit 8.
set -uo pipefail
S="$(cd "$(dirname "$0")" && pwd)"
K="kubectl --context noetl-prod -n noetl"
PLAN="1 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24"
PLAN_BYTES=6190115336
snap() { $K exec noetl-cmdbus-writer-0 -- sh -c "cd /data/eventbus/ehdb-tier && ls -l | awk 'NR>1{print \$5, \$9}' | sort -k2; df -B1 /data/eventbus | tail -1"; }
echo "=== BEFORE $(date -u +%T)"; snap > $S/tier-before.txt; tail -1 $S/tier-before.txt; grep -c . $S/tier-before.txt
[ -z "$($K get sts noetl-cmdbus-writer -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="NOETL_EHDB_TIER_PRUNE_ARCHIVE")].value}')" ] || { echo "ARCHIVE is set — abort"; exit 9; }
bash $S/pool-watch.sh BEFORE
bash $S/writer-env-roll.sh NOETL_EHDB_TIER_PRUNE_MODE=enabled || { echo "ROLL FAILED rc=$?"; exit 3; }
# Wait for the startup pass to finish both tiers (or 3 min).
for i in $(seq 1 36); do
  L=$($K logs noetl-cmdbus-writer-0 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')
  echo "$L" | grep -qE "tier retention.*(summary|complete|pass done|finished).*projection|projection.*(summary|complete)" && break
  sleep 5
done
echo "=== PRUNE LOG"
echo "$L" | grep -iE "tier retention|prune|ENABLED|archive" | cut -c1-300
PRUNED=$(echo "$L" | grep "segment pruned" | grep -oE "segment=[^ ]+" | sed 's/.*\///' )
echo "=== PRUNED SET:"; echo "$PRUNED"
BAD=$(echo "$PRUNED" | grep -v '^$' | while read f; do n=${f##*.}; t=${f%%.*}; if [ "$t" != eventlog ] || ! echo " $PLAN " | grep -q " $n "; then echo "$f"; fi; done)
if [ -n "$BAD" ]; then
  echo "!!! ANOMALY: pruned outside the plan: $BAD — reverting to dry_run NOW"
  bash $S/writer-env-roll.sh NOETL_EHDB_TIER_PRUNE_MODE=dry_run
  exit 8
fi
echo "=== AFTER $(date -u +%T)"; snap > $S/tier-after.txt; tail -1 $S/tier-after.txt
python3 - $S/tier-before.txt $S/tier-after.txt $PLAN_BYTES <<'PY'
import sys
def load(p):
    L=open(p).read().split('\n'); d={}
    for l in L[:-2]:
        if l.strip():
            sz,name=l.split(None,1); d[name]=int(sz)
    return d, L[-2] if L[-1]=='' else L[-1]
b,bdf=load(sys.argv[1]); a,adf=load(sys.argv[2])
gone=sorted(set(b)-set(a), key=lambda n:(n.split('.')[0], [int(x) if x.isdigit() else 0 for x in n.split('.')[2:3]], n))
segs=[n for n in gone if n.count('.')==2]
print("gone files:", len(gone), " gone segments:", len(segs), " segment bytes:", sum(b[n] for n in segs), " all bytes:", sum(b[n] for n in gone), " plan bytes:", sys.argv[3])
print("gone segments:", ' '.join(s.split('.',2)[2] for s in segs))
print("sidecars gone:", sorted(n for n in gone if n.count('.')==3)[:6], '...')
print("new files:", sorted(set(a)-set(b)))
for k in ['eventlog.jsonl.25','eventlog.jsonl.26','projection.jsonl.1','projection.jsonl.2','eventlog.jsonl.25.idx','eventlog.jsonl.26.idx']:
    print(" kept", k, k in a, a.get(k)==b.get(k))
print("df before:", bdf); print("df after: ", adf)
PY
for i in 1 2 3 4; do bash $S/pool-watch.sh "$(date -u +%T)"; sleep 15; done
echo "=== writer ERROR/panic: $($K logs noetl-cmdbus-writer-0 | grep -cE ' ERROR |panicked')"
$K logs noetl-cmdbus-writer-0 | grep -E ' ERROR | WARN ' | grep -viE 'MAX_INFLIGHT|bounded AFTER' | cut -c1-250 | tail -8
