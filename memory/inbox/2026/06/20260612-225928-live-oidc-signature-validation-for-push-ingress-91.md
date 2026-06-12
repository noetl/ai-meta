# Live OIDC signature validation for push ingress (#91)
- Timestamp: 2026-06-12T22:59:28Z
- Author: Kadyapam
- Tags: oidc,gateway,push-ingress,subscription,issue-91,gcp,validation

## Summary
Closed the #90 Phase 3 gap: the gateway pubsub_oidc verifier is proven against the REAL Google JWKS. Minted a genuinely Google-signed OIDC token by impersonating the #90 Phase 5 runtime SA (noetl-subscription-runtime@noetl-demo-19700101) via 'gcloud auth print-identity-token --impersonate-service-account=$SA --audiences=$AUD --include-email' — a plain user token cannot set a custom audience; impersonation needs a scoped roles/iam.serviceAccountTokenCreator binding (granted then REMOVED). Added an #[ignore]d live test oidc_live_google_token_against_real_jwks in repos/gateway/src/ingress/verify.rs (fetches live JWKS via fetch_google_jwks; valid->verified, wrong-aud/wrong-SA/tampered->rejected) [gateway#30, test-only] + runner scripts/live_validate_oidc_verify.sh [e2e#50]. Full HTTP run on kind: gateway binary -> kind server, 4 received -> 1 dispatched (202 + COMPLETED child) -> 3 rejected (tampered 401/wrong-aud 403/missing 401), zero exec from rejects. No GCP cost-bearing resources created. #91 validation complete; PRs open, awaiting merge + pointer bump; board In progress.

## Actions
-

## Repos
-

## Related
-
