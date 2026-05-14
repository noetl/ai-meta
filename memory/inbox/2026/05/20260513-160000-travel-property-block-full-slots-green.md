# 2026-05-13 — Travel PropertyBlock full slot surfacing GREEN pending browser smoke

Context: Kadyapam reported that after the catalog-path hotfix, submitting a prompt reached a new generic browser error: `Request failed with status code 404`. Claude also handed off Round 11: make the Travel right pane surface every captured trip slot, not just the sample destination/date `property_block`.

Diagnosis:
- The submit path was now reaching the gateway and starting execution, but `ChatThread` then polled `GET https://gateway.mestumre.dev/api/executions/{id}`.
- The Cloudflare gateway surface exposes auth, GraphQL, and SSE callbacks, but not the full NoETL REST execution API. Anonymous probes to `/api/executions/{id}` and `/api/executions/{id}/status` returned HTTP 404 from the gateway surface.
- The GUI already solves this shape by opening `/events`, passing `clientId` into the GraphQL `executePlaybook` mutation, and resolving from `playbook/result` SSE callbacks.
- `RightPane` was still rendering the static sample `property_block` envelope from `sampleEnvelopes.json`.

Fix shipped:
- `noetl/travel#26` merged at `e27f28a`.
- `src/api/noetlClient.ts` now mirrors the GUI gateway callback flow: connect to SSE, capture `clientId`, pass it into `executePlaybook`, and resolve the final playbook result from `playbook/result`.
- `src/components/shell/ChatThread.tsx` accepts callback payloads with `data.render` and `data.final_slot_state`, avoiding the gateway REST poll in production.
- `src/App.tsx` stores latest `final_slot_state` and passes it into the right pane.
- `src/components/shell/RightPane.tsx` renders Region, Dates, Party, Star rating, Budget, Bed type, and Amenities as a `property_block`, reusing `formatParty`.
- `src/components/shell/RightPane.test.tsx` asserts all seven slots render.
- `noetl/docs#71` merged at `785e79c`, updating Tutorial 08 and removing the stale right-pane limitation.

Validation:
- `repos/travel`: `npm run test` passed (9 files, 19 tests).
- `repos/travel`: `npm run type-check` passed.
- `repos/travel`: `npm run smoke:widgets` passed.
- `repos/travel`: `npm run build` passed.
- `repos/docs`: `npm run build` passed.
- Travel PR checks and Cloudflare preview passed.
- Travel production Cloudflare Pages deploy `25834193886` passed.
- Docs production Cloudflare Pages deploy `25834194053` passed.

State:
- `repos/travel` pointer should move to `e27f28a`.
- `repos/docs` pointer should move to `785e79c`.
- Round status is GREEN pending Kadyapam browser smoke because the live session token is browser-local.

Browser smoke:
- Hard-refresh `https://travel.mestumre.dev/`, sign in, submit `find ticket from sfo to NY next week`, and confirm the generic 404 is gone.
- Verify the right pane updates captured slots as the agent returns `final_slot_state`.
