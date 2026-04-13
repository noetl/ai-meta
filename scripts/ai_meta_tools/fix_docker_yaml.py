import re
filepath = "repos/ops/automation/development/docker.yaml"
with open(filepath, "r") as f:
    content = f.read()

content = content.replace(
    'docker build -t "local/gui:$IMAGE_TAG" -f "$GUI_REPO/Dockerfile" "$GUI_REPO"',
    'docker build --build-arg VITE_API_MODE=direct -t "local/gui:$IMAGE_TAG" -f "$GUI_REPO/Dockerfile" "$GUI_REPO"'
)

with open(filepath, "w") as f:
    f.write(content)
