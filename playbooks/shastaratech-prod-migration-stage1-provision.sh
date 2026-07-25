#!/usr/bin/env bash
#
# Stage 1 (dark provision) of playbooks/shastaratech-prod-migration.md —
# the "stand up new" step, captured as reproducible IaC.
#
# Scope: NEW empty cluster + target namespaces ONLY.  Does NOT deploy the
# NoETL stack, DB, secrets, or DNS (those are Stages 2-7, gated on the
# data-migration decisions).  Does NOT touch live prod (noetl-demo-19700101,
# a different org/billing account) — every command is scoped to
# shastaratech-noetl-prod explicitly.
#
# Autopilot is chosen for parity with current prod (also Autopilot).
# Autopilot turns on Workload Identity, private nodes, and autoscaling by
# default; we deliberately do not override those defaults.
#
# First executed 2026-07-24 with ADC = shastaratech@gmail.com against
# project shastaratech-noetl-prod (folder 687234939033, org 561323743912),
# billing account 0153F3-73E360-BD0B38.
#
# Re-run safety: create-auto and `kubectl create namespace` are not
# idempotent — they error if the resource already exists.  Treat that error
# as "already provisioned" rather than a failure.
set -euo pipefail

PROJECT=shastaratech-noetl-prod
REGION=us-central1
CLUSTER=noetl-prod-autopilot
CHANNEL=regular

echo "=== GATE: billing linked + APIs enabled (self-check, must pass) ==="
gcloud billing projects describe "$PROJECT" \
  --format="value(billingEnabled)" | grep -qx True \
  || { echo "FAIL: billing not enabled on $PROJECT"; exit 1; }

for api in container.googleapis.com compute.googleapis.com; do
  gcloud services list --enabled --project "$PROJECT" \
    --filter="config.name:$api" --format="value(config.name)" \
    | grep -qx "$api" || { echo "FAIL: $api not enabled on $PROJECT"; exit 1; }
done
echo "GATE GREEN"

echo "=== CREATE: GKE Autopilot cluster (regional us-central1) ==="
gcloud container clusters create-auto "$CLUSTER" \
  --project "$PROJECT" \
  --region "$REGION" \
  --release-channel "$CHANNEL"

echo "=== REACHABILITY: fetch credentials + confirm API server responds ==="
gcloud container clusters get-credentials "$CLUSTER" \
  --region "$REGION" --project "$PROJECT"
kubectl get nodes
kubectl get ns

echo "=== NAMESPACES: both dev and prod hosted on this one cluster ==="
# Nothing is deployed into these yet — Stages 2-7 populate them.
kubectl create namespace noetl-prod
kubectl create namespace noetl-dev

echo "=== DONE: cluster + namespaces provisioned (dark). No stack/DB/DNS. ==="
