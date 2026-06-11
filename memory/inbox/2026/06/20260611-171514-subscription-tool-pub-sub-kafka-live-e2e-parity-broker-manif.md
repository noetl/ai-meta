# Subscription tool: Pub/Sub + Kafka live-E2E parity + broker manifests
- Timestamp: 2026-06-11T17:15:14Z
- Author: Kadyapam
- Tags: noetl,subscription,pubsub,kafka,e2e,kind,issue-90

## Summary
#90 Phase 1 brought Pub/Sub-pull + Kafka-poll backends to live-E2E parity with NATS on kind (count=5 acked=true -> COMPLETED -> event trail). Brokers: ops ci/manifests/pubsub-emulator/ (gcloud SDK emulator, worker reaches via pubsub-emulator.pubsub.svc:8085) + ci/manifests/kafka/ (apache/kafka:3.9.1 single-broker KRaft, advertised on kafka.kafka.svc:9092; bitnami avoided). E2E: noetl/e2e fixtures/playbooks/subscription/ + scripts/kind_validate_subscription_{pubsub,kafka}.sh. No adapter code change needed (pure-Rust kafka crate works vs Kafka 3.9 KRaft; Pub/Sub REST vs emulator; worker v5.15.2 nats|pubsub|kafka credential arm merges endpoint/brokers). GOTCHA: playbook when:/iterator references a prior step's tool-result field as {{ <step>.<field> }} (drain.count), NOT {{ <step>.output.<field> }} — the .output. form never resolves and silently skips arcs. ai-meta@09a60da (ops 568a4ac + e2e 8d21e7a). #90 stays open (Phases 2-7).

## Actions
-

## Repos
-

## Related
-
