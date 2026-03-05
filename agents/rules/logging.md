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
