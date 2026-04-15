import re

path = "repos/noetl/noetl/core/dsl/engine/executor/transitions.py"
with open(path, "r") as f:
    text = f.read()

old_block = """        # PERFORMANCE & CORRECTNESS FIX: If this is a fresh entry into the loop (not a continuation),
        # force a completely new epoch ID *before* we batch claim the NATS slots.
        if existing_loop_state and not step_input.get("__loop_continue") and not step_input.get("__loop_retry"):
            import time
            loop_event_id = f"loop_{state.execution_id}_{int(time.time() * 1000000)}"
            # Delete the local state so commands.py knows this is a fresh loop instance!
            del state.loop_state[step_def.step]
            existing_loop_state = None"""

new_block = """        # PERFORMANCE & CORRECTNESS FIX: If this is a fresh entry into the loop (not a continuation),
        # force a completely new epoch ID *before* we batch claim the NATS slots.
        if not existing_loop_state or (not step_input.get("__loop_continue") and not step_input.get("__loop_retry")):
            import time
            loop_event_id = f"loop_{state.execution_id}_{int(time.time() * 1000000)}"
            # Delete the local state so commands.py knows this is a fresh loop instance!
            if existing_loop_state:
                del state.loop_state[step_def.step]
            existing_loop_state = None"""

text = text.replace(old_block, new_block)

with open(path, "w") as f:
    f.write(text)

print("Successfully synchronized epoch ID generation for the FIRST batch as well!")
