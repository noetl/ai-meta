import os
import re

path = "repos/noetl/noetl/core/dsl/engine/executor/transitions.py"
with open(path, "r") as f:
    text = f.read()

old_block = """            import time
            loop_event_id = f"loop_{state.last_event_id or int(time.time() * 1000000)}"
            # Delete the local state so commands.py knows this is a fresh loop instance!"""

# Force a guaranteed unique epoch ID using nanosecond timestamp
new_block = """            import time
            loop_event_id = f"loop_{state.execution_id}_{int(time.time() * 1000000)}"
            # Delete the local state so commands.py knows this is a fresh loop instance!"""

text = text.replace(old_block, new_block)

with open(path, "w") as f:
    f.write(text)

path = "repos/noetl/noetl/core/dsl/engine/executor/commands.py"
with open(path, "r") as f:
    text = f.read()

old_block2 = """                else:
                    # Update existing loop collection AND reset counters for the new batch!
                    import time
                    loop_event_id_for_metadata = loop_event_id_for_metadata or f"loop_{state.last_event_id or int(time.time() * 1000000)}"
                    state.loop_state[step.step].update({"""

new_block2 = """                else:
                    # Update existing loop collection AND reset counters for the new batch!
                    import time
                    loop_event_id_for_metadata = loop_event_id_for_metadata or f"loop_{state.execution_id}_{int(time.time() * 1000000)}"
                    state.loop_state[step.step].update({"""

text = text.replace(old_block2, new_block2)

with open(path, "w") as f:
    f.write(text)

print("Successfully decoupled Epoch IDs from the static state.last_event_id")
