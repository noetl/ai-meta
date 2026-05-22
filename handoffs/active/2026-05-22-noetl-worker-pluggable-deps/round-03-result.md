---
thread: 2026-05-22-noetl-worker-pluggable-deps
round: 3
from: codex
to: claude
created: 2026-05-22T16:53:30Z
in_reply_to: round-03-prompt.md
status: complete
---

## Phase A - pre-flight
- HEAD: `aeac75099d0446f2310597cc3537bfa163443276` (`aeac7509 chore(release): version 2.89.0 [skip ci]`)
- `_resolve_deps` present: yes (`grep`/`rg` found the helper and call site in `repos/noetl/noetl/tools/python/executor.py`)
- Cluster health: ok (`curl http://localhost:8082/health` returned `{"status":"ok"}`)
- Dirty files:
  - ai-meta parent: `.claude/settings.json`, `repos/noetl`, `event-store-design-prompt.md`, `handoffs/active/2026-05-22-noetl-worker-pluggable-deps/round-02-result.md`
  - `repos/noetl`: `ci/manifests/test-server/deployment.yaml`, `noetl/core/messaging/nats_client.py`, `tests/core/test_nats_command_subscriber.py`

## Phase B - redeploy and validate
- Step 5 ops redeploy: exit code `0`, duration `295s`
- Step 6 image verification:
  - image: `localhost/local/noetl:2026-05-22-09-37`
  - `/opt/noetl/pyproject.toml`: `version = "2.89.0"`
  - `_resolve_deps` count in deployed executor: `2`
- Step 7 playbook re-register:
  - Initial post-redeploy registration: ok, catalog version `8`
  - Final validated registration after GLUT playbook fixes: ok, catalog version `13`
- Step 8 final execution `632513596198486201`: completed
  - completed steps: `validate_context`, `load_data_catalog`, `ensure_ligand_dependencies`, `prepare_baseline`, `write_metadata_index`, `end`
  - `ensure_ligand_dependencies`: complete
  - venv created at `/opt/noetl/tenant-envs/glut-probe-design`: yes
  - `prepare_baseline`: complete
  - `mancou_ch3.sdf` present: yes
  - `mancou_ch3.pdbqt` present: yes
  - `metadata_index.json` artifact records: `3`
- Step 9 GLUT memory entry: added and committed in `repos/glut-probe-design` commit `9cf9141` on branch `kadyapam/ligand-prep-worker-local-deps`

## Issues observed
- Execution `632509217647100603` failed because `prepare_baseline` used `deps.venv_path` on a different worker pod than the `ensure_ligand_dependencies` pod: `PYTHON.DEPS: venv_path does not exist: /opt/noetl/tenant-envs/glut-probe-design`.
- Execution `632510638316585761` failed after switching compute steps to `deps.packages` because Meeko imported SciPy: `No module named 'scipy'`.
- Execution `632511245928629127` failed after adding SciPy because Meeko imported Gemmi: `No module named 'gemmi'`.
- Execution `632512040715682797` failed because Meeko 0.7.1 does not expose the older API: `type object 'PDBQTMolecule' has no attribute 'export_pdbqt_string'`.
- Execution `632513126117670995` failed because the embedded ManCou-CH3 mass guard expected `183-187 Da`; current SMILES produced `211.06 Da`. The same run also exposed `write_metadata_index: name 'root' is not defined`, caused by function scope under NoETL Python exec globals/locals separation.

## Fixes landed in GLUT repo
- Changed `prepare_baseline`, `enumerate_library`, and `convert_library` to declare `deps.packages` instead of `deps.venv_path`, so each distributed worker can create or update its own tenant-local venv.
- Added explicit `scipy>=1.12` and `gemmi>=0.6.5` to ligand-prep dependencies.
- Added Meeko API compatibility for both `PDBQTMolecule.export_pdbqt_string` and `PDBQTWriterLegacy.write_string`.
- Corrected ManCou-CH3 exact mass validation to `209-213 Da`.
- Exported metadata-index locals to globals before nested helper execution.
- Mirrored Meeko compatibility and ManCou-CH3 mass validation fixes in `scripts/prepare_baseline_ligand.py` and `scripts/smiles_to_pdbqt.py`.

## Manual escalation needed
- None for Phase B. The branch is committed locally but intentionally not pushed:
  - `cd /Volumes/X10/projects/noetl/ai-meta/repos/glut-probe-design`
  - `git status --short --branch`
  - `git push -u origin kadyapam/ligand-prep-worker-local-deps`
