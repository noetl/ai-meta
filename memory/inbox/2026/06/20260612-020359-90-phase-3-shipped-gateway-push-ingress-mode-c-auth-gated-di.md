# #90 Phase 3 shipped — gateway push-ingress (Mode C) + auth-gated directive trust (live E2E green)
- Timestamp: 2026-06-12T02:03:59Z
- Author: Kadyapam
- Tags: noetl,subscription,gateway,push-ingress,webhook,pubsub,oidc,hmac,bearer,auth,directives,phase3,rfc90,server,e2e

## Summary
Phase 3 of the subscription/listener RFC (#90) shipped + live-validated on kind; umbrella STAYS OPEN (Phases 4-7 remain). The gateway gains POST /ingress/{listener}: it terminates untrusted webhook/Pub-Sub-push traffic as a verify-and-forward gatekeeper (no DB on the ingress path), VERIFIES the delivery (HMAC-SHA256 raw-body / bearer / Google Pub-Sub OIDC RS256-vs-JWKS+aud+email+exp; secret resolved from the Wallet by alias via the server's GET /api/internal/ingress/{listener}), and ONLY THEN applies header directives + forwards one POST /api/execute per delivery on the dedicated pool. The auth gate is a STRUCTURAL invariant (verify_then_plan fuses verify+directive-resolution so a failed verification yields no DispatchPlan; unit-proven by directives_applied_only_after_verification_passes + live-proven: tampered/unauth deliveries carrying the redirect header -> 401, no execution, no directive). Directive engine VENDORED serde-only into the gateway (src/ingress/directives.rs) from noetl-tools v3.3.0 because the internet-facing edge must not pull duckdb/kube; fast-follow tracked to extract a shared noetl-directives crate. Shipped: gateway v3.3.0 (gateway#28 closes gateway#27), server v3.3.0 (server#182 closes server#181, push catalog validation + ingress config endpoint + subscription::ensure_registered), ops#172 (gateway NOETL_INTERNAL_API_TOKEN env, secretKeyRef same-namespace), e2e#43 (kind_validate_subscription_push.sh + HMAC/bearer fixtures). Live: HMAC 12/12 + bearer 12/12 assertions; Pub-Sub-push envelope unwrap + attributes-as-directive-channel proven (base64 message.data decoded, redirect via attribute); OIDC signature unit-proven (all negatives), live OIDC deferred (needs a real Google SA token). ai-meta pointers: server fa1ff3f + gateway 38f024b + ops 54f2d65 + e2e 1421267 + ai-meta-wiki 82e74b5 + gateway-wiki 64534ec, ai-meta@7447cf0. Board #90 In progress. Note: gateway deploys in ns 'gateway' (not noetl); kind image needs 'localhost/' prefix (set image deploy/gateway gateway=localhost/noetl-gateway:latest); kind load via podman uses image-archive (podman save | kind load image-archive).

## Actions
-

## Repos
-

## Related
-
