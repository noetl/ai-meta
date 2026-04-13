import re

filepath = "repos/noetl/noetl/server/app.py"
with open(filepath, "r") as f:
    content = f.read()

content = re.sub(r"from noetl\.server\.command_reaper import \([^\)]+\)\n", "", content)
content = re.sub(r"from noetl\.server\.stuck_execution_reaper import \([^\)]+\)\n", "", content)

# Look for specific blocks of text and delete them
lines = content.split('\n')
new_lines = []
skip = False
for line in lines:
    if "logger.info(\"Starting command reaper background task...\")" in line:
        skip = True
        # remove previous 2 lines if they belong to this block
        if "try:" in new_lines[-1]: new_lines.pop()
        if "if is_leader:" in new_lines[-1]: new_lines.pop()
        continue
    
    if skip and "logger.info(\"Stuck execution reaper is disabled by configuration\")" in line:
        skip = False
        continue
        
    if skip:
        continue

    new_lines.append(line)

content = '\n'.join(new_lines)
with open(filepath, "w") as f:
    f.write(content)
