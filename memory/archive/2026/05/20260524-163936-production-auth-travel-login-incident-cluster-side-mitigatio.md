# Production auth+travel login incident — cluster-side mitigations applied (gateway timeout, worker min replicas)
- Timestamp: 2026-05-24T16:39:36Z
- Author: Kadyapam
- Tags: incident,gke,auth,travel,production,handoff-pending

## Summary
User reported https://gateway.mestumre.dev returning 500 'Login playbook timed out' and https://travel.mestumre.dev showing 'Execution 633631566496792709 did not complete in time'. Both errors traced to the SAME 10-hour-old incident with two distinct surfaces. Root cause: worker.replicas=1 baseline cluster size; KEDA scale-up cold-start window leaves the cluster contended during burst load. During a burst window (~05:52-06:03 UTC), a travel itinerary-planner playbook took 10m24s (vs normal 10.7s baseline) and a parallel auth0_login took 8m39s (vs normal 2-3s baseline). Gateway's AUTH_PLAYBOOK_TIMEOUT_SECS=12 fired first, returning 500 to the user. Travel UI's waitForExecution() (repos/travel/src/components/shell/ChatThread.tsx:250-262) polls /api/executions/{id} 60x with 1500ms delay = 90s ceiling; fired before backend completed. Both playbooks DID eventually complete successfully. Cluster fixes applied (revision 156→157): kubectl set env deploy/gateway -n gateway AUTH_PLAYBOOK_TIMEOUT_SECS=60; helm upgrade --reuse-values --set worker.autoscaling.minReplicas=3 (1→3). Three follow-ups identified: (a) repos/travel: 90s polling ceiling too brittle, CALLBACK_GRACE_MS=8_000 likely too short; could switch to gateway callback subscription rather than polling. (b) repos/noetl: /api/executions listings endpoint returns stale status:RUNNING for 82/100 rows even when playbook.completed event fired (per-execution detail endpoint is fine). (c) Worker concurrency model verified async per single playbook (10s baseline OK); degradation only manifests under multi-playbook contention which minReplicas=3 should resolve. Open user questions: (1) why per-step latency is ~600ms not ms-level, (2) does the travel UI hit Firestore directly or only through gateway+playbooks.

## Actions
-

## Repos
-

## Related
-
