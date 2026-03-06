# GCP Cost Optimization Playbook (NoETL on GKE)

This playbook applies logging, monitoring, and networking cost controls for a NoETL deployment on GKE.

## Scope

- Cloud Logging: reduce `_Default` ingestion for high-volume low-value lines.
- Cloud Monitoring (Managed Prometheus): drop very high-volume container network series.
- Networking: delete one unused reserved static external IP.

## What This Applies

1. Logging exclusions on project sink `_Default`:
   - `noetl_health_polling_lowvalue`
   - `clickhouse_stderr_stackframes`
   - `noetl_worker_nats_unavailable_spam`
   - `kube_system_chatty_lowseverity`
2. Managed Prometheus `OperatorConfig` filter:
   - keep all metrics except:
     - `container_network_receive_bytes_total`
     - `container_network_receive_packets_total`
     - `container_network_receive_packets_dropped_total`
     - `container_network_transmit_bytes_total`
     - `container_network_transmit_packets_total`
     - `container_network_transmit_packets_dropped_total`
3. Delete one reserved, unused static IP address (default: `gateway-static-ip-cloudflare`).

## Prerequisites

- `gcloud` authenticated with permissions for:
  - Logging sink update
  - Compute address delete/create
  - GKE get-credentials
- `kubectl` installed and able to reach target cluster.
- Managed Prometheus `OperatorConfig` exists in `gmp-public/config` (script skips if absent).

## Apply

From `ai-meta` root:

```bash
chmod +x scripts/gcp_cost_controls_apply.sh scripts/gcp_cost_controls_rollback.sh

PROJECT_ID="<gcp-project-id>" \
CLUSTER_NAME="<gke-cluster-name>" \
CLUSTER_LOCATION="<region-or-zone>" \
UNUSED_ADDRESS_NAME="<reserved-unused-address-name>" \
./scripts/gcp_cost_controls_apply.sh
```

Example:

```bash
PROJECT_ID="noetl-demo-19700101" \
CLUSTER_NAME="noetl-cluster" \
CLUSTER_LOCATION="us-central1" \
UNUSED_ADDRESS_NAME="gateway-static-ip-cloudflare" \
./scripts/gcp_cost_controls_apply.sh
```

## Validate

### 1) Logging exclusions present

```bash
gcloud logging sinks describe _Default \
  --project "$PROJECT_ID" \
  --format='yaml(exclusions)'
```

### 2) Prometheus filter present

```bash
kubectl get operatorconfig config -n gmp-public -o yaml | sed -n '1,160p'
```

Expected:

- `collection.filter.matchOneOf` contains:
  - `{__name__!~"container_network_(receive|transmit)_(bytes|packets|packets_dropped)_total"}`

### 3) Static IP removed (if configured)

```bash
gcloud compute addresses list \
  --project "$PROJECT_ID" \
  --format='table(name,address,region,status,users)'
```

## Rollback

```bash
PROJECT_ID="<gcp-project-id>" \
CLUSTER_NAME="<gke-cluster-name>" \
CLUSTER_LOCATION="<region-or-zone>" \
./scripts/gcp_cost_controls_rollback.sh
```

If you also need to recreate a deleted static IP:

```bash
PROJECT_ID="<gcp-project-id>" \
CLUSTER_LOCATION="<region-or-zone>" \
RECREATE_ADDRESS=true \
RECREATE_ADDRESS_NAME="gateway-static-ip-cloudflare" \
./scripts/gcp_cost_controls_rollback.sh
```

## Notes and Tradeoffs

- `noetl_worker_nats_unavailable_spam` reduces repetitive error cost but hides those specific error lines in Cloud Logging. Keep separate alerting on NATS/server health.
- ClickHouse exclusion only targets repetitive stack-frame lines; top-level error lines remain.
- Prometheus filter reduces ingestion cost and cardinality load for high-volume container network metrics. If dashboards/alerts depend on those six metrics, adjust `matchOneOf`.
- Apply first in staging and compare:
  - `logging.googleapis.com/billing/bytes_ingested`
  - `monitoring.googleapis.com/billing/samples_ingested`

## Executed Reference (2026-03-05)

Applied on:

- Project: `noetl-demo-19700101`
- Cluster: `noetl-cluster` (`us-central1`)

Live changes made:

- Added four `_Default` sink exclusions listed above.
- Patched `gmp-public/operatorconfig config` `collection.filter.matchOneOf`.
- Deleted unused reserved IP `gateway-static-ip-cloudflare`.
