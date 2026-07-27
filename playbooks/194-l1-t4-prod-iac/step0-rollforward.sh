#!/usr/bin/env bash
# Step 0 — roll forward to command-bus-capable images (bus stays NATS) + deploy
# the 2-shard writer infra (inert while NOETL_COMMAND_BUS=nats). Transport-neutral.
set -euo pipefail
cd "$(dirname "$0")"; source env.sh

echo "== 0.1 images (NOETL_COMMAND_BUS stays unset = nats) =="
K set image deploy/noetl-server-rust               noetl-server="$SERVER_IMG"
K set image deploy/noetl-worker-rust               noetl-worker="$WORKER_IMG"
K set image deploy/noetl-worker-system-pool        noetl-worker="$WORKER_IMG"
K set image deploy/noetl-worker-system-pool-shard1 noetl-worker="$WORKER_IMG"
K rollout status deploy/noetl-server-rust               --timeout=5m
K rollout status deploy/noetl-worker-rust               --timeout=5m
K rollout status deploy/noetl-worker-system-pool        --timeout=5m
K rollout status deploy/noetl-worker-system-pool-shard1 --timeout=5m

echo "== 0.2 writer infra (per-shard: shard0 + shard1) — inert in nats mode =="
K apply -f cmdbus-writer-shard0.yaml
K apply -f cmdbus-writer-shard1.yaml
K apply -f cmdbus-writer-podmonitoring.yaml
K rollout status deploy/noetl-cmdbus-writer-0 --timeout=5m
K rollout status deploy/noetl-cmdbus-writer-1 --timeout=5m
echo "== Step 0 applied =="
