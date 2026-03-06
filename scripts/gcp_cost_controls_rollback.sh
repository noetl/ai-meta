#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-}"
CLUSTER_NAME="${CLUSTER_NAME:-noetl-cluster}"
CLUSTER_LOCATION="${CLUSTER_LOCATION:-us-central1}"
RECREATE_ADDRESS="${RECREATE_ADDRESS:-false}"
RECREATE_ADDRESS_NAME="${RECREATE_ADDRESS_NAME:-gateway-static-ip-cloudflare}"

if [[ -z "$PROJECT_ID" ]]; then
  echo "PROJECT_ID is required."
  echo "Example: PROJECT_ID=my-project ./scripts/gcp_cost_controls_rollback.sh"
  exit 1
fi

gcloud config set project "$PROJECT_ID" >/dev/null

remove_exclusion_if_present() {
  local name="$1"
  if gcloud logging sinks describe _Default --project "$PROJECT_ID" \
    --format='value(exclusions[].name)' | tr ';' '\n' | grep -Fxq "$name"; then
    gcloud logging sinks update _Default --project "$PROJECT_ID" \
      --remove-exclusions="$name" >/dev/null
    echo "Removed exclusion: $name"
  else
    echo "Exclusion not present: $name"
  fi
}

remove_exclusion_if_present "noetl_health_polling_lowvalue"
remove_exclusion_if_present "clickhouse_stderr_stackframes"
remove_exclusion_if_present "noetl_worker_nats_unavailable_spam"
remove_exclusion_if_present "kube_system_chatty_lowseverity"

gcloud container clusters get-credentials "$CLUSTER_NAME" \
  --location "$CLUSTER_LOCATION" \
  --project "$PROJECT_ID" >/dev/null

if kubectl get operatorconfig config -n gmp-public >/dev/null 2>&1; then
  kubectl patch operatorconfig config -n gmp-public --type merge \
    -p '{"collection":{"filter":{}}}' >/dev/null
  echo "Reset gmp-public/operatorconfig collection.filter to empty."
else
  echo "Skipped OperatorConfig reset: gmp-public/config not found."
fi

if [[ "$RECREATE_ADDRESS" == "true" ]]; then
  if gcloud compute addresses describe "$RECREATE_ADDRESS_NAME" \
    --region "$CLUSTER_LOCATION" \
    --project "$PROJECT_ID" >/dev/null 2>&1; then
    echo "Address already exists: $RECREATE_ADDRESS_NAME"
  else
    gcloud compute addresses create "$RECREATE_ADDRESS_NAME" \
      --region "$CLUSTER_LOCATION" \
      --project "$PROJECT_ID" >/dev/null
    echo "Recreated static IP: $RECREATE_ADDRESS_NAME"
  fi
fi

echo
echo "Rollback completed for project: $PROJECT_ID"
gcloud logging sinks describe _Default --project "$PROJECT_ID" --format='table(exclusions[].name,exclusions[].disabled)'

