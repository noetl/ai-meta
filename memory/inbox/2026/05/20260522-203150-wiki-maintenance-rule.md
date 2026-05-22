# Wiki maintenance rule landed
- Timestamp: 2026-05-22T20:31:50Z
- Author: Kadyapam (via Claude session)
- Tags: ai-meta,rules,wiki,documentation,policy

## Summary

After completing the wiki coverage sweep (54 pages spanning entry
points, core packages, server API, server runtime, policies,
security, tools, and the DSL engine), added a forward-looking rule
so the wiki keeps pace with development rather than going stale.

New file `agents/rules/wiki-maintenance.md` codifies:

1. **First-touch deep-dive** — if a code change touches an un-covered
   module, add the wiki page in the same change set (not as a
   follow-up sweep).
2. **Validate the wiki against code changes** — if the public
   surface of a documented module changes (env var, API field,
   schema, default), update the wiki page in the same change set
   and call it out in the PR.
3. **Definition of "covered"** — page exists at the conventional
   path with: purpose, public API/YAML surface, key invariants,
   config env vars, error taxonomy, and at least one Related
   cross-link. Page is listed in Home and _Sidebar.
4. **Coordination with handoffs** — wiki edits ride the same
   submodule-pointer-bump pattern as code; cross-session work
   should call out un-covered modules in the handoff prompt.
5. **Exemptions** — skeleton modules, generated re-exports, trivial
   private helpers, cosmetic refactors.

Also added a Hard Rule #8 to `AGENTS.md` pointing at the new file
so the rule loads on session start alongside the other hard rules.

## Actions
- agents/rules/wiki-maintenance.md (new)
- AGENTS.md hard-rule #8 added

## Repos
- ai-meta (rule file + AGENTS.md edit)
- noetl-wiki — the artifact the rule governs

## Related
- agents/rules/handoffs.md — coordination pattern this rule rides on
- agents/rules/commit-conventions.md — commit message prefixes used
  for the chore(sync) bumps the rule mentions
- Wiki state at this snapshot: 54 pages, master @ 0769aca, ai-meta
  pointer @ b0a375c
