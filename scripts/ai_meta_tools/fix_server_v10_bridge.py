import re

path = "repos/noetl/noetl/server/api/core/commands.py"
with open(path, "r") as f:
    text = f.read()

# Update _build_reference_only_result to support the 'response' key
old_logic = '    payload_result = payload.get("result")'
new_logic = '    payload_result = payload.get("result") or payload.get("response")'

text = text.replace(old_logic, new_logic)

# Also check for direct context in response
text = text.replace(
    'direct_context = _bounded_context(payload.get("context"))',
    'direct_context = _bounded_context(payload.get("context") or payload.get("response", {}).get("context"))'
)

with open(path, "w") as f:
    f.write(text)
print("Successfully patched server commands.py with v10 bridge")
