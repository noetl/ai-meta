# GUI Kubernetes MCP deployed and verified
- Timestamp: 2026-04-26T23:54:44Z
- Author: Kadyapam
- Tags: gui,ops,mcp,kubernetes,kind,release

## Summary
After ops PR #10 and gui PR #10 merged, gui main needed a conventional empty release trigger commit because semantic-release skipped the non-conventional merge subject. GUI release/image v1.0.7 was published and deployed to local kind with Kubernetes MCP runtime env pointing at the in-cluster kubernetes-mcp-server. Ops playbook automation/development/mcp_kubernetes.yaml deployed quay.io/containers/kubernetes_mcp_server:v0.0.61 in namespace mcp. Browser validation at http://localhost:38081/catalog confirmed GUI terminal commands: mcp status reported kubernetes healthy with 13 tools, k8s namespaces listed local namespaces, and k8s pods mcp returned kubernetes-mcp-server 1/1 Running.

## Actions
- Published `repos/gui` release/image `v1.0.7` via conventional release-trigger commit `4a9592a`.
- Deployed Kubernetes MCP server with `repos/ops/automation/development/mcp_kubernetes.yaml --set action=deploy`.
- Deployed GUI with `repos/ops/automation/development/gui.yaml --set image_repository=ghcr.io/noetl/gui --set image_tag=v1.0.7 --set mcp_kubernetes_url=/mcp/kubernetes --set mcp_kubernetes_upstream=http://kubernetes-mcp-server.mcp.svc.cluster.local:8080`.
- Verified `/env-config.js`, `/mcp/kubernetes/healthz`, raw MCP initialize through the GUI proxy, and GUI terminal commands in the browser.

## Repos
- `repos/gui`: `4a9592a` (`fix: release kubernetes mcp terminal`)
- `repos/ops`: `e740ae6` (`Merge pull request #10 from noetl/kadyapam/kubernetes-mcp-runtime-deploy`)

## Related
- GUI PR `noetl/gui#10`
- Ops PR `noetl/ops#10`
