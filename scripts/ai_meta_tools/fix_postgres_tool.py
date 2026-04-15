import re

path = "repos/noetl/noetl/tools/postgres/execution.py"
with open(path, "r") as f:
    text = f.read()

# Remove the filtering that drops non-JSON columns
old_block = """            for col_name, value in row.items():
                if isinstance(value, dict) or (
                    isinstance(value, str) and (value.startswith("{") or value.startswith("["))
                ):
                    row_dict[col_name] = value"""

new_block = """            for col_name, value in row.items():
                row_dict[col_name] = value"""

text = text.replace(old_block, new_block)

with open(path, "w") as f:
    f.write(text)
print("Successfully patched postgres tool execution.py")
