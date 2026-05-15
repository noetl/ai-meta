# Amadeus production API switch code-only GREEN

Date: 2026-05-11
Status: GREEN_CODE_ONLY

ops#72 merged the Amadeus MCP production switch at `e9cf2fdaf3c482513268a5ba7642d732362d5221`.

What changed:

- `automation/agents/mcp/amadeus.yaml` now treats `amadeus_env` as a load-bearing workload field.
- Default remains `test`, preserving existing kind/GKE behavior.
- `amadeus_env=production` switches the OAuth token endpoint and the flights, locations, hotels, and activities API calls from `test.api.amadeus.com` to `api.amadeus.com`.
- Production credentials use separate workload paths:
  - `amadeus_production_key_path`
  - `amadeus_production_secret_path`
- The keychain credential map selects production secret paths only when `amadeus_env == "production"`.

Validation:

- `Playbook.model_validate` passed for `automation/agents/mcp/amadeus.yaml`.
- A local Jinja render probe confirmed test and production endpoint/path selection.
- The patched playbook was registered on local kind as version `10`.
- Default test-mode execution `624838761406268192` completed with the Amadeus OAuth keychain bound.

Production smoke was intentionally skipped. GCP Secret Manager in project `noetl-demo-19700101` / project number `1014428265962` does not yet contain:

- `amadeus-production-client-id`
- `amadeus-production-client-secret`

No paid production API calls were made.

Provisioning recipe for the follow-up:

```bash
echo -n "<production-client-id>" | gcloud secrets create amadeus-production-client-id \
  --replication-policy=automatic \
  --project=noetl-demo-19700101 \
  --data-file=-

echo -n "<production-client-secret>" | gcloud secrets create amadeus-production-client-secret \
  --replication-policy=automatic \
  --project=noetl-demo-19700101 \
  --data-file=-

gcloud secrets add-iam-policy-binding amadeus-production-client-id \
  --project=noetl-demo-19700101 \
  --member=serviceAccount:noetl-worker-mcp@noetl-demo-19700101.iam.gserviceaccount.com \
  --role=roles/secretmanager.secretAccessor

gcloud secrets add-iam-policy-binding amadeus-production-client-secret \
  --project=noetl-demo-19700101 \
  --member=serviceAccount:noetl-worker-mcp@noetl-demo-19700101.iam.gserviceaccount.com \
  --role=roles/secretmanager.secretAccessor
```

Follow-up smoke must stay cost-controlled: one production `get_token`, one locations call, one flights call. No production regression matrix.
