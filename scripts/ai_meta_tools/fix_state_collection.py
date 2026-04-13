import os

with open("noetl/core/dsl/engine/engine/state.py", "r") as f:
    content = f.read()

# Fix indentation and logic
old_block = """            collection_size = len(loop_state["collection"]) if "collection" in loop_state else int(loop_state.get("collection_size", 0))
                iter_vars["_last"] = loop_state["index"] >= (collection_size - 1)"""

new_block = """            # Use collection_size if collection is missing (due to persistence optimization)
            collection_size = len(loop_state["collection"]) if "collection" in loop_state else int(loop_state.get("collection_size", 0))
            iter_vars["_last"] = loop_state["index"] >= (collection_size - 1)"""

content = content.replace(old_block, new_block)

with open("noetl/core/dsl/engine/engine/state.py", "w") as f:
    f.write(content)
