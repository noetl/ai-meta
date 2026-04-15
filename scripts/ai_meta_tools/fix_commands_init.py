import re

path = "repos/noetl/noetl/core/dsl/engine/executor/commands.py"
with open(path, "r") as f:
    text = f.read()

# Fix the local state initialization to use the passed epoch ID from transitions.py!
old_block = """            if existing_loop_state is None:
                loop_event_id = f"loop_{state.last_event_id or time.time_ns()}_{time.time_ns()}"
                state.init_loop("""

new_block = """            if existing_loop_state is None:
                import time
                loop_event_id = loop_event_id_for_metadata or f"loop_{state.execution_id}_{int(time.time() * 1000000)}"
                state.init_loop("""

text = text.replace(old_block, new_block)

# Also fix the one at line 267 just in case!
old_block2 = """                        loop_event_id = f"loop_{state.last_event_id or time.time_ns()}_{time.time_ns()}"
                        state.init_loop("""

new_block2 = """                        import time
                        loop_event_id = loop_event_id_for_metadata or f"loop_{state.execution_id}_{int(time.time() * 1000000)}"
                        state.init_loop("""

text = text.replace(old_block2, new_block2)

with open(path, "w") as f:
    f.write(text)

print("Successfully fixed commands.py initialization to use the passed Epoch ID!")
