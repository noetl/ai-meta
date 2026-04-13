import re
filepath = "repos/ops/automation/development/gui.yaml"
with open(filepath, "r") as f:
    content = f.read()

content = content.replace(
    'docker buildx build --load --platform linux/amd64 \\',
    'docker buildx build --load --platform linux/amd64 \\\n              --build-arg VITE_API_MODE=direct \\'
)

with open(filepath, "w") as f:
    f.write(content)
