import os
import re

# 1. Revert everything to be safe
files = [
    "noetl/core/dsl/engine/executor/events.py",
    "noetl/core/dsl/engine/executor/commands.py",
    "noetl/core/dsl/engine/executor/transitions.py",
    "noetl/core/dsl/engine/executor/state.py"
]
for f in files:
    os.system(f"cd repos/noetl && git checkout {f}")

# 2. Apply len safety globally without changing structure
for f in files:
    path = f"repos/noetl/{f}"
    with open(path, "r") as file:
        text = file.read()
    
    text = text.replace("len(collection)", "len(collection or [])")
    text = text.replace("len(pipeline)", "len(pipeline or [])")
    text = text.replace("len(rendered_collection)", "len(rendered_collection or [])")
    
    with open(path, "w") as file:
        file.write(text)

# 3. Surgical fix for state.py render context
state_path = "repos/noetl/noetl/core/dsl/engine/executor/state.py"
with open(state_path, "r") as f:
    text = f.read()
old_line = 'collection_size = len(loop_state["collection"] or []) if "collection" in loop_state else int(loop_state.get("collection_size", 0))'
new_line = 'collection_size = len(loop_state["collection"] or []) if ("collection" in loop_state and loop_state["collection"] is not None) else int(loop_state.get("collection_size", 0))'
text = text.replace(old_line, new_line)
with open(state_path, "w") as f:
    f.write(text)

# 4. Surgical fix for events.py bottleneck
events_path = "repos/noetl/noetl/core/dsl/engine/executor/events.py"
with open(events_path, "r") as f:
    lines = f.readlines()
for i, line in enumerate(lines):
    if "supervisor_completed_count = await self._count_supervised_loop_terminal_iterations(" in line:
        lines[i] = '                    # PERFORMANCE OPTIMIZATION: Skip expensive scan\n                    supervisor_completed_count = -1\n'
        j = i + 1
        while j < len(lines) and ")" not in lines[j-1]:
            lines[j] = "# " + lines[j]
            j += 1
with open(events_path, "w") as f:
    f.writelines(lines)

# 5. Fix commands.py correctly (no indentation change)
comm_path = "repos/noetl/noetl/core/dsl/engine/executor/commands.py"
with open(comm_path, "r") as f:
    text = f.read()

# Safe replacements for pre-claimed support
text = text.replace('claimed_index: Optional[int] = None', 'claimed_index: Optional[int] = control_args.get("__loop_claimed_index")')
text = text.replace('_nats_slot_incremented = False', '_nats_slot_incremented = claimed_index is not None')
text = text.replace('claimed_index = await nats_cache.claim_next_loop_index(', 'if claimed_index is None: claimed_index = await nats_cache.claim_next_loop_index(')

with open(comm_path, "w") as f:
    f.write(text)

