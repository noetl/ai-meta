# NoETL EHDB helper image packaging

Date: 2026-07-04 UTC

`noetl/noetl#685` merged as
`2a73a0050990311329150c7b449c5f00b8e2255d`, closing
`noetl/noetl#684`.

The NoETL dev and pip Dockerfiles now build `ehdb-local-reference` from
pinned `noetl/ehdb` ref `0dc2016f4b692d3d868ccbc3918900962a880ca1`,
copy only the compiled helper binary into the final runtime image, and
run `ehdb-local-reference --help` during the image build.

Scope boundary: this is packaging for bounded worker/playbook
local-reference helper execution. It does not add gateway/API/server
data-plane storage access, public routes, GKE rollout, persistent
per-tenant processes, or replacement of PostgreSQL/NATS/object stores.

Validation:

- `pytest` focused EHDB suite: 60 tests.
- `pytest` nearby runtime suite: 109 tests.
- `compileall` over EHDB integration modules and smoke script.
- `git diff --check`.
- Podman `linux/arm64` image build for `docker/noetl/dev/Dockerfile`.
- Container runtime smoke: helper on PATH plus
  `scripts/smoke_ehdb_local_reference_summary.py`.
- Local kind validation: image archive loaded into `kind-noetl`; one-off
  `ehdb-helper-smoke` Job ran the same summary smoke with
  `imagePullPolicy: Never`.

Pointer state: `repos/noetl` should point at
`2a73a0050990311329150c7b449c5f00b8e2255d`.
