import os
path = "repos/noetl/noetl/core/dsl/engine/executor/commands.py"
with open(path, "r") as f:
    lines = f.readlines()

for i, line in enumerate(lines):
    if "len(collection)" in line and "dir()" not in line:
        indent = line[:len(line) - len(line.lstrip())]
        lines[i] = f"{indent}try:\n{indent}    _tmp_len = len(collection)\n{indent}except Exception as e:\n{indent}    logger.error(f'LEN_FAILURE at line {i+1}: {{e}} | step={{step.step}} | has_loop={{step.loop is not None}}')\n{indent}    raise e\n{line.replace('len(collection)', '_tmp_len')}"

with open(path, "w") as f:
    f.writelines(lines)
print("Added debug logging to commands.py")
