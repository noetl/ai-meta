---
date: 2026-05-05T22:28:18Z
title: Full regression sweep AMBER — Ollama 4Gi too small for gemma3:4b live inference; ops#38 lifted to 5Gi
tags: [noetl, ops, ollama, gemma3-4b, memory-limit, regression-sweep, codex-bridge]
---

## Outcome

AMBER. Final stack is healthy and Gemma 4 inference works, but a
silent infrastructure regression surfaced during the sweep and was
fixed in-flight via [noetl/ops#38](https://github.com/noetl/ops/pull/38).
Cluster remains on `v2.35.9` (no noetl release this round, as
specified by the task constraint).

## The headline finding: Ollama 4Gi memory limit

**Symptom**: direct `kubectl exec deploy/ollama -- ollama run gemma3:4b "ping"`
returned HTTP 500. The auto-troubleshoot diagnosis call also failed.
Error message:

> model requires more system memory (4.0 GiB) than is available (3.9 GiB)

**Why it was silent until now**: previous rounds passed because of
a combination of (a) catalog defaults still pointing at gemma2:2b
(smaller, fits in 4Gi) for some path, (b) the local Ollama
deployment having been manually patched with more memory at some
earlier point, (c) the spike's smoke happening to skip the live
inference path (e.g. when the diagnosis returned `category: unknown,
confidence: 0.0` from a fast fallback). The regression sweep
specifically demanded **proof of live gemma3:4b inference via event
evidence**, which forced the path to actually run and exposed the
limit.

**The fix in ops#38**: `automation/agents/ai_os/lifecycle/deploy.yaml`
Ollama resources updated to `requests: 3Gi, limits: 5Gi` (was 4Gi
default). Default model comments/value also explicitly set to
`gemma3:4b`. Local cluster patched to match before the verification
re-ran.

## Gemma 4 evidence trail (the canonical proof)

This is what to cite going forward when asked "are we actually
running on Gemma 4":

```
spike execution: 620356925057663015            (parent, GREEN)
diagnose execution: 620356943059615814         (auto-troubleshoot sub)
ollama_triage call.done: event_id 620357371792982133
  context.tool_config.args.triage._meta.ollama_response.model
    == "gemma3:4b"
  result.context.arguments.model
    == "gemma3:4b"
```

The parity smoke's cluster mode against execution 620356925057663015
also passed (6 terminal events, 4 step-pair comparisons), confirming
nested-dict shape parity at the persisted-event layer.

## Verification (post ops#38)

All checks passed after the in-flight fix:

- Stack tags: server, worker, ollama-bridge all on
  `ghcr.io/noetl/noetl:v2.35.9`. Pods healthy.
- 5 smokes: carveout 8/8, gap41_wait 7/7, auto_troubleshoot 9/9,
  optional_ai 6/6, parity static 2/2 + cluster PASS.
- Spike stability: 3/3 GREEN, all `attempts=0`. Execution IDs:
  `620359261754753202`, `620359619520495931`, `620359943354319300`.
- MCP JSON-RPC: `tools/list` returned `troubleshoot_diagnose_execution`;
  `tools/call` returned `isError=false` with
  `noetl_execution_id=620360497933582925`.
- Bump_image idempotent (exec 620360689244177056): GHCR probe
  attempt 1/2 succeeded, all components unchanged, no `declare -A`
  output.
- Auto-troubleshoot contract: full 5 keys at
  `events[2].result.context.diagnosis`, source=ollama.
- Failed-sub envelope shape: `trigger_failure` terminal events
  preserve nested `result.context.error.diagnosis` on
  `command.completed event_id=620357385516744862`,
  `step.exit event_id=620357385508356253`,
  `call.done event_id=620357385508356252`.

Catalog re-registers: `bump_image` v9, `diagnose_execution` v9,
`spike_e2e_test` v12, `ai_os_deploy` v4 (new from ops#38).

Ollama models loaded in-cluster:

```
qwen3:32b
gemma3:4b
```

(qwen3:32b is the configured escalation target; not exercised in
this sweep because `escalate_to: none`.)

## Submodule pointer (committed locally in ai-meta, awaiting push)

```
ops    aefa3a36283d99a6d9a55a3711fe816b4f8d20d6   (ops#38 merged)
```

ai-meta `main` is 1 commit ahead of origin:

```
3cfff72 chore(sync): bump ops for Gemma 4 regression sweep
```

## Architectural take

The Ollama memory limit was the kind of silent infrastructure
regression that ONLY a sweep with concrete model-evidence
requirements catches. Catalog defaults said gemma3:4b. Ollama had
gemma3:4b pulled. But the actual model invocation failed with a
500 — and any code path that fell through to a degraded diagnosis
(empty fields, low-confidence dummy values) would have made the
spike still pass at the assertion layer. The bucket that demanded
the model name appear in events forced the failure into view.

This generalises: **whenever we add a new external dependency that
has resource requirements (Ollama models, MCP servers, vector
stores, etc.), the sweep needs a corresponding "actually exercised"
bucket** — not just a "configured" or "loaded" check.

## Follow-ups (not blocking)

1. The "actually exercised" pattern: consider adding evidence-trail
   buckets for any other external dependency that has fall-through
   degradation paths. Candidates: MCP server backends, OpenAI/Claude
   escalation paths.
2. `ai_os/lifecycle/deploy.yaml` Ollama defaults are now 3Gi/5Gi —
   document the rationale (gemma3:4b runtime requirement) in the
   playbook comments so a future "right-size for cost" pass doesn't
   accidentally drop them back below 4Gi.
3. Consider adding a smoke that exercises the model loading path
   directly (`kubectl exec deploy/ollama -- ollama run gemma3:4b
   "ping"`) so the memory regression would have surfaced at PR-time
   rather than during the sweep. Lives well alongside the existing
   parity smoke.

## Refs

- bridge/outbox/20260505-220055-deploy-latest-full-regression-gemma4.result.json
- noetl/ops#38 (Ollama 5Gi limit + gemma3:4b default)
- Diagnose execution evidence: 620356943059615814
- Parent spike: 620356925057663015
