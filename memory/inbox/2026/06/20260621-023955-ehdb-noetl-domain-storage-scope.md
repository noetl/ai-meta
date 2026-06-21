# EHDB NoETL-domain storage scope
- Timestamp: 2026-06-21T02:39:55Z
- Author: Kadyapam
- Tags: ehdb,noetl,storage,nats,rag,dependency-collapse

## Summary
EHDB is now explicitly scoped as a NoETL-domain storage system rather than a generic database. Target capabilities include EHDB-native catalog, transaction log, event streams/durable consumers/replay replacing NATS JetStream, RAG document/chunk/embedding/vector metadata replacing permanent Qdrant dependency, analytical columnar reads replacing ClickHouse role, and EHDB-owned storage replacing ordinary Postgres/object-store platform dependencies. Track the scope in noetl/ehdb#6 and keep design in the EHDB wiki.

## Actions
-

## Repos
-

## Related
-
