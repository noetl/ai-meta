# noetl-dev VM swap added — 8 GiB swapfile, live, no restart
- Timestamp: 2026-07-09T06:11:12Z
- Author: Kadyapam
- Tags: infra,kind,podman-machine,swap,noetl-dev,oom,rust-builds

## Summary
Added an 8 GiB swapfile to the noetl-dev Podman machine VM (6 vCPU / 20 GiB RAM / 200 GiB xfs, Fedora CoreOS 43) that hosts the kind-noetl cluster. The VM shipped with swap=0, so heavy Rust worker/server builds hard-OOM-killed instead of degrading; swap gives a cushion. Swapfile = /var/swapfile, dd-allocated (fallocate leaves holes xfs swapon rejects), chmod 600, mkswap, swapon — LIVE immediately with NO podman machine restart and NO kind-node restart (the noetl-control-plane container does not auto-restart on VM reboot, so a machine restart would destroy the cluster). vm.swappiness=10 (cushion, not first resort). Persisted across reboots via /etc/fstab entry (/var/swapfile none swap sw 0 0) + /etc/sysctl.d/90-swappiness.conf; systemctl daemon-reload made the fstab generator emit an active var-swapfile.swap unit, so persistence is live-effective (no scheduled reboot needed). Cluster stayed healthy throughout: node Ready, /healthz ok, 32 pods Running unchanged before/after. Documented on ops-wiki page local-kind-vm (pushed c0755fb, includes a re-add recipe for VM recreates) + AGENT-COORDINATION board line. ops-wiki pointer NOT bumped in ai-meta — recorded pointer 8f51b636 already behind origin e035a3ab, bumping would absorb unrelated drift. repos/noetl + repos/server untouched; no GKE/prod.

## Actions
-

## Repos
-

## Related
-
