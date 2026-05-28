# Wiki Maintenance Rule

NoETL has **three wikis**, each pinned to its own repository:

- **<https://github.com/noetl/noetl/wiki>** — application
  reference: Python API, DSL semantics, core architecture.
  Mirrors `noetl/noetl/`. Lives at `repos/noetl-wiki`.
- **<https://github.com/noetl/ops/wiki>** — operational
  reference: Kubernetes manifests, Helm install recipes,
  deployment playbooks, infrastructure tuning. Mirrors
  `noetl/ops/`. Lives at `repos/noetl-ops-wiki`.
- **<https://github.com/noetl/travel/wiki>** — developer
  reference for the travel SPA as the worked example of a
  domain-specific application built on NoETL (widget
  contract, orchestrator playbook walkthrough, gateway
  integration, fork-for-your-domain guide). Mirrors
  `noetl/travel/`. Lives at `repos/noetl-travel-wiki`.

This rule keeps documentation coverage growing in **lockstep with the
code** rather than as a separate sweep that drifts toward stale.

## Rule 0 — pick the right wiki

When adding or updating documentation:

- **Python API, DSL, core architecture, replay semantics, event
  shape, etc.** → `noetl/noetl` wiki.
- **Manifests, Helm charts, kubectl recipes, deployment
  automation playbooks, cluster-side install/verify/tuning** →
  `noetl/ops` wiki.
- **Domain-SPA patterns built on NoETL** (widget contract,
  per-domain orchestrator playbooks, SPA shell, gateway
  integration patterns for a SPA, fork-and-adapt workflow)
  → `noetl/travel` wiki. The travel wiki is the engineer-
  facing tutorial for building any-industry NoETL SPAs;
  pages are written generically where possible and use
  travel as the worked example.
- **Hybrid topics** (e.g. a generator that lives in
  `noetl/noetl` but produces manifests that live in
  `noetl/ops`): split — generator API in noetl wiki, the
  apply/verify/tuning operational guide in ops wiki, each
  cross-linked with a prominent callout. Don't try to combine
  them on one page.

If the right home isn't obvious, ask: "Where does the code this
documents live? Where is the artifact a reader needs in front
of them?"

## Rule 1 — deep-dive docs on first touch

When development work touches a module that **does not yet have a
dedicated wiki page**:

1. Before merging the code change, add a wiki page for the module
   following the slug + content conventions established in the wiki.
2. Cross-link the new page from `Home.md` and `_Sidebar.md`.
3. Bump the `noetl-wiki` submodule pointer in the same coordinated
   change set.

Skeleton / placeholder modules with no real surface yet are exempt —
list them under the parent package's "Skeleton modules" or "What's
deliberately not here" section instead of opening empty pages.

## Rule 1b — every pointer bump checks the wiki

When `ai-meta` bumps a submodule pointer for a merged PR:

1. Identify the relevant wiki for the submodule.
2. If the wiki has page(s) covering the changed surface, update
   them in the same change set (or its immediate follow-up) so
   the wiki tracks the merged code.
3. If no relevant page exists yet, follow Rule 1 (add a deep-
   dive page on first touch).
4. **If the submodule has no wiki at all**, stop and ask the
   user to enable the wiki and create a Home page. Do not
   silently skip the wiki step — it accumulates drift.

The bump → wiki update is a single coordinated change. Do not
land the bump and leave the wiki for "later" — that is exactly
how drift starts.

**This rule pairs with `issue-tracking.md` Rule 1b** ("every
pointer bump checks the open-issue list"). A pointer bump is
the natural checkpoint where three trails are reconciled in
lockstep: the code (the pointer itself), the wiki (this rule),
and the ai-task issue (issue-tracking Rule 1b). The
`/bump-pointer` skill walks the three checks in order.

Repos with wikis today (all production submodules):
`noetl/noetl`, `noetl/ops`, `noetl/travel`, `noetl/gateway`,
`noetl/cli`, `noetl/doctor`, `noetl/e2e`, `noetl/gui`,
`noetl/apt`. (`noetl/docs` is itself a Docusaurus site and
does not need a separate wiki.) If a new production submodule
is added, enable its wiki before merging the first code change
that touches a public surface.

## Rule 2 — validate the wiki against code changes

When development changes the public surface of a documented module
(new env var, new API endpoint, new schema field, removed feature,
renamed type, changed default):

1. Update the wiki page **in the same change set** as the code.
2. Verify cross-links still resolve, especially any links that
   reference a renamed or removed surface.
3. Mention the wiki update in the PR description (so reviewers see
   that the doc moved with the code).

If an existing page is stale or incomplete, treat the touched
change as hitting an un-covered module and refresh it.

## What "covered" means

A module is **covered** when:

- A wiki page exists at the conventional path (mirror of the code
  path, with a disambiguating slug if the basename would collide).
- The page documents: purpose, public API or YAML surface, key
  invariants, configuration env vars, error taxonomy, and at least
  one `Related` cross-link.
- Source links use absolute GitHub URLs into `noetl/noetl@main`.

The Home table and `_Sidebar.md` both list the page.

## Coordination with the handoff convention

Wiki edits ride the same coordination pattern as code changes:

- Wiki content lives in `repos/noetl-wiki/`. Edit, commit, push.
- The code PR in `repos/noetl/` references the wiki update in its
  body.
- After both land, bump pointers in `ai-meta`:
  - `chore(sync): bump noetl-wiki to <sha>`
  - `chore(sync): bump noetl to <sha>`

For cross-session work (a multi-PR engineering effort that adds a
new subsystem), open a handoff under `handoffs/active/<slug>/` per
`agents/rules/handoffs.md`. The handoff prompt should call out
which new modules need wiki coverage so the executor doesn't merge
code with un-covered modules.

## Page conventions (quick reference)

- **Slugs avoid generic names.** Use `dsl_engine` instead of
  `engine`. The page itself states the chosen slug if it diverges
  from the basename.
- **Source links are absolute** GitHub URLs into the default
  branch (`main` or `master`).
- **Inter-wiki links use basenames**: `[Outbox](outbox)`.
- **Code snippets reflect the current source** — copy-paste from
  the file, then trim. Don't paraphrase signatures.
- **Mirror the code path.** A page at `noetl/core/foo/bar.md`
  documents the code package or file at `noetl/core/foo/bar` or
  `noetl/core/foo/bar.py`.

## When the rule doesn't fire

- One-line type aliases, generated `__init__.py` re-exports, and
  trivial private helpers.
- Internal-only refactors that don't change any public surface or
  user-observable behavior.
- Sweeping renames that the wiki's existing pages already describe
  abstractly (the rule fires when behavior or shape changes, not
  on every cosmetic shuffle).

## Tooling

- All wikis live as Git submodules tracked in `.gitmodules`:
  - `repos/noetl-wiki/` → `noetl/noetl.wiki.git` (application docs)
  - `repos/noetl-ops-wiki/` → `noetl/ops.wiki.git` (operational docs)
  - `repos/noetl-travel-wiki/` → `noetl/travel.wiki.git` (reference-SPA developer docs)
  - `repos/noetl-gateway-wiki/` → `noetl/gateway.wiki.git` (gateway developer docs)
  - `repos/noetl-cli-wiki/` → `noetl/cli.wiki.git`
  - `repos/noetl-doctor-wiki/` → `noetl/doctor.wiki.git`
  - `repos/noetl-e2e-wiki/` → `noetl/e2e.wiki.git`
  - `repos/noetl-gui-wiki/` → `noetl/gui.wiki.git`
  - `repos/noetl-apt-wiki/` → `noetl/apt.wiki.git`
  After a fresh clone of `ai-meta`, run
  `git submodule update --init --recursive` to bring all in.
- Each wiki is a normal Git repo — no special tooling. Push to
  `origin master` and the wiki updates immediately at
  `https://github.com/noetl/{noetl,ops,travel}/wiki`.
- Page list and slug index lives in each wiki's own `Home.md`
  and `_Sidebar.md`.
- Cross-wiki links: use full GitHub URLs
  (`https://github.com/noetl/<repo>/wiki/<slug>`) — there's no
  shared slug namespace across wikis.
