import re

with open("repos/noetl/noetl/core/dsl/v2/engine/store.py", "r") as f:
    content = f.read()

if "import yaml" not in content:
    content = content.replace("from __future__ import annotations", "from __future__ import annotations\nimport yaml\nimport json")
    
with open("repos/noetl/noetl/core/dsl/v2/engine/store.py", "w") as f:
    f.write(content)
