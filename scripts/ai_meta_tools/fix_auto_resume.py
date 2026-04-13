with open("noetl/server/auto_resume.py", "r") as f:
    lines = f.readlines()

new_lines = []
for line in lines:
    if "from noetl.server.api.core import execute, ExecuteRequest" in line:
        indent = line[:line.find("from")]
        new_lines.append(f"{indent}from noetl.server.api.core.execution import execute\n")
        new_lines.append(f"{indent}from noetl.server.api.core.models import ExecuteRequest\n")
    elif "from noetl.server.api.core import get_nats_publisher" in line:
        indent = line[:line.find("from")]
        new_lines.append(f"{indent}from noetl.server.api.core.core import get_nats_publisher\n")
    else:
        new_lines.append(line)

with open("noetl/server/auto_resume.py", "w") as f:
    f.writelines(new_lines)
