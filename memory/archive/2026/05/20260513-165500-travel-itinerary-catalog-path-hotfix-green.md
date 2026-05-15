# 2026-05-13 — Travel itinerary catalog path hotfix GREEN

Context: after the shell submit/menu hotfix deployed, Kadyapam submitted `find tickets from sfo to paris` and the Travel UI reached NoETL but failed with:

`Execute catalog entry failed (resource_kind=playbook): 404 Not Found - {"detail":"Executable catalog entry not found: playbooks/itinerary-planner.yaml"}`

Diagnosis:
- The Travel chat shell used the YAML file path `playbooks/itinerary-planner.yaml`.
- The Muno itinerary playbook metadata registers the executable catalog path as `muno/playbooks/itinerary-planner`.
- The existing smoke helper also executes `muno/playbooks/itinerary-planner`, confirming the catalog name.

Fix shipped in `noetl/travel#25`:
- Changed `src/components/shell/ChatThread.tsx` to execute `muno/playbooks/itinerary-planner`.
- Updated the NoETL client test fixture to match the registered catalog path.

Validation:
- Local `npm run test` passed: 8 files, 18 tests.
- Local `npm run type-check` passed.
- Local `npm run smoke:widgets` passed for 24 widget envelopes.
- Local `npm run build` passed.
- PR checks passed.
- Cloudflare Pages main deploy `25833128845` completed successfully for merge SHA `0496299`.

State:
- `repos/travel` now points at `0496299` locally in `ai-meta`.
- Browser retest target: hard-refresh `https://travel.mestumre.dev/`, sign in, submit `find tickets from sfo to paris`, and confirm the error no longer mentions missing `playbooks/itinerary-planner.yaml`.
