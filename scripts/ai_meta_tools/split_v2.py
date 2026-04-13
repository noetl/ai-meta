import ast
import os
import shutil

v2_path = "repos/noetl/noetl/server/api/v2.py"
pkg_dir = "repos/noetl/noetl/server/api/v2"

if not os.path.exists(pkg_dir):
    os.makedirs(pkg_dir)

with open(v2_path, "r") as f:
    source = f.read()

# I will just write a very simple AST splitter or grep-based splitter.
# Actually, the file is 3400 lines long. It's safer to use regex and line numbers to split it into 5 files.

lines = source.split("\n")

def get_block(start_match, end_match_next_def):
    start_idx = -1
    for i, line in enumerate(lines):
        if line.startswith(start_match):
            start_idx = i
            break
    if start_idx == -1: return ""
    
    end_idx = len(lines)
    for i in range(start_idx + 1, len(lines)):
        if lines[i].startswith("def ") or lines[i].startswith("async def ") or lines[i].startswith("class ") or lines[i].startswith("@router"):
            end_idx = i
            break
    return "\n".join(lines[start_idx:end_idx])

# A simpler approach: just copy v2.py to v2/__init__.py and be done with it? No, the user wants smaller modules.
