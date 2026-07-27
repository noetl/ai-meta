#!/usr/bin/env bash
# Step 3 (1-shard) — CANARY: flip the USER pool to ehdb (server stays shadow).
# Now maps cleanly: single writer, single user-pool deployment. Pause the user
# pool's NATS KEDA scaler first so it doesn't ramp on an undrained consumer.
set -euo pipefail
cd "$(dirname "$0")"; source env.sh

echo "== 3.0 pause user-pool NATS scaler =="
K annotate scaledobject noetl-worker-rust autoscaling.keda.sh/paused="true" --overwrite

echo "== 3.1 flip user pool to ehdb (claim from the single writer) =="
K set env deploy/noetl-worker-rust \
  NOETL_COMMAND_BUS=ehdb \
  NOETL_COMMAND_SHARD_COUNT=1 \
  NOETL_COMMAND_BUS_CLAIM_ADDR="${WRITER0}:9101"
K rollout status deploy/noetl-worker-rust --timeout=5m
echo "== CANARY: user pool on ehdb; system pool + server still NATS/shadow. =="
