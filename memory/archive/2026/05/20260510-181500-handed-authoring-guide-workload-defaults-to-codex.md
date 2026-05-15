# Handed authoring-guide workload-defaults rule to Codex (12th rule from the flagship arc)

- date: 2026-05-10T18:15:00Z
- tags: docs, playbook-authoring-guide, workload-defaults, retro-rule, codex-handoff

## Round goal

Pin the workload-default-environment-mismatch lesson from the Phase 3
vertex-ai re-smoke as the 12th rule in `repos/docs/docs/reference/playbook_authoring_guide.md`.

The lesson: when a runtime workload defaults to an environment-specific value
(project ID, cluster name, region), the default should match the deployed
environment, not the developer's local kind/sandbox. The travel runtime
defaulted `gcp_project` (and the `vertex_project` Jinja chain that depended on
it) to `noetl-cluster` — silently misrouting every GKE caller until ops#60
flipped the default to `noetl-demo-19700101`.

## Why a new section

The 11 existing rules sit in 5 sections (Keychain rules, Step semantics,
External HTTP calls, YAML and SQL quoting, GUI integration). The new rule
isn't keychain-specific (no keychain involvement), isn't step semantics, isn't
HTTP-specific, isn't YAML/SQL quoting, isn't GUI. It's about workload field
declaration — declaration-time / binding-time behavior that misbehaves when
the default-of-default chain points at the wrong environment.

Best placement: a new top-level section `## Workload defaults` inserted between
`## Keychain rules` and `## Step semantics`. Both deal with binding-time Jinja
template chains that fail silently — the new rule is the natural neighbour.

## The rule

Title: **Match environment-specific workload defaults to where the playbook runs**

Good:
```yaml
workload:
  # GKE project — used by every downstream Jinja chain.
  gcp_project: "noetl-demo-19700101"
  vertex_project: "{{ workload.gcp_project }}"
  vertex_region: "us-central1"
```

Bad:
```yaml
workload:
  # Local kind sandbox name — silently misroutes every GKE caller.
  gcp_project: "noetl-cluster"
  vertex_project: "{{ workload.gcp_project }}"
  vertex_region: "us-central1"
```

Closing paragraph ties back to rule #1 (bare keychain references): both expose
how Jinja template chains in workload binding can hide a misconfiguration that
only manifests at request time. Prefer required fields with no default, OR
default to production; defaulting to local is the trap.

## Phases (3)

1. Apply edit (single-section insertion); verify docs build clean.
2. Docs PR: `docs(reference): add 12th rule — match environment-specific workload defaults to where the playbook runs`.
3. Bump repos/docs gitlink in ai-meta. Stage but do not push.

## Bridge artefacts

- `bridge/inbox/delegated/20260510-181500-authoring-guide-workload-defaults.task.json`
- `scripts/authoring_guide_workload_defaults_msg.txt`

## What's next after this lands

From the post-flagship deferred list (in order):

2. Wire hotels and activities branches in the travel runtime
3. app:form widget for refining Amadeus filters before re-running
4. Audit table re-add inside render_* steps (psycopg)
5. Anthropic re-smoke (gated on user provisioning the GCP secret)
6. Ollama provider — needs in-cluster bridge URL routing design
7. Investigate Amadeus test API 500s on flights/locations
