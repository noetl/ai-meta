import re

with open("noetl/core/dsl/engine/engine/transitions.py", "r") as f:
    content = f.read()

# Fix the broken normalization call
broken_part = """            from noetl.core.dsl.engine.executor.commands import CommandEngine
            collection = CommandEngine._normalize_loop_collection(None, collection, step_def.step)"""

fixed_part = "            collection = self._normalize_loop_collection(collection, step_def.step)"

content = content.replace(broken_part, fixed_part)

with open("noetl/core/dsl/engine/engine/transitions.py", "w") as f:
    f.write(content)
