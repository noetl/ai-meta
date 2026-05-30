# Deployment Validation Rule

Any change that ships in a container image — `noetl-server`,
`noetl-worker`, `gateway`, `gui`, or any image built via
`gcloud builds submit` / Docker / Cloud Build — MUST be validated
on the **local kind cluster** before rolling out to GKE.

## The validation order

```
1. Local cargo / pytest checks           (mandatory; existing CI gate)
2. Build the container image locally     (or pull the image just built by Cloud Build)
3. Load the image into the local kind    (kind load docker-image)
4. Apply the manifests / helm upgrade    (against context kind-noetl)
5. Smoke-test the changed surface        (curl the API, run a playbook, etc.)
6. Only then: Cloud Build + GKE Helm     (production rollout)
```

GKE is the production path; kind catches the bulk of regressions
cheaply — wrong configmap key, missing env var, broken liveness
probe, removed file referenced by a Dockerfile COPY, etc.

## Setup expected to be in place

- **Podman machine `noetl-dev`** running (`podman machine list`
  should show `Currently running`).
- **Kind cluster `noetl`** running (`kind get clusters` shows
  `noetl`; `kubectl --context kind-noetl get nodes` returns a Ready
  control-plane).
- **Port mappings** per `repos/noetl/ci/kind/config.yaml`
  (NoETL Server `localhost:8082`, Gateway API `localhost:8090`,
  Postgres `localhost:54321`, etc. — full table in
  `repos/noetl/CLAUDE.md`).
- **KEDA** pre-installed in the cluster (operator + admission
  webhook + metrics apiserver).

## How to validate (recipe)

The cluster-side recipe lives in
[`repos/ops/automation/development/noetl.yaml`](https://github.com/noetl/ops/blob/main/automation/development/noetl.yaml).
Preferred entry point from `repos/ops`:

```
noetl run automation/development/noetl.yaml --runtime local \
  --set action=redeploy --set noetl_repo_dir=../noetl
```

This builds the image with the local `repos/noetl` working tree,
loads it into the kind cluster, and rolls the deployments.

## Exceptions

The policy does not apply to:

- Documentation-only changes (wiki, docs, README, comments).
- Dev-only scaffolds — e.g. a workspace dependency added to a
  crate that isn't yet wired into the binary's runtime behaviour
  (R-1.1 PR-2c-1 is the canonical example: it added `noetl-tools`
  as a dependency of `noetl-executor` but no CLI call site changed,
  so the binary's runtime is identical).
- Pointer bumps in `ai-meta` for submodule SHAs that have already
  passed their own kind validation in the owning repo's CI.

When in doubt: validate on kind anyway.  The cost is ~3 minutes;
the cost of a broken GKE rollout is hours.

## Connecting back to the chain

This rule pairs with:

- [`ops-deploy.md`](ops-deploy.md) — names the kind validation
  playbook (`repos/ops/automation/development/noetl.yaml`).
- [`commit-conventions.md`](commit-conventions.md) — kind
  validation is part of the substantive-change definition for
  Rule 1 of [`issue-tracking.md`](issue-tracking.md).
- [`wiki-maintenance.md`](wiki-maintenance.md) Rule 1b — every
  pointer bump checks the wiki AND now also checks that kind
  validation happened upstream.

## History

Made durable 2026-05-30 after a session-level instruction:
"Also when you build deployment - test it in local podman kind
cluster."  The infrastructure (Podman machine, kind cluster,
KEDA, port mappings) was already in place; the rule codifies the
expectation that it gets used before any GKE roll-out.
