import re

with open("repos/noetl/noetl/server/api/v2.py", "r") as f:
    content = f.read()

# Fix the specific line that caused SyntaxError
content = content.replace('\\"\\"\\"', '"""')

with open("repos/noetl/noetl/server/api/v2.py", "w") as f:
    f.write(content)
