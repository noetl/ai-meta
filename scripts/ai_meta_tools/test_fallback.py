import re

path = "repos/noetl/noetl/core/dsl/engine/executor/commands.py"
with open(path, "r") as f:
    text = f.read()

# Disable local fallback claim logic that skips index 0!
old_block = """                    if scheduled_count < len(collection or []) and (scheduled_count - completed_count) < max_in_flight:
                        claimed_index = scheduled_count
                        loop_state["scheduled_count"] = scheduled_count + 1"""

new_block = """                    if scheduled_count < len(collection or []) and (scheduled_count - completed_count) < max_in_flight:
                        # Disable local fallback for batch loops to prevent index 0 skipping!
                        pass"""

text = text.replace(old_block, new_block)
with open(path, "w") as f:
    f.write(text)

