# Shared env for the L1 T4 shastaratech-prod cutover scripts. `source env.sh`.
export CTX=gke_shastaratech-noetl-prod_us-central1_noetl-prod-autopilot
export NS=noetl
export SERVER_IMG=ghcr.io/noetl/server@sha256:99b84214ce9f8430a612a814f5b924b8b3bbdaa38dcc8cbda14087639aeb0ba0   # v3.58.0
export WORKER_IMG=ghcr.io/noetl/worker@sha256:27807d74c2cc356883b057a814a9d4300323763b0f11fcd0eb34844f5a82fbe1   # v5.81.0
export WRITER0=noetl-cmdbus-writer-0.noetl.svc.cluster.local
export WRITER1=noetl-cmdbus-writer-1.noetl.svc.cluster.local
export WRITER_ADDRS="0@${WRITER0}:9100,1@${WRITER1}:9100"
export DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
K() { kubectl --context "$CTX" -n "$NS" "$@"; }
