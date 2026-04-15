path = "repos/noetl/noetl/core/dsl/engine/executor/commands.py"
with open(path, "r") as f:
    text = f.read()

text = text.replace("if claimed_index is None: if claimed_index is None: ", "if claimed_index is None: ")
with open(path, "w") as f:
    f.write(text)
print("Fixed commands.py")
