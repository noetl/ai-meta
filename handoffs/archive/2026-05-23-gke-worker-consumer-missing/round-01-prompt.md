---
thread: 2026-05-23-gke-worker-consumer-missing
round: 1
from: claude
to: codex
created: 2026-05-24T00:00:00Z
status: open
expects_result_at: round-01-result.md
---

# Diagnose why noetl-worker on GKE leaves its durable NATS consumer missing

You are operating in `/Volumes/X10/projects/noetl/ai-meta`. Read
`handoffs/README.md` and `agents/rules/handoffs.md` first.

## Context

In the previous round
(`handoffs/active/2026-05-23-gke-provision-validation/round-01-result.md`)
you found that on the live GKE cluster:

- `noetl-worker` pods were `1/1 Running` (8 pods after KEDA
  scale-up).
- The NATS stream `NOETL_COMMANDS` had **2,161 retained
  messages** and **no consumers defined at all**.
- You manually created durable pull consumer
  `noetl_worker_pool` with pull mode, `deliver=new`,
  `ack_wait=15m30s`, `max_ack_pending=64`, `max_deliver=1000`,
  and only then did the worker pool start draining and KEDA
  start reporting lag.

The worker subscriber code
(`noetl/core/messaging/nats_client.py`, `NATSCommandSubscriber`)
**should not silently fail to create the consumer**. The flow:

```
worker.start()
  → NATSCommandSubscriber.connect()
  → NATSCommandSubscriber.subscribe(callback):
       try:
         js.stream_info(stream)  or  js.add_stream(...)
         await self._ensure_consumer()
         self._subscription = await js.pull_subscribe(subject, durable=...)
         while True: fetch + dispatch
       except Exception: logger.error(...); raise   # ← re-raises
```

Every error path either succeeds or raises out of
`subscribe()`. If consumer creation fails, the worker should
crash. So observing `1/1 Running` workers + no consumer + no
crash-loop is a contradiction that needs ground-truth evidence
from the live cluster to resolve.

## Hypotheses to test (in priority order)

1. **Worker container is launched with a different command on
   GKE.** Helm chart may run `noetl-server`, a different
   module, or omit the NATS subscriber entirely.
2. **Workers are crash-looping**, and the `1/1 Running`
   snapshot was a brief window between restarts.
3. **The image / env is different** from local kind — the
   GKE image is the May-20 `e3db3624` (`v2.88.1`) tag; the
   Helm chart may set env vars that disable parts of the
   worker, or the May-20 subscriber init path differs in some
   subtle way.
4. **Workers connect to a different NATS instance** than the
   one you observed (maybe the Helm chart wires the worker to
   one NATS service while you inspected another — `nats` vs
   `nats-headless`, or even a separate StatefulSet).

## Phases

### Phase A — capture ground truth

1. Auth + confirm context:
   ```
   gcloud container clusters get-credentials noetl-cluster \
     --region us-central1 --project noetl-demo-19700101
   kubectl config current-context  # → gke_noetl-demo-19700101_us-central1_noetl-cluster
   ```

2. **Container command + args + image** (Hypothesis 1):
   ```
   kubectl get deploy noetl-worker -n noetl -o yaml \
     > /tmp/worker-deploy.yaml
   kubectl get deploy noetl-worker -n noetl \
     -o jsonpath='{range .spec.template.spec.containers[*]}name={.name}{"\n"}command={.command}{"\n"}args={.args}{"\n"}image={.image}{"\n\n"}{end}'
   ```
   Capture verbatim. Expected from
   `repos/ops/ci/manifests/noetl/worker-deployment.yaml`:
   `command: ["python"]`, `args: ["-m", "noetl.worker"]`.
   Any divergence is the answer to Hypothesis 1.

3. **Restart count + recent events** (Hypothesis 2):
   ```
   kubectl get pods -n noetl -l app=noetl-worker \
     -o jsonpath='{range .items[*]}name={.metadata.name} ready={.status.containerStatuses[0].ready} restarts={.status.containerStatuses[0].restartCount} age={.status.startTime}{"\n"}{end}'
   kubectl describe pod -n noetl -l app=noetl-worker \
     --max-items 1 | head -80
   ```
   High restart counts or `Last State: Terminated reason=Error`
   confirm crash-looping.

4. **Worker env vars** (Hypothesis 3):
   ```
   POD=$(kubectl get pod -n noetl -l app=noetl-worker -o jsonpath='{.items[0].metadata.name}')
   kubectl exec -n noetl "$POD" -- env \
     | grep -E "NATS_|NOETL_|NOETL_RUN_MODE" \
     | sort
   ```
   Compare against the kind cluster's worker env (we have a
   `repos/ops/ci/manifests/noetl/configmap-worker.yaml`
   baseline). Anything missing or differently set is a clue.

5. **What NATS the worker actually points at** (Hypothesis 4):
   ```
   kubectl exec -n noetl "$POD" -- /bin/sh -c \
     'cat /tmp/worker_config.txt' 2>/dev/null  || true
   ```
   The worker writes its config to `/tmp/worker_config.txt`
   on startup. Capture verbatim — that's the actual
   `nats_url` and `server_url` it's using.

6. **All NATS-shaped services in the cluster** (Hypothesis 4):
   ```
   kubectl get svc -A | grep -i nats
   kubectl get statefulset -A | grep -i nats
   ```

7. **Worker logs** (always-useful):
   ```
   kubectl logs -n noetl "$POD" --tail=200 | head -100
   kubectl logs -n noetl "$POD" --previous --tail=50 \
     2>/dev/null | head  # if it has restarted
   ```
   Look for `Subscribe failed`, `Created NATS consumer`,
   `Connected to NATS`, or any traceback.

### Phase B — analyze + identify the root cause

8. Based on Phase A evidence, classify which hypothesis is
   correct (or document a new one).
9. If Hypothesis 1: capture the Helm chart command. Note
   whether the chart is in `repos/ops/helm/` or fetched from
   a remote chart repo.
10. If Hypothesis 2: capture the crash reason + count.
11. If Hypothesis 3: diff the env against
    `repos/ops/ci/manifests/noetl/configmap-worker.yaml` line
    by line.
12. If Hypothesis 4: trace the actual NATS endpoint the
    worker connects to vs. what KEDA was reading from.

### Phase C — propose a fix

13. Write a focused fix for the root cause. Examples:
    - **If Hypothesis 1 (Helm command override):** the fix
      lives in the Helm chart values, not application code.
      Patch the Helm chart so it launches `noetl.worker`
      correctly, OR document that GKE-Helm is a different
      deploy shape and the consumer needs to be provisioned
      by a separate `Job` / `StatefulSet`.
    - **If Hypothesis 2 (crash-loop):** fix whatever the
      worker is crashing on. Likely a missing env var
      (e.g. `NOETL_SERVER_URL`) or an unreachable NATS.
    - **If Hypothesis 3 (env difference):** patch the
      missing env var in the Helm chart or document the
      required env contract.
    - **If Hypothesis 4 (wrong NATS):** patch the worker's
      `NATS_URL` env to point at the actual NATS service
      that holds `NOETL_COMMANDS`.

14. If the fix touches application code (e.g. the subscriber
    should be more defensive about pull_subscribe failing),
    open a PR against `noetl/noetl` with the diff +
    explanation. **Do not merge.**

15. If the fix is config-only (Helm values, manifest patch),
    document the exact change inline in the result and open
    a focused handoff to land it.

### Phase D — verify

16. After the fix is applied (in the cluster, not just in
    a PR), restart the noetl-worker pods:
    ```
    kubectl rollout restart deployment/noetl-worker -n noetl
    kubectl rollout status deployment/noetl-worker -n noetl
    ```
17. Confirm the consumer gets created automatically:
    ```
    kubectl exec -n noetl nats-box -- nats --server <url> \
      consumer ls NOETL_COMMANDS
    # Expected: noetl_worker_pool present, owned by ... worker pods
    ```
18. Optional: delete the manually-created consumer first
    (`nats consumer rm`), restart, confirm the worker
    recreates it.

## What to report

`round-01-result.md` body — one H2 per Phase A–D plus
`## Root cause` and `## Issues observed`.

Specifically include:

- The worker `command` + `args` + image (Phase A.2).
- Worker pod restart counts + last-restart reason (Phase A.3).
- The worker's actual `NATS_URL` + `server_url` from
  `/tmp/worker_config.txt` (Phase A.5).
- The first 50 lines of worker logs starting at process start
  (look for `Starting Core worker`, `Connected to NATS`,
  `Subscribe failed`).
- One of the four hypotheses confirmed (or a new one).
- A concrete fix proposal with the exact diff or kubectl
  command(s) needed.

## Hard rules

- **No PR merges from this round.** Open with summaries; stop.
- **No secrets in any file under ai-meta.** GCP service
  account JSON, kubeconfigs, etc. stay out of the repo.
- **Read-only against the cluster as much as possible.**
  Don't restart the workers until Phase D (so we can see
  the broken state). The earlier round's manually-created
  consumer can stay; we want to see if a *fresh* worker
  creates one independently.

## What success looks like

- One of the four hypotheses confirmed, with concrete
  evidence (logs, env, command output).
- A fix proposal that future cluster turnovers can apply
  without needing a manual `nats consumer add` step.
- A clear answer for whether this is an application bug, a
  Helm-chart misconfiguration, or a configuration drift.
