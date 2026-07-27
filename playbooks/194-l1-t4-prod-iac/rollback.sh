#!/usr/bin/env bash
# One-command rollback — bus back to NATS at every stage. NATS is never deleted
# and commands are never dual-CONSUMED, so this is a clean revert with no
# reconciliation. Safe to run from any step (shadow/canary/full-flip).
set -uo pipefail
cd "$(dirname "$0")"; source env.sh

echo "== bus -> nats on server + both worker pools + both writers =="
K set env deploy/noetl-server-rust               NOETL_COMMAND_BUS=nats || true
K set env deploy/noetl-worker-rust               NOETL_COMMAND_BUS=nats || true
K set env deploy/noetl-worker-system-pool        NOETL_COMMAND_BUS=nats || true
K set env deploy/noetl-worker-system-pool-shard1 NOETL_COMMAND_BUS=nats || true
K set env deploy/noetl-cmdbus-writer-0           NOETL_COMMAND_BUS=nats || true
K set env deploy/noetl-cmdbus-writer-1           NOETL_COMMAND_BUS=nats || true

echo "== restart to apply =="
K rollout restart deploy/noetl-server-rust deploy/noetl-worker-rust \
  deploy/noetl-worker-system-pool deploy/noetl-worker-system-pool-shard1

echo "== unpause any paused NATS scalers =="
K annotate scaledobject noetl-worker-rust autoscaling.keda.sh/paused- --overwrite 2>/dev/null || true

echo "== rollback issued; verify pods Ready then drive synthetic load =="
