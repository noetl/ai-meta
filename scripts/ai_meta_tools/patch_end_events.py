import re

with open("repos/noetl/noetl/core/dsl/v2/engine/events.py", "r") as f:
    lines = f.readlines()

for i, line in enumerate(lines):
    if "return commands" in line and i > len(lines) - 10:
        lines.insert(i, "        await self.state_store.save_state(state, conn)\n")
        break

with open("repos/noetl/noetl/core/dsl/v2/engine/events.py", "w") as f:
    f.writelines(lines)

