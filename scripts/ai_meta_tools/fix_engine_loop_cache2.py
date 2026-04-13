import re

filepath = "repos/noetl/noetl/core/dsl/v2/engine.py"
with open(filepath, "r") as f:
    content = f.read()

target = """                elif epoch_relative_count == 0 and completed_count > 0 and (completed_count % snapshot_epoch_size) == 0:
                    epoch_relative_count = snapshot_epoch_size
                loop_state["results"] = []"""

replacement = """                elif epoch_relative_count == 0 and completed_count > 0 and (completed_count % snapshot_epoch_size) == 0:
                    epoch_relative_count = snapshot_epoch_size
                
                # CRITICAL: Do NOT clear results if we are just reconciling counts mid-epoch. 
                # This only triggers if we explicitly want to strip stale cache data (e.g. crossing).
                # The issue was setting loop_state['results'] = [] unconditionally.
                # Actually, `completed_count` logic is used to jump ahead if we missed events.
                # Only clear results if we actually changed epochs.
                if loop_state.get("event_id") != cached_event_id:
                    loop_state["results"] = []
                elif "results" not in loop_state:
                    loop_state["results"] = []"""

if target in content:
    content = content.replace(target, replacement)
    with open(filepath, "w") as f:
        f.write(content)
    print("Patched successfully!")
else:
    print("Target not found!")
