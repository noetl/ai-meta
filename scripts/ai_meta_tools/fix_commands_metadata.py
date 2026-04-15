import re

path = "repos/noetl/noetl/core/dsl/engine/executor/commands.py"
with open(path, "r") as f:
    text = f.read()

# Remove the destructive assignment that overwrote the passed epoch ID
old_block = """            loop_state = existing_loop_state
            loop_event_id_for_metadata = (
                str(loop_state.get("event_id"))
                if loop_state.get("event_id") is not None
                else None
            )

            # Resolve distributed loop key candidates.
            if force_new_loop_instance:
                loop_event_id_for_metadata = loop_state.get("event_id")"""

new_block = """            loop_state = existing_loop_state
            # Preserving the passed epoch ID from transitions.py!
            loop_event_id_for_metadata = loop_event_id_for_metadata or (
                str(loop_state.get("event_id"))
                if loop_state.get("event_id") is not None
                else None
            )

            # Resolve distributed loop key candidates.
            if force_new_loop_instance:
                loop_event_id_for_metadata = loop_event_id_for_metadata or loop_state.get("event_id")"""

text = text.replace(old_block, new_block)

with open(path, "w") as f:
    f.write(text)

print("Successfully preserved the passed Epoch ID!")
