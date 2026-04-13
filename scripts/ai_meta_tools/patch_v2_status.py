import re

with open("repos/noetl/noetl/server/api/v2.py", "r") as f:
    content = f.read()

content = content.replace(
    "state = engine.state_store.get_state(execution_id)",
    "state = await engine.state_store.load_state(execution_id)"
)

with open("repos/noetl/noetl/server/api/v2.py", "w") as f:
    f.write(content)

