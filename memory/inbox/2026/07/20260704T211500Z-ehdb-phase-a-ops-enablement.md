# EHDB integration Phase A — ops/runtime enablement SHIPPED+MERGED

Date: 2026-07-04 UTC

Executed Phase A from the EHDB↔NoETL handoff
(https://github.com/noetl/ehdb/wiki/Claude-Handoff-EHDB-NoETL-Integration).
Product code in `noetl/ops` only; ai-meta carries pointers + this note.

## What landed

- **noetl/ops#234** (merged, squash) — `e79b87eed9ec2178cf4a8e01b3bc3d613df9efcc`.
  Disabled-by-default, role-specific EHDB env in the Helm charts +
  a kind smoke Job.
- **ehdb wiki** `94f65fb1c14fe091e8eb7223fe27962753bae680` — Architecture
  page *Ops Env-Rendering Boundary* section + Roadmap Phase A = DONE.

## The design (control-plane vs data-plane env boundary)

`automation/helm/noetl` + `automation/helm/gateway` gained an
`ehdb.enabled: false` master switch (+ per-role `ehdb.roles.<r>.enabled`
opt-out). A shared `templates/_ehdb.tpl` renders role-specific env, and
the plane split is **hardcoded in the template keyed on client role**,
NOT values — an operator cannot leak a data-plane storage handle into a
control-plane role:

- server / api / gateway → `NOETL_EHDB_MODE=control_plane` +
  `NOETL_EHDB_CAPABILITIES=control_plane`, **never**
  `NOETL_EHDB_LOCAL_REFERENCE_LOG`.
- worker / playbook / system → `NOETL_EHDB_MODE=local_reference` +
  `NOETL_EHDB_LOCAL_REFERENCE_LOG=/opt/noetl/data/ehdb/local-reference.jsonl`.

Env var names match the already-merged `noetl.core.ehdb_contract`
feature-gated (disabled-by-default) contract in `noetl/noetl`
(pointer `f82ccb7f`).

## Validation (local kind-noetl, helm v4.1.3)

- `helm template` defaults → **byte-identical** diff vs baseline on BOTH
  charts (disabled = byte-neutral, no `NOETL_EHDB_*` anywhere).
- `helm template --set ehdb.enabled=true` → worker/worker-pool/projector/
  outbox = `local_reference` with log; server + gateway = `control_plane`
  with **no** log handle. Per-role opt-out verified.
- `helm lint` clean (disabled + enabled) both charts.
- kind smoke Job `ci/manifests/noetl/ehdb/smoke-job.yaml` (image
  `localhost/local/noetl:ehdb-helper-image-test`, `imagePullPolicy: Never`)
  → Job Complete, pod exit 0, deterministic summary
  `{"log_path": ".../local-reference.jsonl", ...all counts 0}`.

## Pointers

- ai-meta bumped `repos/ops` → `e79b87e`, `repos/ehdb-wiki` → `94f65fb`.
- Umbrella issue: noetl/ehdb#234 (stays OPEN; Phase A done, Phases B–G ahead).
- Next: **Phase B** — bounded worker/playbook readiness hook over
  `read_ehdb_local_reference_summary_from_env`, no gateway data access.
