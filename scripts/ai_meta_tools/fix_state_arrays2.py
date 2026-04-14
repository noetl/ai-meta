import re

with open("repos/noetl/noetl/core/dsl/engine/executor/state.py", "r") as f:
    text = f.read()

# Fix get_render_context "length": len(loop_state["collection"])
text = re.sub(
    r'"length": len\(loop_state\["collection"\]\),',
    r'"length": loop_state.get("collection_size", 0),',
    text
)

# Fix add_loop_result
pattern = r"""        loop_state\["last_result"\] = _compact_loop_result\(result\)
        
        if failed:
            loop_state\["failed_count"\] \+= 1"""
replacement = """        loop_state["last_result"] = _compact_loop_result(result)
        loop_state["completed_count"] = loop_state.get("completed_count", 0) + 1
        
        if failed:
            loop_state["failed_count"] += 1"""
text = re.sub(pattern, replacement, text)

with open("repos/noetl/noetl/core/dsl/engine/executor/state.py", "w") as f:
    f.write(text)
print("Updated state.py")
