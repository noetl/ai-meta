import re

with open("repos/noetl/noetl/core/dsl/v2/engine/events.py", "r") as f:
    content = f.read()

# Remove the already_persisted stale-cache logic block
pattern = r'        # Load execution state\. For already-persisted events.*?cache_refreshed = True'

content = re.sub(pattern, '', content, flags=re.DOTALL)

with open("repos/noetl/noetl/core/dsl/v2/engine/events.py", "w") as f:
    f.write(content)

