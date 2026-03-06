#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-}"
CLUSTER_NAME="${CLUSTER_NAME:-noetl-cluster}"
CLUSTER_LOCATION="${CLUSTER_LOCATION:-us-central1}"
UNUSED_ADDRESS_NAME="${UNUSED_ADDRESS_NAME:-gateway-static-ip-cloudflare}"

if [[ -z "$PROJECT_ID" ]]; then
  echo "PROJECT_ID is required."
  echo "Example: PROJECT_ID=my-project ./scripts/gcp_cost_controls_apply.sh"
  exit 1
fi

gcloud config set project "$PROJECT_ID" >/dev/null

upsert_exclusion() {
  local name="$1"
  local description="$2"
  local filter="$3"

  if gcloud logging sinks describe _Default --project "$PROJECT_ID" \
    --format='value(exclusions[].name)' | tr ';' '\n' | grep -Fxq "$name"; then
    gcloud logging sinks update _Default --project "$PROJECT_ID" \
      --update-exclusion="name=$name,description=$description,filter=$filter" >/dev/null
    echo "Updated exclusion: $name"
  else
    gcloud logging sinks update _Default --project "$PROJECT_ID" \
      --add-exclusion="name=$name,description=$description,filter=$filter" >/dev/null
    echo "Added exclusion: $name"
  fi
}

F_HEALTH='resource.type="k8s_container" AND (resource.labels.namespace_name="noetl" OR resource.labels.namespace_name="gateway" OR resource.labels.namespace_name="gui") AND severity<ERROR AND (textPayload =~ "/api/(health|pool/status|auth/session/validate)" OR jsonPayload.message =~ "/api/(health|pool/status|auth/session/validate)")'
F_CLICKHOUSE='resource.type="k8s_container" AND resource.labels.namespace_name="clickhouse" AND resource.labels.container_name="clickhouse" AND logName="projects/'"$PROJECT_ID"'/logs/stderr" AND (textPayload =~ "^[0-9]+\\." OR textPayload:"(version")'
F_NATS='resource.type="k8s_container" AND resource.labels.namespace_name="noetl" AND resource.labels.container_name="worker" AND severity="ERROR" AND jsonPayload.message:"Error fetching messages: nats: ServiceUnavailableError"'
F_KSYS='resource.type="k8s_container" AND resource.labels.namespace_name="kube-system" AND severity<ERROR AND (resource.labels.container_name="fluentbit" OR resource.labels.container_name="cilium-agent" OR resource.labels.container_name="netd" OR resource.labels.container_name="gke-metrics-agent")'

upsert_exclusion "noetl_health_polling_lowvalue" \
  "Drop low-severity high-frequency health and session-validate request logs" \
  "$F_HEALTH"
upsert_exclusion "clickhouse_stderr_stackframes" \
  "Drop repetitive ClickHouse stack frame lines from stderr to reduce log flood cost" \
  "$F_CLICKHOUSE"
upsert_exclusion "noetl_worker_nats_unavailable_spam" \
  "Drop repetitive worker poll ServiceUnavailableError spam lines" \
  "$F_NATS"
upsert_exclusion "kube_system_chatty_lowseverity" \
  "Drop low-severity high-volume infra container logs in kube-system" \
  "$F_KSYS"

gcloud container clusters get-credentials "$CLUSTER_NAME" \
  --location "$CLUSTER_LOCATION" \
  --project "$PROJECT_ID" >/dev/null

if kubectl get operatorconfig config -n gmp-public >/dev/null 2>&1; then
  kubectl patch operatorconfig config -n gmp-public --type merge \
    -p '{"collection":{"filter":{"matchOneOf":["{__name__!~\"container_network_(receive|transmit)_(bytes|packets|packets_dropped)_total\"}"]}}}' >/dev/null
  echo "Patched gmp-public/operatorconfig config with collection filter."
else
  echo "Skipped OperatorConfig patch: gmp-public/config not found."
fi

if gcloud compute addresses describe "$UNUSED_ADDRESS_NAME" \
  --region "$CLUSTER_LOCATION" \
  --project "$PROJECT_ID" >/dev/null 2>&1; then
  status="$(gcloud compute addresses describe "$UNUSED_ADDRESS_NAME" --region "$CLUSTER_LOCATION" --project "$PROJECT_ID" --format='value(status)')"
  users="$(gcloud compute addresses describe "$UNUSED_ADDRESS_NAME" --region "$CLUSTER_LOCATION" --project "$PROJECT_ID" --format='value(users)')"
  if [[ "$status" == "RESERVED" && -z "$users" ]]; then
    gcloud compute addresses delete "$UNUSED_ADDRESS_NAME" \
      --region "$CLUSTER_LOCATION" \
      --project "$PROJECT_ID" \
      --quiet >/dev/null
    echo "Deleted unused static IP: $UNUSED_ADDRESS_NAME"
  else
    echo "Skipped deleting $UNUSED_ADDRESS_NAME (status=$status users=$users)."
  fi
else
  echo "Skipped static IP cleanup: $UNUSED_ADDRESS_NAME not found in $CLUSTER_LOCATION."
fi

echo
echo "Applied cost controls for project: $PROJECT_ID"
gcloud logging sinks describe _Default --project "$PROJECT_ID" --format='table(exclusions[].name,exclusions[].disabled)'

