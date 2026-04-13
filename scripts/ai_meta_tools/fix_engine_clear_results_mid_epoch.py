import re

filepath = "repos/noetl/noetl/core/dsl/v2/engine.py"
with open(filepath, "r") as f:
    content = f.read()

target = """                elif epoch_relative_scheduled == 0 and scheduled_count > 0 and (scheduled_count % snapshot_epoch_size) == 0:
                    epoch_relative_scheduled = snapshot_epoch_size
                loop_state["results"] = []
                loop_state["omitted_results_count"] = epoch_relative_count"""

replacement = """                elif epoch_relative_scheduled == 0 and scheduled_count > 0 and (scheduled_count % snapshot_epoch_size) == 0:
                    epoch_relative_scheduled = snapshot_epoch_size
                
                # Do NOT unconditionally clear results array here. 
                # This causes the engine to forget completed iterations if the rebuilt epoch matches the cached epoch.
                # Only collapse the array if we are synthesizing an entirely new relative count and missing the granular results.
                # It is safer to truncate to omitted_results_count=epoch_relative_count if and only if we truly lost the granular results.
                # However, load_state ALREADY properly clears `results` when crossing an epoch boundary (via command.issued).
                # The only time we are here is if the cross-epoch total leaked into the current iteration state.
                if len(loop_state.get("results", [])) > epoch_relative_count:
                    loop_state["results"] = loop_state.get("results", [])[-epoch_relative_count:]
                loop_state["omitted_results_count"] = max(0, epoch_relative_count - len(loop_state.get("results", [])))"""

if target in content:
    content = content.replace(target, replacement)
    with open(filepath, "w") as f:
        f.write(content)
    print("Patched successfully!")
else:
    print("Target not found!")
