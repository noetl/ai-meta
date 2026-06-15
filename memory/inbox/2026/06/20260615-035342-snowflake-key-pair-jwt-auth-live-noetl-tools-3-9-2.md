# Snowflake key-pair JWT auth live (noetl-tools 3.9.2)
- Timestamp: 2026-06-15T03:53:42Z
- Author: Kadyapam
- Tags: snowflake,keypair-jwt,noetl-tools,credentials,e2e,regression,issue-98,issue-99

## Summary
Snowflake tool now authenticates via key-pair JWT (RS256; iss=<ACCOUNT>.<USER>.SHA256:<base64(SHA256(pubkey DER))>, sub=<ACCOUNT>.<USER>, Bearer + X-Snowflake-Authorization-Token-Type: KEYPAIR_JWT) — bypasses MFA. Shipped across tools v3.9.0 (JWT + new SnowflakeConfig.public_key field), v3.9.1 (User-Agent header — SQL API rejects missing UA with 391903), v3.9.2 (session context warehouse/role/database/schema in request BODY not via USE — SQL API rejects USE with 391911; + multi-statement command split on ';' — SQL API runs one stmt/request, whole block fails 000008). Worker maps sf_public_key->public_key (worker#83) + noetl-tools dep bumped to 3.9.2 (worker#84/#85/#86). e2e#57 dropped USE from snowflake_postgres fixture. Validated end-to-end on kind against live sf_test account (NDCFGPC-MI21697): create_sf_database + setup_sf_table COMPLETED via JWT. transfer_sf_to_pg still fails — transfer tool can't resolve credential aliases / has no keypair fields — tracked in new umbrella #99. ai-meta pointers: tools a216ab2, worker 9d6b127, e2e e191231. Wiki: noetl-tools-wiki Snowflake-Tool page + ai-meta-wiki Umbrella-Regression-Baseline/#98 + Umbrella-Transfer-Tool-Credentials/#99.

## Actions
-

## Repos
-

## Related
-
