import re

path = "repos/noetl/noetl/tools/postgres/execution.py"
with open(path, "r") as f:
    text = f.read()

# Correctly integrate the data types while removing the JSON filter
old_block = """            for col_name, value in row.items():
                row_dict[col_name] = value
                elif isinstance(value, Decimal):"""

new_block = """            for col_name, value in row.items():
                if isinstance(value, Decimal):"""

text = text.replace(old_block, new_block)

with open(path, "w") as f:
    f.write(text)
print("Successfully patched postgres tool FINAL")
