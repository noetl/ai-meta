# Ops GHCR deploy playbooks merged
- Timestamp: 2026-04-26T20:58:04Z
- Author: Kadyapam
- Tags: ops,ghcr,deploy,kind,noetl

## Summary
Merged noetl/ops PR #9 (merge commit 9be9f656c56317da1cad0bb6d172ab63d248645f) to support deploying pinned registry images from ops playbooks without local image builds. NoETL local dev playbook can deploy ghcr.io/noetl/noetl:v2.23.2 with imagePullPolicy=Always; GUI playbook accepts explicit image_tag while preserving runtime env injection; Gateway playbook adds deploy-image for ghcr.io/noetl/noetl-gateway with namespace, NodePort, and context guard fixes. Local kind validation on arm64 confirmed NoETL server/worker healthy on v2.23.2. GUI/Gateway GHCR images were not rolled to arm64 kind because latest published GUI image lacks linux/arm64 and gateway image pulls as linux/amd64.

## Actions
-

## Repos
-

## Related
-
