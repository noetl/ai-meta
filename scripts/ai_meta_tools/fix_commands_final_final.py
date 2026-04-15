import re

path = "repos/noetl/noetl/core/dsl/engine/executor/commands.py"
with open(path, "r") as f:
    text = f.read()

# I am completely deleting the line 830 overwrite block
old_block = """            loop_state["collection_size"] = len(collection or [])
            loop_state["index"] = max(int(loop_state.get("index", 0) or 0), claimed_index + 1)
            loop_event_id_for_metadata = (
                str(resolved_loop_event_id)
                if resolved_loop_event_id is not None
                else (str(loop_state.get("event_id")) if loop_state.get("event_id") is not None else loop_event_id_for_metadata)
            )
            logger.info("""

new_block = """            loop_state["collection_size"] = len(collection or [])
            loop_state["index"] = max(int(loop_state.get("index", 0) or 0), claimed_index + 1)
            logger.info("""

text = text.replace(old_block, new_block)

with open(path, "w") as f:
    f.write(text)

print("Successfully removed the final destructive epoch ID overwrite from commands.py!")
