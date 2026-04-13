import re

filepath = "repos/noetl/noetl/core/dsl/v2/engine.py"
with open(filepath, "r") as f:
    content = f.read()

target = """            for candidate_event_id in loop_event_id_candidates:
                candidate_state = await nats_cache.get_loop_state(
                    str(state.execution_id),
                    step.step,
                    event_id=candidate_event_id,
                )
                if candidate_state:
                    nats_loop_state = candidate_state
                    resolved_loop_event_id = candidate_event_id
                    loop_state["event_id"] = candidate_event_id
                    break"""

replacement = """            for candidate_event_id in loop_event_id_candidates:
                candidate_state = await nats_cache.get_loop_state(
                    str(state.execution_id),
                    step.step,
                    event_id=candidate_event_id,
                )
                if candidate_state:
                    nats_loop_state = candidate_state
                    resolved_loop_event_id = candidate_event_id
                    loop_state["event_id"] = candidate_event_id
                    loop_event_id_for_metadata = candidate_event_id
                    break"""

if target in content:
    content = content.replace(target, replacement)
    with open(filepath, "w") as f:
        f.write(content)
    print("Patched successfully!")
else:
    print("Target not found!")
