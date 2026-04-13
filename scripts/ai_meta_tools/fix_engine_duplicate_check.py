import re

filepath = "repos/noetl/noetl/core/dsl/v2/engine.py"
with open(filepath, "r") as f:
    content = f.read()

target = """                            loop_event_id = event_payload.get("loop_event_id")
                            if not loop_event_id and isinstance(response_data, dict):
                                loop_event_id = response_data.get("loop_event_id")
                            if loop_event_id:
                                loop_event_ids[loop_step_name] = str(loop_event_id)"""

replacement = """                            loop_event_id = event_payload.get("loop_event_id")
                            if not loop_event_id and isinstance(response_data, dict):
                                loop_event_id = response_data.get("loop_event_id")
                            if loop_event_id:
                                # Protect against late call.done events from previous epochs
                                # overwriting the active epoch ID (which corrupts the loop state).
                                existing_id = loop_event_ids.get(loop_step_name)
                                if not existing_id or str(loop_event_id) >= existing_id:
                                    loop_event_ids[loop_step_name] = str(loop_event_id)"""

if target in content:
    content = content.replace(target, replacement)
    with open(filepath, "w") as f:
        f.write(content)
    print("Patched successfully!")
else:
    print("Target not found!")
