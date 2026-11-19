#!/usr/bin/env bash
# release-roll.sh <prev-tag> : wait for the next worker release after <prev-tag>, mirror
# GHCR->AR (digest-verified), image-only writer roll with probe, then age-seal + prune +
# dispatch checks.
set -uo pipefail
S="$(cd "$(dirname "$0")" && pwd)"
G=ghcr.io/noetl/worker; AR=us-central1-docker.pkg.dev/shastaratech-noetl-prod/noetl/noetl-worker-rust
K="kubectl --context noetl-prod -n noetl"
PREV=$1
cd /tmp
until v=$(gh release list -R noetl/worker -L 1 --json tagName --jq ".[0].tagName") && [ -n "$v" ] && [ "$v" != "$PREV" ]; do sleep 20; done
V=${v#v}; echo "$(date -u +%T) release $v -> $(git ls-remote https://github.com/noetl/worker refs/tags/$v | cut -c1-12)"
until crane manifest $G:$V 2>/dev/null | python3 -c "import json,sys;m=json.load(sys.stdin);a=[x['platform']['architecture'] for x in m.get('manifests',[])];sys.exit(0 if 'amd64' in a else 1)" 2>/dev/null; do sleep 30; done
D=$(crane digest $G:$V); echo "$(date -u +%T) GHCR $V $D"
crane copy $G@$D $AR:$v 2>&1 | tail -1
A=$(crane digest $AR:$v); echo "AR $v $A"
[ "$D" = "$A" ] || { echo "DIGEST MISMATCH — not rolling"; exit 7; }
echo "=== ROLL $(date -u +%T)"
RT=$(date -u +%Y-%m-%dT%H:%M:%S)
bash $S/writer-seed-proof.sh "$AR@$A" || exit $?
echo "=== SEALS / PRUNE since roll"
for i in $(seq 1 60); do $K logs noetl-cmdbus-writer-0 2>/dev/null | grep -q 'sealed.*tier="projection".*reason="age"\|reason="age".*tier="projection"\|tier="projection".*reason="age"' && break; sleep 10; done
$K logs noetl-cmdbus-writer-0 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | grep -E "tier store sealed|segment indexed|ENABLED summary|segment pruned|DRY RUN \(nothing|verdict" | cut -c1-260 | tail -20
$K exec noetl-cmdbus-writer-0 -- sh -c "cd /data/eventbus/ehdb-tier; ls -l --full-time projection* eventlog.jsonl eventlog.jsonl.2?; df -B1 /data/eventbus | tail -1"
$K exec noetl-cmdbus-writer-0 -- sh -c "wget -qO- 127.0.0.1:9090/metrics" | grep -E "^noetl_ehdb_tier_seals_total"
echo "=== DISPATCH: first execution started after $RT"
until o=$($K exec noetl-server-rust-embedded-0 -- sh -c 'wget -qO- "http://127.0.0.1:8082/api/executions?limit=6"' 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin); items=d if isinstance(d,list) else d.get('executions') or []
done=[e for e in items if str(e.get('started_at'))[:19]>='$RT' and e.get('status') in ('COMPLETED','FAILED','CANCELLED')]
print('\n'.join(f\"{e['execution_id']} {e['status']} {e.get('path')} {str(e.get('started_at'))[11:19]} {str(e.get('completed_at'))[11:19]}\" for e in done))" 2>/dev/null); [ -n "$o" ]; do sleep 20; done
echo "$o"
for P in $($K get pods -o name | grep system-pool); do echo "$(basename $P|tail -c 12) restarts=$($K get $P -o jsonpath='{.status.containerStatuses[0].restartCount}') noops=$($K logs $P -c noetl-worker --since=40m | grep -c 'WAL chain incomplete')"; done
echo "writer restarts=$($K get pod noetl-cmdbus-writer-0 -o jsonpath='{.status.containerStatuses[0].restartCount}') errors=$($K logs noetl-cmdbus-writer-0 | grep -cE ' ERROR |panicked')"
