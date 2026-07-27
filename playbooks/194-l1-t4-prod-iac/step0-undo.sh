#!/usr/bin/env bash
# Step 0 image rollback — revert the three roll-forward deployments to their
# prior ReplicaSet (back to server v3.52 / worker 5.51/5.52). Writers can be left
# (inert) or deleted with `kubectl delete -f cmdbus-writer-shard{0,1}.yaml`.
set -uo pipefail
cd "$(dirname "$0")"; source env.sh
K rollout undo deploy/noetl-server-rust
K rollout undo deploy/noetl-worker-rust
K rollout undo deploy/noetl-worker-system-pool
K rollout undo deploy/noetl-worker-system-pool-shard1
K rollout status deploy/noetl-server-rust --timeout=5m
echo "== Step 0 images reverted =="
