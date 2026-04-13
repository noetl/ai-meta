import re

with open("repos/noetl/noetl/server/api/v2.py", "r") as f:
    content = f.read()

# Add state_ref to supervisor_meta
content = content.replace(
    'supervisor_meta = {',
    'supervisor_meta = {\n                        "state_ref": f"state:{cmd.execution_id}",'
)

with open("repos/noetl/noetl/server/api/v2.py", "w") as f:
    f.write(content)

