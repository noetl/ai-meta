# Ollama backend on GKE stopped for cost control

Date: 2026-05-12
Status: GREEN

The GKE Ollama backend was intentionally stopped after the option B proof round to avoid ongoing Autopilot cost from the CPU-only `gemma3:4b` pod.

What changed:

- Scaled `deployment/ollama` to zero replicas in namespace `noetl`.
- Applied the state through Helm release `noetl` revision `130` with `ollama.enabled=true` and `ollama.replicas=0`.
- Kept `service/ollama` and PVC `ollama-data` in place.
- Merged `noetl/ops#76`, which fixes the Helm template so `ollama.replicas=0` is respected instead of being converted to `1` by Helm's `default` helper.
- ai-meta now points `repos/ops` at `64a74798b6140a65d08e40d8f6d6217b65709196`.

Verified state:

- `deployment.apps/ollama` is `0/0`.
- No pods match `app=ollama`.
- `service/ollama` still resolves inside the namespace.
- `persistentvolumeclaim/ollama-data` remains `Bound` at 20Gi.
- `ollama-bridge` remains running, so routing is still present but backend inference is unavailable until re-enabled.

Expected runtime behavior while stopped:

- `travel --provider ollama ...` should fall back to OpenAI.
- The fallback reason should mention the missing/unreachable Ollama backend.
- This is expected and cost-saving, not a regression.

Re-provisioning runbook:

```bash
cd /Volumes/X10/projects/noetl/ai-meta/repos/ops

helm upgrade noetl automation/helm/noetl \
  --namespace noetl \
  --kube-context gke_noetl-demo-19700101_us-central1_noetl-cluster \
  --reuse-values \
  --set ollama.enabled=true \
  --set ollama.replicas=1 \
  --set ollama.resources.requests.memory=8Gi \
  --set ollama.resources.limits.memory=10Gi

kubectl --context gke_noetl-demo-19700101_us-central1_noetl-cluster \
  -n noetl rollout status deployment/ollama --timeout=420s

kubectl --context gke_noetl-demo-19700101_us-central1_noetl-cluster \
  -n noetl exec deploy/ollama -- ollama list
```

If `gemma3:4b` is missing, pull it into the retained PVC:

```bash
kubectl --context gke_noetl-demo-19700101_us-central1_noetl-cluster \
  -n noetl exec deploy/ollama -- ollama pull gemma3:4b
```

Then verify routing with a direct backend probe from `ollama-bridge` and run:

```text
travel --provider ollama help
travel --provider ollama activities near Times Square
```

Expected result when re-enabled: `effective_provider=ollama`, no fallback reason, widget rendered. Expect high CPU latency, roughly one minute in the classifier child execution.

To stop it again after a test window, run the same Helm command with `--set ollama.replicas=0`.
