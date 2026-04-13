with open("noetl/server/api/core/recovery.py", "r") as f:
    lines = f.read().split('\n')

for i, line in enumerate(lines):
    if "await asyncio.gather" in line:
        # Check indentation of the previous line and match it
        prev_indent = ""
        if i > 0:
            for char in lines[i-1]:
                if char.isspace(): prev_indent += char
                else: break
        lines[i] = prev_indent + line.lstrip()

with open("noetl/server/api/core/recovery.py", "w") as f:
    f.write('\n'.join(lines))
