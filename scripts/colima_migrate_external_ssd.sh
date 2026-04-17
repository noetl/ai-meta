#!/usr/bin/env bash
set -euo pipefail

# One-time Colima migration/setup for macOS with external SSD-backed storage.
# - Installs required tools (if missing)
# - Sets COLIMA_HOME to external SSD path
# - Starts Colima with Docker runtime and requested resources
# - Switches Docker CLI context to Colima
# - Optionally creates a kind cluster
#
# Usage:
#   scripts/colima_migrate_external_ssd.sh [SSD_MOUNT_PATH] [--create-kind [cluster_name]]
#
# Examples:
#   scripts/colima_migrate_external_ssd.sh
#   scripts/colima_migrate_external_ssd.sh /Volumes/X10 --create-kind
#   scripts/colima_migrate_external_ssd.sh /Volumes/X10 --create-kind noetl

SSD_MOUNT_PATH="/Volumes/X10"
CREATE_KIND="false"
KIND_CLUSTER_NAME="noetl"

if [[ $# -ge 1 && "${1:-}" != "--create-kind" ]]; then
  SSD_MOUNT_PATH="$1"
  shift
fi

if [[ "${1:-}" == "--create-kind" ]]; then
  CREATE_KIND="true"
  if [[ -n "${2:-}" ]]; then
    KIND_CLUSTER_NAME="$2"
  fi
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script is intended for macOS (Darwin)." >&2
  exit 1
fi

if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew is required but not installed: https://brew.sh" >&2
  exit 1
fi

if [[ ! -d "$SSD_MOUNT_PATH" ]]; then
  echo "SSD mount path does not exist: $SSD_MOUNT_PATH" >&2
  exit 1
fi

COLIMA_HOME_PATH="$SSD_MOUNT_PATH/colima-home"
mkdir -p "$COLIMA_HOME_PATH"

echo "==> Ensuring required tools are installed"
FORMULAE=(colima docker docker-buildx kind kubectl)
for formula in "${FORMULAE[@]}"; do
  if ! brew list --formula "$formula" >/dev/null 2>&1; then
    echo "Installing $formula..."
    brew install "$formula"
  fi
done

echo "==> Setting COLIMA_HOME for current shell"
export COLIMA_HOME="$COLIMA_HOME_PATH"

ZSHRC="$HOME/.zshrc"
EXPORT_LINE="export COLIMA_HOME=$COLIMA_HOME_PATH"
if [[ -f "$ZSHRC" ]]; then
  if ! grep -Fq "$EXPORT_LINE" "$ZSHRC"; then
    echo "$EXPORT_LINE" >> "$ZSHRC"
    echo "Added COLIMA_HOME export to $ZSHRC"
  fi
else
  echo "$EXPORT_LINE" > "$ZSHRC"
  echo "Created $ZSHRC with COLIMA_HOME export"
fi

echo "==> Stopping Docker Desktop if running (to avoid context/socket conflicts)"
osascript -e 'quit app "Docker"' >/dev/null 2>&1 || true
pkill -f "Docker Desktop" >/dev/null 2>&1 || true
pkill -f "com.docker.backend" >/dev/null 2>&1 || true

if command -v colima >/dev/null 2>&1; then
  echo "==> Stopping existing Colima instance (if running)"
  colima stop >/dev/null 2>&1 || true
fi

echo "==> Starting Colima on external SSD"
# Adjust these resources if needed for your workloads.
colima start \
  --runtime docker \
  --vm-type vz \
  --cpu 6 \
  --memory 12 \
  --disk 200

echo "==> Switching Docker context to Colima"
docker context use colima >/dev/null

echo "==> Verifying Docker engine"
docker info >/dev/null
docker context ls

if [[ "$CREATE_KIND" == "true" ]]; then
  echo "==> Checking kind cluster: $KIND_CLUSTER_NAME"
  if kind get clusters | grep -Fxq "$KIND_CLUSTER_NAME"; then
    echo "kind cluster '$KIND_CLUSTER_NAME' already exists; skipping create"
  else
    echo "Creating kind cluster '$KIND_CLUSTER_NAME'"
    kind create cluster --name "$KIND_CLUSTER_NAME"
  fi
  kubectl cluster-info --context "kind-$KIND_CLUSTER_NAME"
fi

echo
echo "Done."
echo "COLIMA_HOME is now: $COLIMA_HOME_PATH"
echo "External SSD must be mounted before running Colima."
echo "Open a new terminal (or run: source ~/.zshrc) to pick up persisted COLIMA_HOME."
