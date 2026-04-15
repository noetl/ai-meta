import os
import re

files = [
    "repos/noetl/noetl/core/dsl/engine/executor/events.py",
    "repos/noetl/noetl/core/dsl/engine/executor/commands.py",
    "repos/noetl/noetl/core/dsl/engine/executor/transitions.py",
    "repos/noetl/noetl/core/dsl/engine/executor/state.py"
]

for file_path in files:
    with open(file_path, "r") as f:
        lines = f.readlines()
    
    new_lines = []
    for i, line in enumerate(lines):
        if "len(" in line and "logger.error" not in line and "import " not in line:
            # Extract the variable inside len()
            match = re.search(r'len\((.*?)\)', line)
            if match:
                var_name = match.group(1).strip()
                indent = line[:len(line) - len(line.lstrip())]
                # Add debug log before the line
                new_lines.append(f"{indent}if ({var_name}) is None:\n")
                new_lines.append(f"{indent}    import logging\n")
                new_lines.append(f"{indent}    logging.getLogger('noetl').error(f'--- LEN_FAILURE at {os.path.basename(file_path)}:{i+1}: variable \"{var_name}\" is None')\n")
        new_lines.append(line)
    
    with open(file_path, "w") as f:
        f.writelines(new_lines)
    print(f"Added deep debug to {file_path}")

