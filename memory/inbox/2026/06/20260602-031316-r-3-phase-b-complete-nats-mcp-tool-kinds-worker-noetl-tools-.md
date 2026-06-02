# R-3 Phase B complete: nats + mcp tool kinds, worker noetl-tools 2.16 bump, KEDA dual-scaling
- Timestamp: 2026-06-02T03:13:16Z
- Author: Kadyapam
- Tags: R-3,Phase-B,worker-parity,noetl-tools,nats-tool,mcp-tool,KEDA,dual-scaling,deferred-agent,deferred-container,#30,#38,#39,#40,#41

## Summary
Sequential R-3 Phase B worker tool-kind parity rounds shipped today: (1) #38 noetl/tools#12 NatsTool (KV/Object Store/JetStream publish) shipped 2.15.0; (2) #39 noetl/tools#13 McpTool (JSON-RPC over HTTP with SSE) shipped 2.16.0; (3) #40 noetl/worker#36 bumped noetl-tools 2.11 → 2.16 — dynamic ToolRegistry dispatch means no per-variant match arms, just dep bump + integration tests; (4) #41 noetl/noetl#652 + noetl/ops#136 KEDA dual-scaling — new scaledobject-worker-rust-pool.yaml + parameterised drift guard across both pool fixtures (tests/fixtures/keda/). Both ScaledObjects applied to kind, READY=True with their HPAs provisioned. agent + container kinds deferred (Python-runtime LLM bridge + slot-holding K8s poll loop respectively — both need architectural re-shaping before Rust port). Worker pinning + redaction unchanged. R-3 Phase B structurally complete; next under #30 umbrella is R-4 hot-path-rewrite decision point (~6 months out, driven by production handle_event p90 numbers; today p90 is ~130-180ms after #29's perf series, not constraining). Codex delegation hit Bash sandbox limits twice during the session (PR work for #41 ops side and earlier #36 patch removal) — implemented directly in both cases. Pattern lesson: codex agents are good for scoped Rust crate work but the Bash permission setup is unreliable for git+gh push flows; expect to take over manually for the push/PR step on more than half of dispatches.

## Actions
-

## Repos
-

## Related
-
