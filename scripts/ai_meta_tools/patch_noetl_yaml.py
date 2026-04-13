import re

filepath = "repos/ops/automation/development/noetl.yaml"
with open(filepath, "r") as f:
    content = f.read()

target = "kubectl apply -f ci/manifests/postgres/service.yaml"
replacement = "kubectl apply -f ci/manifests/postgres/service.yaml\n            kubectl apply -f ci/manifests/postgres/service-external.yaml"

if target in content and "service-external.yaml" not in content:
    content = content.replace(target, replacement)
    with open(filepath, "w") as f:
        f.write(content)
    print("Patched successfully!")
else:
    print("Already patched or target not found!")
