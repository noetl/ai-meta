#!/usr/bin/env bash
# Step 1b (Option 2) — collapse the COMMAND-BUS axis to a single shard. Bus stays
# NATS throughout (neutral). The state/event sharding axis (#166: NOETL_SHARD_COUNT=2,
# NOETL_SHARD_INDEX, state-shard-write, the off-server state builder on its own
# noetl_events consumer) is UNTOUCHED — kind-proven independent (sharding.rs:172
# "correctness never depends on affinity"; the command bus reads only
# NOETL_COMMAND_SHARD_COUNT; the state materializer uses NOETL_RESULT_SHARD_COUNT
# + the event stream).
#
# Order matters (no stranding): unify the system consumers to the broad shared
# subject FIRST (subsumption: `.system.>` matches today's `.system.shard.N.>`),
# THEN drop the server to command_shard_count=1 (which switches its system publish
# to the legacy `.system.<eid>` subject the broad filter still matches).
#
# Kind learnings baked in:
#  - both system pools share ONE durable consumer (noetl_worker_system_rust) or
#    JetStream double-delivers to distinct consumers -> duplicate execution.
#  - the writer in ehdb mode needs NOETL_COMMAND_BUS_CLAIM_ADDR (self); set now so
#    the later full-flip doesn't crash the writer.
set -euo pipefail
cd "$(dirname "$0")"; source env.sh

echo "== 1b.1 — unify system pools onto broad shared NATS consumer (still cmdshard=2, subsumption-safe) =="
for d in noetl-worker-system-pool noetl-worker-system-pool-shard1; do
  K set env deploy/$d 'NATS_FILTER_SUBJECT=noetl.commands.system.>' 'NATS_CONSUMER=noetl_worker_system_rust'
done
K rollout status deploy/noetl-worker-system-pool        --timeout=5m
K rollout status deploy/noetl-worker-system-pool-shard1 --timeout=5m

echo "== 1b.2 — server to command_shard_count=1, single writer addr =="
K set env deploy/noetl-server-rust \
  NOETL_COMMAND_SHARD_COUNT=1 \
  NOETL_COMMAND_BUS_WRITER_ADDRS="0@${WRITER0}:9100"
K rollout status deploy/noetl-server-rust --timeout=5m

echo "== 1b.3 — single writer: cmdshard=1 + self CLAIM_ADDR (ehdb-mode requirement); retire writer-1 =="
K set env deploy/noetl-cmdbus-writer-0 \
  NOETL_COMMAND_SHARD_COUNT=1 \
  NOETL_COMMAND_BUS_CLAIM_ADDR=127.0.0.1:9101
K rollout status deploy/noetl-cmdbus-writer-0 --timeout=5m
K scale deploy/noetl-cmdbus-writer-1 --replicas=0

echo "== 1b done — command bus is single-shard; bus still NATS; #166 state axis untouched =="
