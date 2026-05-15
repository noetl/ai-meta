# Travel Anthropic re-smoke v2 AMBER - secret fixed, model access mismatch

Date: 2026-05-10

The Anthropic GCP secret provisioning is now correct, but the re-smoke did not close GREEN.

What changed:

- `anthropic-api-key` version 1 exists in `noetl-demo-19700101`.
- `noetl-demo-19700101` has project number `1014428265962`, so the existing runtime path `projects/1014428265962/secrets/anthropic-api-key/versions/1` already points at the right project.
- The key prefix was verified only as `sk-ant-api03-8AQeco4...`.
- IAM includes `serviceAccount:noetl-worker-mcp@noetl-demo-19700101.iam.gserviceaccount.com` with `roles/secretmanager.secretAccessor`.

Why it is still AMBER:

- All five `travel --provider anthropic ...` smokes completed, but each fell back to OpenAI with `provider_fallback_reason="anthropic HTTP 404"`.
- Direct Anthropic API probing with the same key confirmed:
  - `claude-3-5-haiku-latest` returns 404 `not_found_error`.
  - `claude-3-5-haiku-20241022` also returns 404.
  - `claude-sonnet-4-20250514` returns 200.
- Therefore the remaining blocker is model availability/configuration, not Secret Manager.

No ops PR was opened because the bridge task allowed only a secret-path alignment change and explicitly denied modifying classifier/model code in this smoke-only round.

Follow-up shape:

- Small ops/docs round: make the Anthropic model configurable via workload, or switch the default from `claude-3-5-haiku-latest` to an enabled model such as `claude-sonnet-4-20250514`.
- Then rerun the five-intent Anthropic matrix and require `effective_provider="anthropic"` with no fallback reason for help/flights/locations/hotels/activities.
