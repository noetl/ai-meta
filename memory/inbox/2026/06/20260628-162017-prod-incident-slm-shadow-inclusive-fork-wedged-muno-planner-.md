# Prod incident: SLM shadow inclusive-fork wedged Muno planner (#154)
- Timestamp: 2026-06-28T16:20:17Z
- Author: Kadyapam
- Tags: incident,prod,slm-shadow,orchestrate,muno,travel,server,issue-154,issue-153

## Summary
2026-06-28: real user 'Trip to Paris' got NO reply on travel.mestumre.dev after SLM shadow (planner v53, cid 658884549467702124) shipped to prod. Mechanism: shadow changed render_widget_chat.next exclusive->inclusive 3-arc fork; a post_docs>0 turn matches 2 arcs (main finalize + shadow_slm_compare) -> prod orchestrate wasm (server v3.47.0) errors evaluating the inclusive multi-match fork -> returns error/empty via offloaded ref -> server worker-driven drive can't resolve ref ('orchestrate result ref not found in store' -> 'could not decode OrchestrationResult' -> commands=0) -> reconcile poller re-publishes __orchestrate__ every ~8s FOREVER. Turn computes bot_message at render_widget_chat then wedges; persist_render_docs/append_render_events/final_result/playbook.completed never fire -> no Firestore write, no gateway completion -> SPA shows no reply. shadow_slm_compare never dispatches (fork errors first) so the dead Mac MLX cloudflared endpoint is NOT proximate cause. RESTORED: re-registered shadow-off content -> v54 cid 659305048584749934 (POST /api/catalog/register, body {content,resource_type:Playbook}); latest now has no slm_shadow. Both casings COMPLETE ~45s with bot_message. CLEANUP: terminated 2 wedged execs (329650379006418944 real user, 329653503444131840 repro) by appending playbook.failed via POST /api/events (append-only, no data deleted) -> reconcile poller stops via terminal guard in apply_worker_orchestration. FIX FILED #154 two legs: (A server, important latent) worker-driven orchestrate unresolvable-ref must terminate playbook.failed not Ok(0) loop -- #123/server PR#258 only covered inline output_b64 envelope not the ref-not-found arms (events.rs ~L3550-3625); (B travel) shadow compare must not ride inclusive multi-match fork on response path -- chain after finalize or separate spawned exec, no-op on endpoint down. Shadow stays OFF; re-enable gated on #154. Commented #153 (issuecomment-4826678503). Core pods 0 restarts; OQ5/result_store/IAM/secrets/images untouched.

## Actions
-

## Repos
-

## Related
-
