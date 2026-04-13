import re

with open("repos/noetl/noetl/server/api/v2.py", "r") as f:
    lines = f.readlines()

new_lines = []
for i, line in enumerate(lines):
    # Fix the indentation of the command_events.append line I added
    if 'command_events.append((int(execution_id), evt_id, cmd_id, cmd.step))' in line:
        # Check current indentation
        match = re.match(r'^(\s+)', line)
        if match:
            # It should be same as the previous line
            new_lines.append('                    ' + line.strip() + '\n')
        else:
            new_lines.append(line)
    else:
        new_lines.append(line)

# Let's do a more surgical replacement to be safe.
with open("repos/noetl/noetl/server/api/v2.py", "r") as f:
    content = f.read()

content = re.sub(
    r'await cur\.execute\(\"\"\"INSERT INTO noetl\.event.*?datetime\.now\(timezone\.utc\)\)\)\n\s+command_events\.append',
    r'await cur.execute(\"\"\"INSERT INTO noetl.event (execution_id, catalog_id, event_id, event_type, node_id, node_name, node_type, status, context, meta, parent_event_id, parent_execution_id, created_at) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)\"\"\", (int(execution_id), catalog_id, evt_id, "command.issued", cmd.step, cmd.step, cmd.tool.kind, "PENDING", Json(context), Json(meta), root_event_id, req.parent_execution_id, datetime.now(timezone.utc)))\n                    command_events.append',
    content,
    flags=re.DOTALL
)

with open("repos/noetl/noetl/server/api/v2.py", "w") as f:
    f.write(content)

