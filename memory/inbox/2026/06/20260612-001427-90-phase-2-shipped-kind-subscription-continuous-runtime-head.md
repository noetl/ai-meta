# #90 Phase 2 shipped — kind:Subscription + continuous runtime + header-directive engine (live E2E green)
- Timestamp: 2026-06-12T00:14:27Z
- Author: Kadyapam
- Tags: noetl,subscription,phase2,rfc90,kind-subscription,directive-engine,continuous-runtime,server,worker,tools,ops,e2e,live-e2e

## Summary
RFC #90 Phase 2 SHIPPED across 5 repos + live kind E2E (13/13). kind:Subscription first-class catalog type + event-sourced lifecycle (server v3.2.0, ebd2944, /api/subscriptions register/activate/pause/resume/drain/deactivate, idempotent register, execution_pool override -> noetl.commands.<pool>.<eid>, W3C trace into meta.trace + child inheritance). Continuous listener runtime Mode B (worker v5.16.0, 1f74992, WORKER_MODE=subscription: build_source factory, poll loop -> one POST /api/execute per message on dedicated pool, directives + directives_applied, drain on SIGTERM). Header-directive engine (tools v3.3.0, 4995692: DirectiveSpec/DispatchPlan allowlisted redirect/pool/idempotency/content + W3C trace, untrusted by default + build_source factory). Ops dedicated pool+KEDA+Recreate (242e420). E2E fixtures+runner (32df918). E2E: 6 msgs->6 executions on dedicated pool all COMPLETED, 2 header-redirected, traceparent into all 6 children, full lifecycle event-logged. 3 integration gaps fixed in-PR: noetl.resource FK seed for subscription kind, event.created_at TIMESTAMP not TIMESTAMPTZ, SIGTERM drain. Decisions: OQ1 new WORKER_MODE run-mode, OQ7 explicit-pool wins over priority. CLI parse deferred to Phase 6. ai-meta@8e970e4. #90 STAYS OPEN (Phase 3 gateway push, Phase 4 spool). Cluster left clean :dev (brokers kept).

## Actions
-

## Repos
-

## Related
-
