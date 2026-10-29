#!/usr/bin/env bash
# writer-seed-proof.sh <image> : clean writer roll (writer-image-roll: image only,
# no annotation; TOKIO_WORKER_THREADS=8 kept by strategic env merge; Pending>60s -> undo),
# while a pool pod probes the writer's :9090 / :9106 / :9102 every second, so we can see
# whether the writer ANSWERS during the command-log scan (the old silent gap).
set -uo pipefail
S="$(cd "$(dirname "$0")" && pwd)"
K="kubectl --context noetl-prod -n noetl"
W=noetl-cmdbus-writer-0.noetl.svc.cluster.local
echo "pending before: $(kubectl --context noetl-prod get pods -A --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l | tr -d ' ')"
bash $S/pool-watch.sh BEFORE
PP=$($K get pods -o name | grep system-pool-shard1 | head -1)
# 150 s of 1 Hz probes from shard1's pod: ts, then 1/0 per port.
$K exec $PP -c noetl-worker -- sh -c "i=0; while [ \$i -lt 150 ]; do t=\$(date -u +%H:%M:%S); a=0;b=0;c=0; wget -q -T1 -O /dev/null http://$W:9090/metrics 2>/dev/null && a=1; wget -q -T1 -O /dev/null http://$W:9106/metrics 2>/dev/null && b=1; wget -q -T1 -O /dev/null http://$W:9102/metrics 2>/dev/null && c=1; echo \"\$t 9090=\$a 9106=\$b 9102=\$c\"; i=\$((i+1)); sleep 1; done" > $S/seed-probe.log 2>&1 &
PROBE=$!
sleep 3
date -u +%T
bash $S/writer-image-roll.sh "$1" || { rc=$?; echo "ROLL FAILED rc=$rc"; kill $PROBE 2>/dev/null; exit $rc; }
for i in $(seq 1 24); do bash $S/pool-watch.sh "$(date -u +%T)"; sleep 6; done
wait $PROBE
echo "--- writer env check:"
$K get sts noetl-cmdbus-writer -o json | python3 -c "
import json,sys;d=json.load(sys.stdin);c=d['spec']['template']['spec']['containers'][0]
print(c['image'][-20:], [f\"{e['name']}={e.get('value')}\" for e in c.get('env',[]) if e['name'].startswith(('TOKIO','NOETL_EHDB_TIER_PRUNE','NOETL_EHDB_TIER_RET'))], 'annotations', d['spec']['template']['metadata'].get('annotations'))"
echo "--- probe transitions (writer reachability, 1 Hz):"
awk '{s=$2" "$3" "$4} s!=p{print; p=s}' $S/seed-probe.log
echo "--- pool drop->resume:"
for P in $($K get pods -o name | grep system-pool); do echo "$(basename $P | tail -c 12):"; $K logs $P --since=8m 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | grep -E "resum|WAL feed dropped|NOT verified|replay from 0|WAL chain incomplete" | cut -c1-200 | tail -5; done
echo "--- writer timeline:"
$K logs noetl-cmdbus-writer-0 2>/dev/null | python3 -c "
import re,sys,datetime
L=[re.sub(r'\x1b\[[0-9;]*m','',l) for l in sys.stdin]
def ts(l):
  try: return datetime.datetime.fromisoformat(l.split()[0].replace('Z','+00:00'))
  except Exception: return None
T=[(ts(l),l) for l in L if ts(l)]
t0=T[0][0]; print('  t0', t0.time())
prev=t0
for t,l in T[:400]:
  d=(t-prev).total_seconds()
  if d>3: print(f'  ... GAP {d:.1f}s')
  if any(k in l for k in ('coordinator up','fan-out','consuming commands','/metrics','tier service','WARN','ERROR')): print(f'  +{(t-t0).total_seconds():6.2f}s', l.split(None,2)[-1][:110].strip())
  prev=t
print('  lines in first 60s:', sum(1 for t,_ in T if (t-t0).total_seconds()<60), ' ERROR/panic:', sum(1 for l in L if ' ERROR ' in l or 'panicked' in l))"
