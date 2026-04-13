import os

deploy = """apiVersion: apps/v1
kind: Deployment
metadata:
  name: gui
  namespace: noetl
  labels:
    app: gui
spec:
  replicas: 1
  selector:
    matchLabels:
      app: gui
  template:
    metadata:
      labels:
        app: gui
    spec:
      containers:
      - name: nginx
        image: image_name:image_tag
        imagePullPolicy: IfNotPresent
        env:
        - name: VITE_API_MODE
          value: "direct"
        ports:
        - containerPort: 8080
          name: http
          protocol: TCP
        resources:
          requests:
            memory: "32Mi"
            cpu: "50m"
          limits:
            memory: "128Mi"
            cpu: "200m"
"""

svc = """apiVersion: v1
kind: Service
metadata:
  name: gui
  namespace: noetl
  labels:
    app: gui
spec:
  ports:
  - port: 8080
    targetPort: http
    protocol: TCP
    name: http
  selector:
    app: gui
"""

os.makedirs("repos/ops/ci/manifests/gui", exist_ok=True)
with open("repos/ops/ci/manifests/gui/deployment.yaml", "w") as f:
    f.write(deploy)
with open("repos/ops/ci/manifests/gui/service.yaml", "w") as f:
    f.write(svc)
