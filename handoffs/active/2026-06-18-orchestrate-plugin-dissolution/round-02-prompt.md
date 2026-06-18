---
thread: 2026-06-18-orchestrate-plugin-dissolution
round: 2
from: claude
to: claude
created: 2026-06-18T19:30:00Z
status: open
tracks: noetl/ai-meta#111
expects_result_at: round-02-result.md
---

# Round 2 — continue toward server-API-only + stand up e2e for the new topology

Self-dispatched continuation of this thread after round 1 (Phase A / #110
shipped). Round 1 declared "Phase B — nothing pending" for #108; this round
takes the broader program lens (#107 step 2 wrap-up) the operator asked for:

1. **Status assessment** — concretely determine what orchestrator /
   workflow-execution logic still lives in the **server** vs. what already runs
   on the **system worker pool**, and what keeps the server from being
   API-only (catalog CRUD + external/gateway ingress + read APIs). Map the
   remaining gap to the program phases.
2. **E2E for the new topology** — stand up a committed, repeatable kind rig
   proving the orchestrate drive runs **off-server on the system pool** and the
   server only schedules + applies + serves reads. Validate live on kind.
3. **Refactor what is safe** — land + validate any genuinely-safe server-API-only
   step this session. **Conservative bias on anything that changes default
   behavior at scale** — surface production-policy decisions to the operator
   rather than doing them unilaterally.

## Hard rules (unchanged from round 1)

- PROD GKE untouched; do NOT re-run #49 flip prep.
- Don't disturb the other session's drift-test consumer or the CQRS branch.
- Restore kind to its as-found baseline at the end.
- Never push to `origin/main` or merge a PR without the standard go-ahead — the
  operator's blanket "work autonomously — no go/no-go prompts" for this session
  authorizes shipping additive, validated, non-behavioral changes (e.g. an e2e
  rig); behavior-changing defaults stay gated.
