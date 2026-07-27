#!/usr/bin/env bash
# Step 2 — SHADOW. Server + both writers publish to BOTH buses; NATS stays
# authoritative; workers stay on NATS. A shadow EHDB publish failure is logged and
# swallowed server-side (execute.rs), so this cannot break command delivery.
# EHDB KEDA scaler stays paused (there is none active here; the only ScaledObject
# is noetl-worker-rust on NATS lag — leave it).
set -euo pipefail
cd "$(dirname "$0")"; source env.sh

K set env deploy/noetl-cmdbus-writer-0 NOETL_COMMAND_BUS=shadow
K set env deploy/noetl-cmdbus-writer-1 NOETL_COMMAND_BUS=shadow
K set env deploy/noetl-server-rust \
  NOETL_COMMAND_BUS=shadow \
  NOETL_COMMAND_BUS_WRITER_ADDRS="$WRITER_ADDRS"
# NOETL_COMMAND_SHARD_COUNT=2 already set on the server.
K rollout status deploy/noetl-cmdbus-writer-0 --timeout=5m
K rollout status deploy/noetl-cmdbus-writer-1 --timeout=5m
K rollout status deploy/noetl-server-rust     --timeout=5m
echo "== SHADOW enabled (server + writers). Workers remain on NATS. =="
