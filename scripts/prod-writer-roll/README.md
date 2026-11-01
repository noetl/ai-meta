# prod writer roll scripts (EHDB, noetl-prod)

These are the scripts used for the 2026-10-26/27 prod writer rolls: worker v6.10.0, v6.11.0 and v6.11.1, plus enabling #491 deletion. They were rebuilt from the session transcript after a reboot cleared the scratchpad. Run logs are written next to the scripts and git-ignored.

| script | use |
|---|---|
| `writer-image-roll.sh <image@digest>` | **The only way to change the writer image.** Patches the image only: no safe-to-evict annotation, and the env (`PRUNE_MODE=enabled`, `RETENTION_HOURS=49`, `TOKIO_WORKER_THREADS=8`) is left alone. If the new pod is Pending for more than 60 s, it runs `rollout undo` and replaces the pod. |
| `writer-env-roll.sh NAME=VALUE` | Changes one env var on the writer, which restarts it. The image is unchanged. |
| `writer-seed-proof.sh <image>` | Runs `writer-image-roll` while a system-pool pod probes the writer's :9090/:9106/:9102 once a second for 150 s. Then reports probe transitions, pool drop→resume, the env check, and the writer startup timeline. |
| `release-roll.sh <prev-worker-tag>` | Waits for the next worker release and its amd64 image. Copies GHCR→AR and refuses to roll if the digests differ. Then runs `writer-seed-proof`, checks seals and prune, and waits for the first execution after the roll (dispatch). |
| `pool-watch.sh <label>` | Prints one line per system-pool pod: restarts, ready, state-builder healthy, resubscribe counts. |
| `enable-prune.sh` | **Historical, one-shot.** Flipped #491 to `enabled` against the 20-segment plan approved on 2026-10-27, and reverted to dry_run on any anomaly. Don't rerun it as-is. |

Never use the old `writer-roll3.sh` pattern. It patched `PRUNE_MODE=dry_run` and would silently switch deletion off.

The worker release workflow's `publish-ar` step always fails, so the GHCR→AR copy in `release-roll.sh` is the real publish step for now.
