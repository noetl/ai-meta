svc = """apiVersion: v1
kind: Service
metadata:
  name: gui
  namespace: noetl
  labels:
    app: gui
spec:
  type: NodePort
  ports:
  - port: 8080
    targetPort: http
    protocol: TCP
    name: http
    nodePort: 30080
  selector:
    app: gui
"""
with open("repos/ops/ci/manifests/gui/service.yaml", "w") as f:
    f.write(svc)
