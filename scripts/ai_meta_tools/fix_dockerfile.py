filepath = "repos/noetl/docker/noetl/dev/Dockerfile"
with open(filepath, "r") as f:
    content = f.read()

import re

# Remove UI builder stage
content = re.sub(r"FROM node:20-alpine AS ui-builder[\s\S]*?RUN cd ui-src && npm run build\n\n", "", content)

# Remove UI copy step
content = re.sub(r"COPY --from=ui-builder \/ui\/ui-src\/dist \.\/noetl\/core\/ui\n\n", "", content)

# Remove NOETL_ENABLE_UI env var
content = re.sub(r"ENV NOETL_ENABLE_UI=false\n\n", "", content)

with open(filepath, "w") as f:
    f.write(content)
