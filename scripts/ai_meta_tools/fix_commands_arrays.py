import re

with open("repos/noetl/noetl/core/dsl/engine/executor/commands.py", "r") as f:
    text = f.read()

# existing_loop_state["collection"] = list(collection)
text = re.sub(
    r'existing_loop_state\["collection"\] = list\(collection\)',
    r'existing_loop_state["collection_size"] = len(collection) if hasattr(collection, "__len__") else 0',
    text
)

# previous_collection = existing_loop_state.get("collection")
text = re.sub(
    r'previous_collection = existing_loop_state\.get\("collection"\)',
    r'previous_size = existing_loop_state.get("collection_size", 0)',
    text
)

# if isinstance(existing_loop_state.get("collection"), list) and len(existing_loop_state.get("collection") or []) > 0
text = re.sub(
    r'and isinstance\(existing_loop_state\.get\("collection"\), list\)\s+and len\(existing_loop_state\.get\("collection"\) or \[\]\) > 0',
    r'and existing_loop_state.get("collection_size", 0) > 0',
    text
)

with open("repos/noetl/noetl/core/dsl/engine/executor/commands.py", "w") as f:
    f.write(text)
print("Updated commands.py")
