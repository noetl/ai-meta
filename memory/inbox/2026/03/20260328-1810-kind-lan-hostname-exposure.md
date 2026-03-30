# Kind LAN Hostname Exposure (noetl) - 2026-03-28

## Goal
Expose local kind-noetl services on the machine network interface so they are reachable via machine hostname (for example `studio722.local`) instead of localhost-only binds.

## Why this change was needed
The kind cluster port mappings were bound to loopback (`listenAddress: "127.0.0.1"`), which prevented access from other devices on the home network even when using a `.local` hostname.

## What was changed

### 1) Kind port bindings switched from loopback to all interfaces
Changed `listenAddress` from `127.0.0.1` to `0.0.0.0` in both repos:

- `repos/noetl/ci/kind/config.yaml`
- `repos/noetl/ci/kind/config-minimal.yaml`
- `repos/noetl/ci/kind/config-no-ibkr.yaml`
- `repos/noetl/ci/kind/config-alt-ports.yaml`
- `repos/ops/ci/kind/config.yaml`
- `repos/ops/ci/kind/config-minimal.yaml`
- `repos/ops/ci/kind/config-no-ibkr.yaml`
- `repos/ops/ci/kind/config-alt-ports.yaml`

### 2) Local deployment automation now reports LAN endpoint
Updated ops playbooks to print preferred endpoint using detected local hostname (`<LocalHostName>.local`) with localhost fallback:

- `repos/ops/automation/infrastructure/kind.yaml`
- `repos/ops/automation/development/noetl.yaml`
- `repos/ops/automation/setup/bootstrap.yaml`
- `repos/ops/automation/bootstrap_full.yaml`

### 3) Fixture registration defaults to LAN hostname
Updated playbook fixture loader default host behavior:

- `repos/noetl/tests/fixtures/register_test_playbooks.sh`

New default behavior:
- `NOETL_HOST` env var if set
- else auto-detect local hostname and append `.local`
- else fallback to `localhost`

### 4) Bootstrap docs/scripts updated for consistency
Updated endpoint guidance in:

- `repos/noetl/ci/README.md`
- `repos/ops/ci/README.md`
- `repos/noetl/ci/bootstrap/bootstrap.sh`
- `repos/ops/ci/bootstrap/bootstrap.sh`
- `repos/ops/automation/ibkr/README.md` (kind mapping snippet)

## Required one-time action
Kind does not retroactively apply changed port mappings to an existing cluster.

Recreate cluster:

```bash
kind delete cluster --name noetl
noetl run automation/infrastructure/kind.yaml --set action=create
```

Then deploy/redeploy NoETL as usual.

## Verification checklist

1. Verify Docker bind is not loopback-only:

```bash
lsof -nP -iTCP:8082 -sTCP:LISTEN
```

Expected: listener on `*:8082` (or equivalent), not only `127.0.0.1:8082`.

2. Verify from host:

```bash
curl -f "http://$(scutil --get LocalHostName).local:8082/api/health"
```

3. Verify from another device on the same LAN:
- Open `http://<machine>.local:8082/api/health`

## Security note
Binding kind host ports to `0.0.0.0` exposes mapped services to the local network.
Use trusted LAN/network segments and host firewall controls as needed.
