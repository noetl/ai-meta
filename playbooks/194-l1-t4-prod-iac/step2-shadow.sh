#!/usr/bin/env bash
# Step 2 (1-shard) — SHADOW. Server + the single writer publish to BOTH buses;
# NATS authoritative; workers stay on NATS. Shadow EHDB publish failures are
# logged+swallowed server-side, so this cannot break delivery.
set -euo pipefail
cd "$(dirname "$0")"; source env.sh

K set env deploy/noetl-cmdbus-writer-0 NOETL_COMMAND_BUS=shadow
K set env deploy/noetl-server-rust \
  NOETL_COMMAND_BUS=shadow \
  NOETL_COMMAND_BUS_WRITER_ADDRS="$WRITER_ADDRS"   # single shard 0
# NOETL_COMMAND_SHARD_COUNT=1 already set on the server (step1b).
K rollout status deploy/noetl-cmdbus-writer-0 --timeout=5m
K rollout status deploy/noetl-server-rust     --timeout=5m
echo "== SHADOW enabled (server + single writer). Workers remain on NATS. =="
