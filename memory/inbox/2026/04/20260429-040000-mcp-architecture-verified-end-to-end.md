# MCP architecture verified end-to-end on kind v2.27.0

## Closed PRs (this session)

```
noetl/noetl#395  fix(catalog): YAML payload kind: is authoritative on register
noetl/noetl#396  chore(dsl): regenerate Playbook JSON schema from v10 Pydantic models
noetl/noetl#397  feat(catalog): validate Playbook/Agent payloads at register time
noetl/noetl#398  fix(catalog): preserve HTTPException status on /catalog/register
noetl/ops#15     feat(agents): kubernetes MCP lifecycle agent fleet + curated Mcp template (architecture phase 3)
noetl/ops#16     fix(agents): canonical NextRouter form for lifecycle agents
noetl/ops#17     fix(deploy): configurable podman machine name; skip-when-empty
```

PRs from earlier today (already in main when session started):

```
noetl/noetl#392  feat(server): MCP catalog resource lifecycle (architecture phase 1)
noetl/noetl#393  fix: Copilot pass-2 review follow-up on #392
noetl/noetl#394  feat(server): noetl-side check_playbook_access enforcement (architecture phase 2)
noetl/gui#16     feat(catalog): friendly playbook run dialog backed by /ui_schema (architecture phase 4)
noetl/gui#17     fix(catalog-run): Copilot pass-1 review follow-up on #16 (squash-merged with pass-2)
```

## Discovered (and resolved) along the way

- **`noetl catalog register` always sent `resource_type: Playbook`** even
  when the YAML declared `kind: Mcp`. Fixed server-side in #395 — the
  payload's `kind:` is now authoritative; the request parameter is a
  fallback hint.
- **The two hand-maintained DSL JSON schemas predated v10 entirely.**
  Both used the deprecated `next: -step:` list form and the old
  `call+args` step shape. Replaced with a single auto-generated
  `playbook.schema.json` (37,812 bytes) plus a regen script in #396.
  The two stale files are deleted.
- **Lifecycle agents passed catalog register but failed engine load.**
  The v10 `Step.next: NextRouter` rejected the `next: - step: end`
  list form; `PlaybookRepo.load_playbook_by_id` swallowed the Pydantic
  ValidationError as None and re-raised as the misleading "Playbook not
  found: catalog_id=...". Fixed both at the YAML side (#16, six files)
  and at the server side (#397 — register-time Pydantic validation).
- **The 422 from #397 was being wrapped as a 500.** Caught by the bare
  `except Exception` in `/catalog/register`. #398 catches HTTPException
  first and re-raises unchanged.
- **Deploy script hardcoded a `noetl-dev` podman machine** that not
  every dev environment has. #17 makes it configurable per workload
  knob; setting it to `""` skips the check entirely (colima / Docker
  Desktop / native podman / Linux).

## End-to-end verification (Codex, fresh kind cluster)

```
✅ Cluster bootstrapped: kind-noetl
✅ noetl pod running ghcr.io/noetl/noetl:v2.27.0
✅ Health check: {"status":"ok"}
✅ Catalog registration: 6 lifecycle playbooks as kind=playbook;
   MCP template as kind=mcp
✅ Step 7.1 - bad playbook → 422 with workflow.0.next + NextRouter
   (currently wrapped in 500 by the pre-#398 endpoint; #398 fixes it)
✅ Step 7.2 - good playbook → version 1 registered
✅ Step 8     - lifecycle/status → execution_id 615471140567252998
```

## Submodule pointer state in ai-meta

`b515a53 chore(sync): bump ops to 94d9ab9, noetl to b78064d7`

(b78064d7 is post-#398; 94d9ab9 is post-#17. The kind cluster is on
v2.27.0 which is pre-#398, so a redeploy is the prerequisite for the
422-instead-of-500 surface to be live.)

## Pending follow-ups

- Improve `playbooks` terminal listing (pagination + filter) — issue #37
- Mcp tab + Add-MCP wizard in the GUI (Phase 4 follow-up). With #395/#396/#397/#398 in place, the wizard has:
  - the canonical schema to validate user input against in real-time
  - a guarantee the catalog won't accept a malformed Mcp resource
  - the `mcp_kubernetes.yaml` template to seed from
- Optional: redeploy noetl on kind to v2.27.x (post-#398) so the bad-playbook smoke returns clean 422 instead of 500-wrapping-422.

Tags: noetl, ops, gui, mcp, phase-1, phase-2, phase-3, phase-4, dsl, schema, validation, kind, end-to-end
