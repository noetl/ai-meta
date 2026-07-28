# Shared env for the L1 T4 shastaratech-prod cutover scripts. `source env.sh`.
export CTX=gke_shastaratech-noetl-prod_us-central1_noetl-prod-autopilot
export NS=noetl
# #203 fix images (retry 2026-07-27), copied ghcr->AR by crane, deploy by digest:
export SERVER_IMG=us-central1-docker.pkg.dev/shastaratech-noetl-prod/noetl/server-rust@sha256:5a73f4a5477f9ed2f8cc3bc2a390a4bf30515c90f17ef3bc9884ae4832782f8f       # v3.58.1
export WORKER_IMG=us-central1-docker.pkg.dev/shastaratech-noetl-prod/noetl/noetl-worker-rust@sha256:db156fa6e20ce006393f989f29936e5b23fb15cf476719d9439a2cd0844bcab3  # v5.81.1
# prior (v3.58.0/v5.81.0, ghcr): server@sha256:99b842... worker@sha256:27807d...
export WRITER0=noetl-cmdbus-writer-0.noetl.svc.cluster.local
export WRITER1=noetl-cmdbus-writer-1.noetl.svc.cluster.local
# Option 2 (chosen 2026-07-27): single command-bus shard -> single writer (writer-0).
# writer-1 is scaled to 0 by step1b. WRITER_ADDRS carries shard 0 only.
export WRITER_ADDRS="0@${WRITER0}:9100"
export DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
K() { kubectl --context "$CTX" -n "$NS" "$@"; }
