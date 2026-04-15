import re

path = "repos/noetl/noetl/server/api/core/commands.py"
with open(path, "r") as f:
    lines = f.readlines()

for i, line in enumerate(lines):
    if 'context = _bounded_context(payload_result.get("context"))' in line:
        indent = line[:len(line) - len(line.lstrip())]
        lines[i] = f"{indent}context = _bounded_context(payload_result.get('context') or payload_result)\n"
    if 'direct_context = _bounded_context(payload.get("context")' in line:
        indent = line[:len(line) - len(line.lstrip())]
        lines[i] = f"{indent}direct_context = _bounded_context(payload.get('context') or payload.get('response') or payload)\n"

with open(path, "w") as f:
    f.writelines(lines)
print("Successfully patched server commands.py v2")
