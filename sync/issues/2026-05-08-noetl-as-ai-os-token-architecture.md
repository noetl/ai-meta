# NoETL-as-AI-OS: token-based architecture and the dynamic widget surface

**Date filed**: 2026-05-08
**Status**: Captured / staged roadmap
**Origin**: User vision — "NoETL GUI as AI operating system interface"
**Related**:
- `architecture/agent_orchestration.md` (current event-sourcing model)
- `architecture/mcp_catalog_architecture.md` (Mcp as catalog kind)
- `architecture/playbook_as_mcp_server.md` (MCP-as-playbook pattern)
- `sync/issues/2026-05-06-future-vertex-ai-gemini-mcp-pointer-swap.md` (pointer-swap precedent)

## The vision

NoETL becomes the runtime for an AI operating system. The OS analogy
maps cleanly onto components NoETL already has:

| OS concept | NoETL component | Notes |
|---|---|---|
| System call interface | Catalog + DSL | Playbooks invoke catalog items by path + version |
| Process | Execution | Has lifecycle, events, terminal status |
| Message bus | Event source (NATS JetStream) | Already in place |
| Shared memory | NATS K/V + Object Store | Sessions, large payloads, references |
| Filesystem | Catalog (PG-backed) | Versioned, content-addressed by path |
| Standard I/O | Step args + step result | Inputs/outputs of each step |
| Inter-process call | `tool: agent` / `tool: playbook` | Already validated through Gap 1 + 4.1 |
| Window manager / shell | GUI + terminal-console | Currently separate UXes; want them unified |
| Daemon / service | MCP servers (in-cluster + cloud) | Pointer-swappable per deployment mode |

What's missing today:

1. **Widget as a first-class catalog kind.** Playbook outputs are
   plain JSON. The GUI has to interpret them ad-hoc. There's no way
   for a playbook author to say "render this result as a chart, a
   table, a markdown doc, a confirmation dialog, a progress bar."
2. **Kind-aware catalog UX.** The GUI's catalog view is Playbook-only.
   Mcp and Credential kinds are managed elsewhere or not at all.
   Adding Widget without first generalizing the catalog UX would
   produce a fourth disjoint surface.
3. **Token unification.** The pieces — Playbooks, Mcp servers, Events,
   Commands, soon Widgets — are all addressable by stable identifiers
   (catalog path + version, execution_id, event_id, command_id), but
   they're not modeled as a single abstraction. The vision: every
   addressable unit is a *token*. Tokens compose. A playbook is a
   token; an event is a token referencing an execution token; a
   widget is a token; a command is a token wanting state-change.
4. **Unified terminal-and-window UX.** Today there's a GUI (visual,
   click-to-run) and a terminal console (text, type-to-run). The user
   chooses one or the other per session. The vision: the same UX
   surface accepts both modalities — type a token reference and the
   widget for that token renders inline; click a widget and you can
   pipe its output into the next step text-style.

## The token abstraction precisely

A **token** is any addressable unit in the NoETL universe. Concretely:

```
TokenRef = (kind, path, version) | (event, execution_id, event_id) | …
```

Existing tokens (already addressable):

- **Catalog token**: `(Playbook | Mcp | Credential | Widget, path, version)` — backed by the catalog DB.
- **Execution token**: `(Execution, execution_id)` — backed by the events table.
- **Event token**: `(Event, execution_id, event_id)` — within an execution.
- **Command token**: `(Command, command_id)` — pending intent to change state.

New token kinds the vision calls for:

- **Widget token**: `(Widget, path, version)` — first-class catalog
  entry that defines a renderable visual. Same lifecycle as Playbook
  (register, version, deploy via catalog).
- **Reference token**: a value carried in a step's result that is
  itself a token reference. Already exists in `result.context` as
  `reference: { _ref: <id> }` for large-payload externalisation.
  Generalising this for widgets means a step can return
  `{ render: { _ref: "widget/<path>", with: { ... } } }` and the
  GUI knows to materialize that widget reference.

Operationally this means: every NoETL state transition is a movement
of tokens. Events are tokens carrying state. Commands are tokens
carrying intent. Playbooks are tokens being executed. Widgets are
tokens being rendered. The catalog is a **token registry**, the
event source is a **token bus**, the GUI is a **token visualizer**.

## The widget contract (proposed)

A `Widget` catalog kind, defined like an existing Pydantic model
alongside `Playbook` and `Mcp`:

```yaml
apiVersion: noetl.io/v2
kind: Widget
metadata:
  name: diagnosis_summary
  path: widgets/diagnosis_summary
  description: |
    Renders an error diagnosis card with category, confidence,
    suggested action, and a "view full execution" link.
  tags: [widget, diagnosis, ai-os]

spec:
  schema:                    # input shape the widget accepts
    type: object
    required: [diagnosis]
    properties:
      diagnosis:
        type: object
        required: [category, confidence, root_cause, suggested_action, source]

  render:
    type: react              # react | markdown | mermaid | sse-stream
    component: DiagnosisCard # name resolvable in the GUI's widget registry
    fallback: markdown       # what to render if React component is unavailable
    fallback_template: |     # Jinja over the input shape
      ## Diagnosis: {{ diagnosis.category }} (confidence {{ diagnosis.confidence }})
      **Root cause**: {{ diagnosis.root_cause }}
      **Suggested**: {{ diagnosis.suggested_action }}

  refresh:
    via: event               # event-driven (re-render on new events) | polling | static
    listen: ["execution.{{ execution_id }}.events.diagnose.command.completed"]
```

Steps reference widgets by token in their results:

```yaml
- step: extract_envelope
  tool: python
  code: |
    result = {
      "smoke_status": "ok",
      "render": {
        "widget": "widgets/diagnosis_summary",   # token ref to a widget
        "with": {
          "diagnosis": diagnosis,
        },
      },
    }
```

The GUI sees `result.render.widget` as a token reference, fetches the
widget definition from the catalog (cached by path+version),
renders the React component (or falls back to markdown), and the
playbook's result becomes a live, dynamic visual.

This generalises naturally to chat-style "smart messages": the AI
agent can return widget tokens describing how its output should
render — confirmation buttons, cards, charts, embedded code blocks
with run-button affordances.

## Catalog UX as the entry point

Before Widget-as-kind ships, the catalog UX needs to grow into a
kind-aware surface, otherwise we just paper a new kind onto a
Playbook-shaped UI:

- **Kind tabs**: Playbook | MCP | Credential | Widget. Each tab is a
  list view of the same shape (path, latest version, description,
  tags, last-modified).
- **Search across kinds**: free-text query falls back to fuzzy match on
  path + description + tags. Kind filter narrows the result set.
- **Version handling**: by default, each path collapses to its
  latest version. "Show all versions" toggle expands to a flat list
  with version chip per row. Per-path detail view shows full version
  history with diff between adjacent versions.
- **Description + navigation**: card view with kind icon (Playbook = ▶,
  MCP = 🔌, Credential = 🔑, Widget = 🪟), description preview,
  tag chips. Path becomes breadcrumbs (e.g. `automation > agents >
  troubleshoot > diagnose_execution`) with each segment clickable to
  filter.
- **Related items**: each detail view shows references — playbooks
  that invoke this MCP, executions that ran this playbook, widgets
  that render outputs of this playbook.

## Terminal-window unification

The terminal-console (`repos/gui/src/components/NoetlPrompt.tsx`) and
the GUI's catalog/execution views currently share state but render
disjointly. The unification target:

- **Token cursor**: the prompt accepts both natural-language queries
  ("show me the latest spike runs") and token references
  (`exec 620539...`, `playbook tests/spike/spike_e2e_test`,
  `widget widgets/diagnosis_summary`). Token references inline-expand
  into rendered widgets.
- **Click-to-tokenize**: clicking a catalog item drops its token
  reference into the prompt buffer; the next thing you type
  contextualizes to that token (e.g. click a playbook → type
  `--payload '{...}'` → enter to execute).
- **Streaming widgets in prompt history**: a SSE-backed widget can
  live-update inline in the prompt history as new events arrive.
  No need to switch to a separate execution view to watch progress.

This composes well with the architecture: the prompt becomes the
shell, widgets become the rendering primitive, the catalog becomes
the autocomplete source, and the event bus becomes the live-update
feed.

## Quantum cloud framing

The user named this as the foundation of "quantum cloud." I read that
as: when the runtime is purely token-based and content-addressed,
the location of any token (in-memory, in-cache, in-cluster, in-GKE,
in-some-other-cluster) becomes a deployment detail rather than an
architectural one. Tokens are content-addressed; their resolution
goes through the catalog (registry); the execution runtime can fetch
a token from any addressable backing store. This is the same
architectural shift containerization made for "what runs where" —
applied to "what is referenced where."

I won't pretend this is a small leap. The piece that gets us there
in stages is the token unification: every kind first-class, every
reference symmetric, every state transition modeled as token
movement. The rest follows.

## Staged roadmap

Each round is a coherent, shippable unit. Don't try to do the whole
thing in one sweep.

### Round 1 — Catalog UX kind-aware + Widget kind defined

- noetl: add `Widget` to the catalog kind enum (Pydantic model).
  Mirrors `Mcp` shape — name, path, description, tags, spec block.
- ops: add `repos/ops/automation/agents/widgets/diagnosis_summary.yaml`
  as the canonical example (renders the diagnose envelope from
  Gap 4.1). Markdown render type only for now.
- gui: refactor `Catalog.tsx` from playbook-only to kind-aware. Tabs
  for Playbook | MCP | Credential | Widget. Version collapse with
  expand toggle. Search across path + description + tags.
- docs: introduce the Widget kind concept in
  `architecture/widget_kind.md` (new). Cross-link from
  `mcp_catalog_architecture.md` and `agent_orchestration.md`.

### Round 2 — Widget rendering in NoetlPrompt terminal (no noetl python changes)

**Architectural correction from user feedback (2026-05-07):** widgets
are NOT a noetl-side Pydantic kind. They are pure GUI/data
references — either (a) URL pointers to CDN-hosted assets, (b)
inline templates rendered from playbook output, or (c) inline
content (markdown, code blocks, charts) carried in
`result.render.*`. The reference repo for the rendering pattern is
[`mlflowio/chatui`](https://github.com/mlflowio/chatui)'s
`MessageContent.tsx`, registered as a read-only submodule at
`references/chatui` (see AGENTS.md for the read-only directive).

**Wire-shape decision** (after reading the chatui reference): we
adopt chatui's discriminator convention literally — every widget is
`{ type: "app:<name>", args: {...} }`, **with the args field names
preserved verbatim from chatui**. This keeps the playbook-side
JSON shape and the GUI-side dispatcher symmetric, so a future port
of additional widget kinds from chatui is a pure copy job.

The adaptation target is the existing terminal-style prompt at
`repos/gui/src/components/NoetlPrompt.tsx`. Each `PromptEntry`
gains an optional `render: WidgetContent` field that the renderer
interprets, where `WidgetContent` is the discriminated union from
`repos/gui/src/components/widgets/types.ts`. The full set of
supported kinds (32 chatui kinds + 3 NoETL extensions) ships in
round 2 — see `repos/docs/docs/gui/widgets.md` for the per-kind
contract table.

Display kinds: `app:markdown` (`{text}`), `app:title`, `app:text`,
`app:horizontalline`, `app:picture` (`{imageUrl|imageBase64,...}`),
`app:icon`, `app:profilepicture`, `app:statusbar`,
`app:alert` (`{message, variant?}`), `app:tooltip`,
`app:infotable`, `app:infogrid`, `app:grouped_table`,
`app:table` (`{size?, data: string[][]}`), `app:recordtable`,
`app:filedisplay`.

Layout kinds: `app:row` / `app:column` (`{children, gap?, align?,
justify?}`), `app:container`, `app:carousel`, `app:expandable`,
`app:info_block`.

Interactive kinds (emit through `onWidgetEvent`): `app:button`,
`app:calendar`, `app:dropdown`, `app:radio`, `app:checkbox`,
`app:input`, `app:form`, `app:customform`, `app:quiz`,
`app:draganddrop`.

NoETL extensions: `app:code`, `app:iframe`, `app:link`.

Playbook authors emit widget references in their step outputs:

```yaml
- step: extract_envelope
  tool: python
  code: |
    result = {
      "smoke_status": "ok",
      "render": {
        "type": "app:markdown",
        "args": {
          "text": f"## Diagnosis\n**Category:** {diagnosis['category']}\n...",
        },
      },
    }
```

The GUI's prompt renderer sees `result.render` in the step's output
(or events thereof) via `extractAgentRender`, dispatches by `type`
to the matching `App<Kind>` component, and renders inline beneath
the textual report. Unknown `type` values fall through to a small
"unsupported widget" surface that still shows the JSON so a
playbook author can debug.

**Round 2 deliverables (shipped 2026-05-08):**

- gui: `repos/gui/src/components/widgets/` — new module containing
  `WidgetRenderer.tsx` (switch dispatcher + class ErrorBoundary,
  no `react-error-boundary` dep), `types.ts` (the discriminated
  `WidgetContent` union), and 35 widget components — every chatui
  `app:*` widget plus three NoETL extensions:
    - **Display**: AppMarkdown, AppText, AppTitle, AppHorizontalLine,
      AppPicture, AppIcon, AppProfilePicture, AppStatusBar, AppAlert,
      AppTooltip, AppInfoTable, AppInfoGrid, AppGroupedTable,
      AppTable, AppRecordTable, AppFileDisplay
    - **Layout**: AppRow, AppColumn, AppContainer, AppCarousel,
      AppExpandable, AppInfoBlock
    - **Interactive**: AppButton, AppCalendar, AppDropdown, AppRadio,
      AppCheckbox, AppInput, AppForm, AppCustomForm, AppQuiz,
      AppDragAndDrop
    - **NoETL extensions**: AppCode, AppIframe, AppLink
- gui: `AppMarkdown` ships a tiny dependency-free markdown renderer
  (headings, paragraphs, lists, links, fenced code, inline emphasis) —
  no `react-markdown` dep added. HTML is escaped before formatting.
- gui: `AppIframe` defaults to `sandbox="allow-scripts allow-same-origin"`
  and `referrerPolicy="no-referrer"` so CDN-hosted widgets cannot
  navigate the host or leak referrers.
- gui: `repos/gui/src/components/NoetlPrompt.tsx` — `PromptEntry`
  gains `render?: WidgetContent`; the result block dispatches to
  `WidgetRenderer` when `render` is present.
- gui: `NoetlPrompt.handleWidgetEvent` — bridges chatui's
  `WidgetMessageEvent` (`{event, key, value}`) into the prompt:
  `key === "command"` invokes `runCommand(value)`,
  `key === "navigate"` navigates to a route, anything else prints
  to history. Round 3 will widen this — e.g. AppForm submit values
  could become payload for the next playbook the user runs.
- gui: `repos/gui/src/services/agentResult.ts` — adds
  `extractAgentRender()` that walks `execution.result` then
  `events[].result` / `events[].context` looking for the first
  `{render: {type, args}}` shape (capped at depth 4). Used by
  the `report <execution_id>` command to surface widgets inline.
- docs: `repos/docs/docs/gui/widgets.md` — guide for embedding a
  widget in playbook output (the `result.render` contract,
  per-kind contract table, security notes for `app:iframe`,
  example of triggering prompt commands from `app:button`).
- ai-meta: `references/chatui` registered as read-only submodule
  (`submodule.update=none`, `submodule.ignore=all`). AGENTS.md
  documents the read-only directive for `references/<name>`.
- typescript: `npx tsc --noEmit` passes clean across repos/gui.

NO noetl python changes. NO catalog kind changes. The widget is
just a JSON-shape contract on step outputs. This makes future
expansion (CDN-hosted iframes, server-rendered templates) purely a
GUI evolution.

**Round 2.x follow-ups (next sub-passes):**

- gui: surface `extractAgentRender` in the additional report-style
  surfaces — `runMcpAgent`, `runKubernetesCommand`,
  `runGenericMcpTool` — so widget-emitting playbooks render their
  widgets in any prompt path, not just `report`.
- gui: form-submit semantics — let `app:form` / `app:customform`
  submit values seed a `run <playbook>` payload through the prompt.
- gui: add CSS for the `noetl-widget*` class hooks (currently
  inline-styled where it matters; the class hooks are reserved for
  future themed overrides).
- gui: lazy-load heavier widget groups (antd Carousel, DatePicker,
  Form set) — the round-2 deploy report flagged the bundle delta
  at +191 KB gzip vs the 60 KB threshold.

### Round 2 deployment notes (2026-05-08, RED → unblock-in-flight)

Codex shipped the round-2 deploy task and reported RED:
`bridge/outbox/20260508-064720-deploy-widget-renderer-round-2-local.result.json`.
The GUI build, PR, release (v1.8.0), and local kind rollout all
succeeded. The blocker was at the noetl projection layer — both
synthetic smokes (`622377612446270148` widget tree, `622377613679395529`
unsupported widget) persisted only `render.type` and dropped
`render.args` before the GUI could read them.

Codex correctly diagnosed the path:
`repos/noetl/noetl/worker/nats_worker.py:_extract_control_context`.
The function has an explicit allow-path for `error.diagnosis`
(noetl#417, v2.37.1, sha 4a4f9f6) that recursively preserves nested
content via `_preserve_recursive_control_value` (max_depth=8); no
parallel allow-path existed for `render`.

Claude shipped the symmetric carve-out: when `key_str == "render"`
and `child.get("args")` is a dict-or-list, the same recursive
preserver is invoked. Five new tests in
`tests/worker/test_control_context_projection.py` mirror the
existing four `error.diagnosis` tests. The fix logic was
inline-verified in the sandbox (without the full noetl dep chain)
and all assertions pass.

The unblock is handed to Codex as
`bridge/inbox/delegated/20260508-074315-noetl-render-projection-allow-path.task.json`
— pytest → noetl PR → semantic-release → local kind redeploy of
noetl-server + noetl-worker → replay BOTH smokes to GREEN with full
nested widget tree visible in the browser → ai-meta pointer bump.
The pending aeff434 ai-meta commit (gui + docs gitlink bumps from
round 2) stays as-is; the noetl bump lands on top.

### Round 3 — Terminal-window unification (token cursor)

- gui: extend `NoetlPrompt.tsx` to accept token references
  (`playbook <path>`, `exec <id>`, `widget <path>`). Inline expansion.
- gui: catalog rows become click-to-tokenize.
- gui: streaming widgets receive SSE events and re-render inline.

### Round 4 — Token reference graph + related items

- noetl-server: events table grows a `token_refs` column extracted
  at write time (which catalog tokens did this event reference).
- gui: detail views grow "related items" sections backed by
  token_refs queries. Playbook detail shows recent executions;
  MCP detail shows playbooks that import it; Widget detail shows
  executions that rendered it.

### Round 5+ — Token addressability beyond local cluster

- The "quantum cloud" piece. Open questions:
  - Token URIs across clusters (`noetl://gke-us-central1/playbook/...`)
  - Cross-cluster catalog federation (do we replicate or proxy?)
  - Trust model for cross-cluster token resolution
- Filed for design pass once rounds 1-4 are operational.

## Open design questions for round 1

- **Widget Pydantic model**: how strict is the schema? Operators want
  freedom to define renderers; we want enough validation that bad
  widgets don't bring down the GUI. Lean toward strict schema with
  a `render.type: custom` escape hatch for advanced cases.
- **Widget render registry**: where does the GUI know that
  `DiagnosisCard` resolves to a real React component? Two options:
  (a) static registry compiled into the GUI bundle (only widgets
  shipped with the GUI render via React; others fall back to
  markdown), (b) dynamic component loading via federated modules
  (more flexible; more attack surface). Recommend (a) for round 1,
  evaluate (b) if needed in round 3.
- **Catalog kind tabs vs unified**: tabs are easier to navigate and
  match user mental model. Unified-with-filter is more "search-like."
  Start with tabs, add a unified search overlay later.
- **Version collapse default**: latest-only or all? Recommend
  latest-only with explicit "show all versions" toggle. Most users
  most of the time only care about the latest; version history is
  the audit/debug surface.

## Effort estimate

- Round 1: ~3-4 days (1 noetl PR, 1 ops PR, 1 gui PR, 1 docs PR)
- Round 2: ~2-3 days
- Round 3: ~3-4 days (terminal-window unification is real UI work)
- Round 4: ~2-3 days
- Round 5+: design pass first; effort TBD

This is multi-week work, not a single round. The vision is real; the
delivery is staged.

## When to start

The user has already kicked round 1 with this filing. The first
bridge task is the kind-aware catalog UX + Widget kind definition.
Subsequent rounds chain off it.
