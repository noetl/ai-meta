with open("repos/noetl/noetl/server/api/v2.py", "r") as f:
    lines = f.readlines()

new_lines = []
for line in lines:
    if 'command_events.append((int(' in line and 'new_evt_id' in line:
        new_lines.append('                ' + line.strip() + '\n')
    elif 'supervisor_commands.append(' in line and 'new_evt_id' in line:
        new_lines.append('                ' + line.strip() + '\n')
    elif '(str(cmd.execution_id), cmd_id, cmd.step, int(new_evt_id)' in line:
        new_lines.append('                    ' + line.strip() + '\n')
    elif ') )' in line and i > 1800: # end of supervisor_commands
         new_lines.append('                ' + line.strip() + '\n')
    else:
        new_lines.append(line)

with open("repos/noetl/noetl/server/api/v2.py", "w") as f:
    f.writelines(new_lines)
