#!/usr/bin/env bash
# usage: scheme_census.sh CONTEXT server|writer
# Bloom-scheme census of each store's LATEST manifest, read straight off the PVC.
# Reports total parts, how many carry scheme=2 / legacy / no bloom, and the scheme
# of the 5 newest parts by max_sequence (what was sealed most recently).
set -u
C=$1; R=$2
case $R in
  server) POD=$(kubectl --context "$C" -n noetl get pods -o name | grep -E 'noetl-server-rust' | head -1); CT=noetl-server
          [ "$C" = kind-noetl ] && CT=$(kubectl --context "$C" -n noetl get ${POD} -o jsonpath='{.spec.containers[0].name}')
          FILES="/data/ehdb-embedded/substrate/manifest/d1_event_log/LATEST /data/ehdb-embedded/runtime-substrate/manifest/d8_runtime/LATEST" ;;
  writer) POD=pod/noetl-cmdbus-writer-0; CT=noetl-worker
          FILES="/data/cmdbus/manifest/d1_event_log/LATEST /data/eventbus/manifest/d1_event_log/LATEST /data/eventkv/manifest/d4_kv/LATEST" ;;
  *) echo "role must be server|writer"; exit 2 ;;
esac
for f in $FILES; do
  kubectl --context "$C" -n noetl exec "${POD#pod/}" -c "$CT" -- cat "$f" 2>/dev/null | python3 -I "$(dirname "$0")/scheme_census.py" "$f"
done
