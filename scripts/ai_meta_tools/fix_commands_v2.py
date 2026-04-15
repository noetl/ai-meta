path = "repos/noetl/noetl/core/dsl/engine/executor/commands.py"
with open(path, "r") as f:
    text = f.read()

# Surgical insertion after the method docstring
marker = '        """Create a command to execute a step."""'
text = text.replace(marker, marker + "\n        collection = []  # Default for safety")

# Also ensure claimed_index is handled
text = text.replace(
    'claimed_index: Optional[int] = None',
    'claimed_index: Optional[int] = control_args.get("__loop_claimed_index")'
)

with open(path, "w") as f:
    f.write(text)
print("Successfully patched commands.py v2")
