import re

filepath = "repos/noetl/noetl/core/dsl/v2/engine.py"
with open(filepath, "r") as f:
    content = f.read()

target = """                    loop_state = state.loop_state[step.step]
                    force_new_loop_instance = True
                    loop_event_id_candidates = [loop_event_id]
                    resolved_loop_event_id = loop_event_id
                    nats_loop_state = None"""

replacement = """                    loop_state = state.loop_state[step.step]
                    force_new_loop_instance = True
                    loop_event_id_candidates = [loop_event_id]
                    resolved_loop_event_id = loop_event_id
                    loop_event_id_for_metadata = loop_event_id
                    nats_loop_state = None"""

if target in content:
    content = content.replace(target, replacement)
    with open(filepath, "w") as f:
        f.write(content)
    print("Patched successfully!")
else:
    print("Target not found!")
