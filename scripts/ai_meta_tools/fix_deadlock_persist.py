import re

with open("repos/noetl/noetl/core/dsl/v2/engine/events.py", "r") as f:
    content = f.read()

content = re.sub(
    r'await self\._persist_event\(([^,]+),\s*state\)',
    r'await self._persist_event(\1, state, conn=conn)',
    content
)

with open("repos/noetl/noetl/core/dsl/v2/engine/events.py", "w") as f:
    f.write(content)

