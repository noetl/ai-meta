# RFC #90 Phase 7 shipped — subscription scale hardening; #90 CLOSED (all 7 phases)
- Timestamp: 2026-06-12T19:38:43Z
- Author: Kadyapam
- Tags: noetl,subscription,rfc-90,phase-7,scale-hardening,batch,dedup,rate-limit,closed,server,worker

## Summary
Phase 7 (scale hardening) of the subscription/listener RFC shipped + live-proven on kind, closing umbrella #90 (all 7 phases complete). server v3.5.0 (#189, closes server#188): POST /api/execute/batch (N->N, partial-failure contained, reuses execute_one so per-message routing/trace/dedup intact) + opt-in exactly-once dedup window (noetl.subscription_dedup, bounded-by-age, race-safe INSERT ON CONFLICT, scoped by parent_execution_id=subscription, subscription.message.deduplicated audit, default off, resolves OQ1). worker v5.19.0 (#79, closes worker#78): batch dispatch via execute_batch in chunks of batch_max; dedup opt-in stamps idempotency_key->message_id; per-subscription rate limits via new deterministic token-bucket RateGovernor (src/ratelimit.rs) enforced on the FETCH side (stop fetching at cap -> source keeps backlog -> no loss) + subscription.rate_limited event. ops#176 example + e2e#48 kind_validate_subscription_scale.sh. NO tools change -> no crate cascade. Live on kind: batch 12->12 COMPLETED on subscription pool + per-message traceparent + execute_batch used; dedup duplicate->1 execution + deduplicated event; rate-limit engaged + 10/10 -> executions no loss; direct-curl within/outside-window + dedup-off + batch partial-failure all green. ai-meta b668adb (server 7b217d8 + worker 7531f4a + ops 6db69b9 + e2e 203593b). #90 closed; follow-ups opened: #91 live OIDC, #92 shared noetl-directives/noetl-spool crates, #93 cross-restart spool drain, #94 s3 spool wiring, tools#57 pubsub pull. Board #90 -> Done. Cluster restored to :dev (phase7 code; version string reads 3.4.2 cosmetically since image built pre-release-commit).

## Actions
-

## Repos
-

## Related
-
