#!/usr/bin/env bash
# Step 4 (1-shard) — FULL FLIP. Both system pools -> ehdb (claim the single
# writer) BEFORE the server stops publishing to NATS, then the writer + server
# -> ehdb. Order matters or system commands strand for the gap.
set -euo pipefail
cd "$(dirname "$0")"; source env.sh

echo "== 4.1 both system pools -> ehdb (compete on the single writer, exactly-once) =="
for d in noetl-worker-system-pool noetl-worker-system-pool-shard1; do
  K set env deploy/$d \
    NOETL_COMMAND_BUS=ehdb \
    NOETL_COMMAND_SHARD_COUNT=1 \
    NOETL_COMMAND_BUS_CLAIM_ADDR="${WRITER0}:9101"
done
K rollout status deploy/noetl-worker-system-pool        --timeout=5m
K rollout status deploy/noetl-worker-system-pool-shard1 --timeout=5m

echo "== 4.2 writer + server -> ehdb (server publishes to EHDB only) =="
K set env deploy/noetl-cmdbus-writer-0 NOETL_COMMAND_BUS=ehdb
K set env deploy/noetl-server-rust     NOETL_COMMAND_BUS=ehdb
K rollout status deploy/noetl-cmdbus-writer-0 --timeout=5m
K rollout status deploy/noetl-server-rust     --timeout=5m
echo "== FULL FLIP: command bus = ehdb end-to-end. NATS still installed. =="
