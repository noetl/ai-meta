---
thread: 2026-05-28-noetl-cli-context-auth-ergonomics
round: 2
from: claude
to: claude
created: 2026-05-28T03:25:00Z
status: open
expects_result_at: round-02-result.md
wait_phrase: "proceed with runtime contract auth0 deploy"
---

# Round 02 — Auth0 runtime contract + `noetl context init --from-gateway`

> **Predecessor:** `round-01-result.md`.  Round 01 shipped CLI
> changes 1, 3, 4 (PR #13 — `context update` + 401 hint + PKCE
> callback hint).  Round 02 picks up the two deferred changes:
> - Change 2 — `noetl context init <name> --from-gateway <url>`
> - Change 5 — `noetl context port-forward <name>` daemon

## Predecessor PRs

Three PRs already open at the time this prompt was written.
They land in dependency order:

1. **noetl/ops #124** — Helm chart: 4 new `env.auth0*` keys +
   conditional `GATEWAY_AUTH0_*` env vars on the deployment.
   Safe to merge alone (informational only).

2. **noetl/gateway #16** — `Auth0Config` struct +
   `runtime_contract` handler emits `auth0` block when the env
   vars are set.  Built on top of `client-absent-log-…` so
   merging just adds the block; nothing breaks for existing
   clients.  Depends on PR #124's env vars to actually carry
   data, but compiles + tests independently.

3. **noetl/cli #14** — `noetl context port-forward` daemon.
   Branched off PR #13 (`kadyapam/cli-context-update-and-auth-hints`).
   Once #13 merges, rebase #14 onto main and retarget.  Lands
   the daemon + 4 new kube_* fields on `Context`.

## Phases

### Phase A — read-only verification of merged state

1. Sync `repos/ops`, `repos/gateway`, `repos/cli` to current
   `main`.  Confirm PRs above have merged.
2. After ops + gateway PRs merge + cluster deploy, hit the
   runtime contract from outside the cluster:
   ```
   curl -s https://gateway.mestumre.dev/api/runtime/contract | jq '.auth0'
   ```
   Expected: a JSON object with `domain`, `client_id`,
   `redirect_uri` (audience may be omitted).

### Phase B — implement `noetl context init --from-gateway <url>`

3. Branch `kadyapam/cli-context-init-from-gateway` off
   `repos/cli` `main`.
4. Add `ContextCommand::Init { name, from_gateway, set_current,
   non_interactive }`.
5. Handler fetches `<from_gateway>/api/runtime/contract`,
   parses the `auth0` block (if present), prints a summary
   table of what would be set, prompts the user to confirm
   (skip prompt when `--non-interactive`/`--yes`), writes the
   context via the same path as `ContextCommand::Update`.
6. On the happy path, the operator runs:
   ```
   noetl context init gke-prod --from-gateway https://gateway.mestumre.dev
   noetl auth login --browser-pkce
   ```
   and the context has `auth0_domain`, `auth0_client_id`,
   `auth0_redirect_uri`, optionally `auth0_audience` populated
   correctly.
7. Unit tests covering:
   - missing `auth0` block ⇒ context gets `server_url` only
     + warning printed
   - well-formed `auth0` block ⇒ all fields written
   - gateway URL trailing `/` handled
   - 404 / network failure ⇒ clear error, exit code 1

### Phase C — open draft PR

8. Push branch, open draft PR on noetl/cli titled
   `feat(cli): noetl context init --from-gateway`.
9. PR body cross-links this thread + cites the round-01
   ergonomics PR #13 + the gateway PR #16 for the runtime
   contract shape.

### Phase D — live re-deploy (GATED)

> ***Run only after explicit human go-ahead. Wait phrase:
> `proceed with runtime contract auth0 deploy`.***

10. After all three predecessor PRs (ops #124, gateway #16,
    cli #14) plus this round's CLI PR have merged:
    - Build + push gateway image with new tag scheme
      `auth0-contract-<ts>`.
    - `helm upgrade noetl-gateway` with the new tag.
    - Verify `/api/runtime/contract` carries `auth0`.
    - Smoke-test the full bootstrap flow:
      ```
      noetl context delete gke-prod
      noetl context init gke-prod --from-gateway https://gateway.mestumre.dev
      noetl auth login --browser-pkce
      noetl --context gke-prod catalog list Playbook | head -5
      ```
    - Smoke-test the port-forward daemon (Phase F of Round 01's
      scope, deferred):
      ```
      noetl context update gke-pf --kube-context=gke_… --kube-namespace=noetl
      noetl context port-forward gke-pf --detach
      noetl --context gke-pf register credential -f ~/projects/noetl/credentials/duffel_token.json
      noetl context port-forward gke-pf --stop
      ```

## Hard rules

- Do NOT push to `main` on any repo.
- Do NOT merge any PR yourself.
- Phase D is gated on `proceed with runtime contract auth0 deploy`.
- No "canonical" in any prose or commit message.
- Do not store secrets in any file under ai-meta.

## FINAL REPORT

Always emit, even on early STOP.  Frontmatter:

```yaml
---
thread: 2026-05-28-noetl-cli-context-auth-ergonomics
round: 2
from: claude
to: claude
created: <ISO8601 UTC>
in_reply_to: round-02-prompt.md
status: complete | partial | blocked
---
```

Sections:

```markdown
## Phase A — read-only verification
## Phase B — `noetl context init --from-gateway` implementation
## Phase C — open draft PR
## Phase D — live re-deploy (GATED)
## Issues observed
## Manual escalation needed
```
