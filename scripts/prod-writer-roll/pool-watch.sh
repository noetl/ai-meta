#!/usr/bin/env bash
# pool-watch.sh <label> : one line per system-pool pod: restarts, ready, healthy, resubscribe kinds.
K="kubectl --context noetl-prod -n noetl"
for P in $($K get pods -o name | grep system-pool); do
  m=$($K exec $P -c noetl-worker -- sh -c "wget -qO- 127.0.0.1:9090/metrics 2>/dev/null" 2>/dev/null | grep -E "^noetl_worker_state_builder_(healthy|wal_resubscribe_total|wal_events_total)" | sed -E 's/noetl_worker_state_builder_//; s/wal_resubscribe_total\{kind="([a-z_]+)"\}/resub_\1/' | tr '\n' ' ')
  echo "$1 $(basename $P | tail -c 12) restarts=$($K get $P -o jsonpath='{.status.containerStatuses[0].restartCount}') ready=$($K get $P -o jsonpath='{.status.containerStatuses[0].ready}') $m"
done
