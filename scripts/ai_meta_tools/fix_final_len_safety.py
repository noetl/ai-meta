import os
import re

files = [
    "repos/noetl/noetl/core/dsl/engine/executor/state.py",
    "repos/noetl/noetl/core/dsl/engine/executor/rendering.py"
]

for file_path in files:
    with open(file_path, "r") as f:
        text = f.read()
    
    # Replace len(...) with len(... or []) for known collection variables
    text = text.replace('len(loop_state["collection"])', 'len(loop_state["collection"] or [])')
    text = text.replace('len(collection)', 'len(collection or [])')
    text = text.replace('len(cached_collection)', 'len(cached_collection or [])')
    text = text.replace('len(rendered_collection)', 'len(rendered_collection or [])')
    text = text.replace('len(current_collection)', 'len(current_collection or [])')

    with open(file_path, "w") as f:
        f.write(text)
    print(f"Applied safety to {file_path}")

