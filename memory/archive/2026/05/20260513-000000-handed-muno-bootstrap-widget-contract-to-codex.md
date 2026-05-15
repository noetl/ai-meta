# Handed muno bootstrap + widget contract to Codex (trip-planner Round 4a/6a)

- date: 2026-05-13T00:00:00Z
- tags: trip-planner, adiona, muno, widget-contract, bootstrap, react, mui, typescript, vite, codex-handoff, round-4a, round-6a

## Round goal

Bootstrap `git@github.com:noetl/muno.git` (currently empty) as the
trip-planner project's home base. Single Codex round delivers:

- **Widget contract** — 23 template schemas + 1 envelope schema as
  canonical JSON Schema draft-07 at `muno/playbooks/widget-contract/`,
  plus the architecture doc at `muno/docs/architecture/widget-contract.md`.
- **Frontend skeleton** — React 18 + TS + Vite + MUI v6 + ajv +
  json-schema-to-typescript pipeline. Widget renderer validates
  envelopes against schemas and dispatches to STUB components that
  render payload-as-JSON inside an MUI Card. Round 6b replaces stubs
  with real Material rendering.
- **Project home base** — full structure per the scoping doc:
  `docs/` (architecture/deployment/auth/tutorial/runbooks), `memory/`
  (claude+codex subdirs), `.claude/`, project-scoped `scripts/`
  (memory_add, memory_compact, figma_fetch, build_widget_contracts),
  `AGENTS.md`, `CLAUDE.md`, `README.md`, `Dockerfile`, `nginx.conf`.
- **First commit pushed directly to muno main** (no PR — repo is
  empty; initial bootstrap commit).
- **`repos/muno` added as submodule under ai-meta** (locally committed
  by Codex; Kadyapam pushes ai-meta).

After this round:
- **Round 4b** — implement `muno/playbooks/itinerary-planner.yaml`
  (the LLM-driven hybrid-input agent). Independent.
- **Round 6b** — replace the stub widget components with real Material
  rendering. Independent.
- 4b + 6b run as PARALLEL Codex rounds; both code against the contract
  this round freezes.

## Why combine 4a + 6a

Strict sequential (Round 4 → Round 6) means muno's UI can't start
until the agent ships, even though the contract is the only handoff
between them. Combining the contract freeze with muno bootstrap unlocks
parallel 4b/6b execution: the agent codes against the JSON schemas;
the UI codes against the generated TS types. Both reference the same
source of truth in `muno/playbooks/widget-contract/`.

## Pre-handoff (DONE)

- `noetl/muno` repo exists, empty.
- No new GCP secrets — existing duffel-api-test / google-maps-widget-key
  / figma-access-token continue to serve.

## Architecture locks

- Closed catalogue of 23 templates + 1 envelope. AI emits one of the
  23; unknown types fall back to `bot_text`.
- Schemas use JSON Schema draft-07, `additionalProperties: false`,
  explicit `required` arrays. Versioned via `schema_version` field on
  the envelope.
- `ai_adjustments` block carries the bounded AI discretion: variant
  pick, emphasis slots, conditional banners, annotations. No invented
  fields.
- Frontend renderer validates with ajv before rendering. Invalid
  payload → fallback bot_text describing the issue (graceful, never
  crash).
- Build pipeline regenerates `src/contracts/widgets.ts` from schemas
  at `npm run build` time. Generated file IS committed for IDE
  go-to-definition.
- Widget components are STUBS in this round — `<pre>{JSON}</pre>` inside
  MUI Card. Round 6b replaces them.
- Theme placeholder Material colors. Figma-variable-driven theme
  arrives in Round 6b once we add `file_variables:read` to the
  Figma PAT.

## Bridge artefacts

- `bridge/inbox/delegated/20260513-000000-muno-bootstrap-widget-contract.task.json`
- `scripts/muno_bootstrap_widget_contract_msg.txt`

## Trigger prompt for Codex (paste after pushing)

```
Bootstrap noetl/muno as the trip-planner project home base. Single
Codex round: widget contract schemas (23 templates + envelope) +
React 18 + TS + Vite + MUI v6 frontend skeleton with schema-validating
widget renderer (stubs, not real components) + full project meta
(docs, memory, .claude, scripts) + initial push to muno main +
submodule add in ai-meta.

Bridge task: bridge/inbox/delegated/20260513-000000-muno-bootstrap-widget-contract.task.json
Prompt details: scripts/muno_bootstrap_widget_contract_msg.txt
Scoping doc: sync/issues/2026-05-12-trip-planner-app-scoping.md
Result file: bridge/outbox/20260513-000000-muno-bootstrap-widget-contract.result.json

Pre-handoff (DONE): noetl/muno repo exists, empty. No new GCP secrets.

Run all 7 phases per the bridge task. Architectural rules:
  - Single round, no splitting.
  - Initial push to noetl/muno main is direct (repo empty, no PR).
  - All 23 templates + envelope schema ship in this round.
  - Widget components are STUBS rendering JSON. Round 6b does real
    Material rendering.
  - npm run build regenerates src/contracts/widgets.ts from schemas;
    the generated file IS committed.
  - i18n + theme placeholders only.
  - ai-meta submodule add is local-only; Kadyapam pushes ai-meta.
  - No new GCP secrets.
  - No secrets / .env / node_modules committed.
  - If muno repo is non-empty: AMBER + STOP (don't overwrite).
```

## What's after this round

- **Round 4b** (LLM-driven itinerary agent) — fresh bridge round to
  implement `muno/playbooks/itinerary-planner.yaml`. Consumes
  mcp/firestore (Round 3 GREEN), mcp/duffel (Rounds 1+search round),
  mcp/google-places (Pattern C), mcp/amadeus (existing). Emits wire
  envelopes matching the schemas this round freezes.
- **Round 6b** (real Material widget components) — fresh bridge round
  to replace JSON stubs with Material implementations. Pulls Figma
  tokens via the figma-access-token PAT (needs `file_variables:read`
  scope added). Codes against the TS types generated this round.
- Then Round 5 (Google Calendar) + Round 7 (end-to-end tutorial).

## Related

- `sync/issues/2026-05-12-trip-planner-app-scoping.md`
- `memory/inbox/2026/05/20260512-235900-firestore-mcp-event-sourcing-green.md`
- `memory/inbox/2026/05/20260512-230000-duffel-stays-unavailable-round-2.md`
- `memory/inbox/2026/05/20260512-160546-duffel-test-orders-green.md`
- `repos/gui/package.json` (toolchain reference)
- https://json-schema.org/draft-07/schema
- https://github.com/bcherny/json-schema-to-typescript
- https://ajv.js.org/
- https://mui.com/material-ui/getting-started/
