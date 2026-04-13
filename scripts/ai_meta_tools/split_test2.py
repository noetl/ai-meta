import time
commands_text = "INSERT INTO t VALUES ('" + "a"*5000000 + "');"

t0 = time.time()
commands_list = []
current_command = ""
in_string = False
string_char = None
i = 0
while i < len(commands_text):
    char = commands_text[i]
    if char in ('"', "'") and (i == 0 or commands_text[i-1] != '\\'):
        if not in_string:
            in_string = True
            string_char = char
        elif char == string_char:
            in_string = False
            string_char = None
    if char == ';' and not in_string:
        command = current_command.strip()
        if command:
            commands_list.append(command)
        current_command = ""
    else:
        current_command += char
    i += 1
if current_command.strip():
    commands_list.append(current_command.strip())
print(f"char-by-char parse 5MB: {time.time() - t0:.3f}s")
