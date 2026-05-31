---
paths:
  - "repos/noetl/**"
  - "repos/server/**"
  - "repos/gateway/**"
  - "repos/worker/**"
---

# Logging Hygiene

- Keep logs minimal by default. Avoid INFO-level logs for high-frequency health/internal polling paths.
- When adding new health/check/poll endpoints, either suppress access logs for those paths, or log at DEBUG with rate-limiting/sampling.
- Any change that can increase request log volume must include a quick flood check and an explicit rationale.
- **Metrics, not logs, for observability**.  When you reach for a log line, ask whether a counter / histogram / span event would tell you the same thing without the cost.  See [`observability.md`](observability.md) for the metrics surface, traceability requirements, and `execution_id` propagation expectations.
- Every WARN / ERROR line includes `execution_id` as a structured field (not embedded in the formatted message text) — keeps grep / log-aggregator queries reliable across components.
