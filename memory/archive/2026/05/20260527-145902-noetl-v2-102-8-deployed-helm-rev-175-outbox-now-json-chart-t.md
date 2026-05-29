# noetl v2.102.8 deployed (helm rev 175); outbox now JSON; chart template bug surfaced + PR #122 open
- Timestamp: 2026-05-27T14:59:02Z
- Author: Kadyapam
- Tags: noetl,ops,helm,outbox,deployed,pr-620,pr-121,pr-122,template-bug

## Summary
PR #620 merged → noetl v2.102.8 publishes JSON over NATS instead of arrow-feather. PR #121 merged → chart sets NOETL_EVENT_MIRROR_ENABLED=true in config.server + config.worker. Built inline-runner-v9-20260527074000. Helm rev 175 on noetl. After deploy: workers correctly read mirror=true from ConfigMap (worker template just iterates config.worker). BUT server reads mirror=false from ConfigMap because templates/configmap-server.yaml:12 has a hardcoded 'NOETL_EVENT_MIRROR_ENABLED: ternary .Values.projector.enabled' that overrides the range above. Worked around with kubectl set env deployment/noetl-server NOETL_EVENT_MIRROR_ENABLED=true. PR #122 opened on noetl/ops with proper template fix (guards the ternary behind 'if not (hasKey .Values.config.server NOETL_EVENT_MIRROR_ENABLED)'). User testing SPA now. Cluster state: helm rev 175, image inline-runner-v9-20260527074000 (v2.102.8), worker env from ConfigMap (true), server env from direct override (true), worker still on NOETL_INLINE_TRIVIAL_CHILDREN=off. Old outbox 442 rows: 438 PUBLISHED (as arrow-feather pre-fix), 4 FAILED (oversized payloads still need NATS max-payload tuning OR clearing as dead-letter).

## Actions
-

## Repos
-

## Related
-
