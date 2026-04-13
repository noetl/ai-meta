import re

with open("repos/noetl/noetl/server/api/v2.py", "r") as f:
    content = f.read()

# Fix the NameError in claim_command
# It's likely in the exception handler I added or modified.
content = content.replace(
    'if engine is not None and commands_generated:',
    'if commands_generated:'
)

# And make sure get_engine() is used inside claim_command if needed.
# Actually, I'll just check all occurrences of 'engine.' in v2.py
with open("repos/noetl/noetl/server/api/v2.py", "w") as f:
    f.write(content)

