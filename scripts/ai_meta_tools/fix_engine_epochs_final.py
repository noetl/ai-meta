import re

path = "repos/noetl/noetl/core/dsl/engine/executor/transitions.py"
with open(path, "r") as f:
    text = f.read()

old_block = """        existing_loop_state = state.loop_state.get(step_def.step)
        loop_event_id = str(existing_loop_state.get("event_id") or "") if existing_loop_state else ""
        
        collection = None"""

# Ensure the batch claimer uses a totally fresh epoch ID for new batches!
new_block = """        existing_loop_state = state.loop_state.get(step_def.step)
        loop_event_id = str(existing_loop_state.get("event_id") or "") if existing_loop_state else ""
        
        # PERFORMANCE & CORRECTNESS FIX: If this is a fresh entry into the loop (not a continuation),
        # force a completely new epoch ID *before* we batch claim the NATS slots.
        if existing_loop_state and not step_input.get("__loop_continue") and not step_input.get("__loop_retry"):
            import time
            loop_event_id = f"loop_{state.last_event_id or time.time_ns()}"
        
        collection = None"""

text = text.replace(old_block, new_block)

with open(path, "w") as f:
    f.write(text)

path = "repos/noetl/noetl/core/dsl/engine/executor/commands.py"
with open(path, "r") as f:
    text = f.read()

# Disable the conflicting mid-loop epoch reset
old_block2 = """                if (nats_size > 0 and nats_completed >= nats_size and nats_scheduled >= nats_size) or nats_loop_done_claimed:
                    loop_event_id = f"loop_{state.last_event_id or time.time_ns()}"
                    state.init_loop(
                        step.step,
                        collection,
                        step.loop.iterator,
                        step.loop.mode,
                        event_id=loop_event_id,
                    )"""

new_block2 = """                if (nats_size > 0 and nats_completed >= nats_size and nats_scheduled >= nats_size) or nats_loop_done_claimed:
                    # Let transitions.py handle the epoch ID!
                    loop_event_id = loop_event_id_for_metadata or f"loop_{state.last_event_id or time.time_ns()}"
                    state.init_loop(
                        step.step,
                        collection,
                        step.loop.iterator,
                        step.loop.mode,
                        event_id=loop_event_id,
                    )"""

text = text.replace(old_block2, new_block2)

with open(path, "w") as f:
    f.write(text)

print("Successfully synchronized epoch generation between transitions.py and commands.py")
