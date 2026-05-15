# Muno GKE UI Removed

Kadyapam decided Muno should follow the existing Cloudflare Pages frontend
pattern (like `adiona/team4`) instead of staying as a GKE-hosted UI.

Actions completed:

- Deleted the live `muno` namespace on GKE with `kubectl delete namespace muno
  --wait=false`.
- This removes the Muno Deployment, Service, GKE Ingress, ManagedCertificate,
  and `ghcr-pull` secret from the cluster.
- `noetl/ops#88` merged at `be91035599e62f89fa5b9da229aa15e8c383d53b`,
  deleting `ci/manifests/muno/*` so future ops manifest sweeps do not recreate
  the UI deployment.

State observed after deletion:

- `ManagedCertificate` resources for Muno were gone.
- The namespace was still `Terminating` while GKE cleaned up the Ingress/load
  balancer finalizer. This is expected to take a few minutes.

Next hosting direction:

- Deploy Muno as a Cloudflare Pages project.
- Point `muno.mestumre.dev` to the Pages hostname with a proxied CNAME.
- Keep GKE for NoETL API/workers/storage, not the Muno static frontend.

