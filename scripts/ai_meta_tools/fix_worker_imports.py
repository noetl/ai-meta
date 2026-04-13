with open("noetl/worker/nats_worker.py", "r") as f:
    lines = f.readlines()

# Add imports after first docstring
import_index = 0
for i, line in enumerate(lines):
    if 'import asyncio' in line:
        import_index = i
        break

new_imports = [
    "from jinja2 import Environment, BaseLoader\n",
    "from noetl.core.dsl.render import add_b64encode_filter\n"
]

for imp in reversed(new_imports):
    lines.insert(import_index, imp)

with open("noetl/worker/nats_worker.py", "w") as f:
    f.writelines(lines)
