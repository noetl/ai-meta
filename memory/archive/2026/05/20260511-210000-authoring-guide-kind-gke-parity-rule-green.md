# Authoring guide kind-to-GKE parity rule GREEN

Date: 2026-05-11

Docs PR `noetl/docs#61` merged at `aca3631cc4698a79f6a2433354274330cffd00ea`, adding the 14th playbook-authoring rule:

```text
### Every kind deploy needs a chained GKE-parity round
```

Placement: new `## Deployment parity` section in `docs/reference/playbook_authoring_guide.md`, inserted after `## GUI integration` and before `## See also`.

The rule pins the repeated process lesson from this session: local kind is a fast acceptance surface, not proof that GKE and external production surfaces are current. It tells future bridge tasks to either include an explicit GKE phase or queue a chained parity round, and to document when GKE is intentionally out of scope.

Evidence pointers in the rule:

- `bridge/outbox/20260511-110000-gke-parity-sync.result.json` — catalog drift after kind-only deploys
- `bridge/outbox/20260511-130000-gateway-terminal-surface-and-gui-bump.result.json` — GUI surface lived outside the expected GKE surface
- `bridge/outbox/20260511-150000-eliminate-minio-add-seaweedfs-rustfs-chooser.result.json` — storage replacement was kind-GREEN before GKE rollout

Validation: `npm run build` completed cleanly in `repos/docs`.

ai-meta has `repos/docs` bumped locally and staged through the close-out commit, but not pushed. Result file: `bridge/outbox/20260511-210000-authoring-guide-kind-gke-parity-rule.result.json`.
