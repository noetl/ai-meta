import re

path = "repos/noetl/noetl/server/api/core/core.py"
with open(path, "r") as f:
    text = f.read()

# Increase row limit
text = text.replace(
    'int(os.getenv("NOETL_EVENT_RESULT_CONTEXT_MAX_ROWS_PER_COMMAND", "1")),',
    'int(os.getenv("NOETL_EVENT_RESULT_CONTEXT_MAX_ROWS_PER_COMMAND", "5000")),'
)

# Increase size limit
text = text.replace(
    'int(os.getenv("NOETL_EVENT_RESULT_CONTEXT_MAX_BYTES", "16384")),',
    'int(os.getenv("NOETL_EVENT_RESULT_CONTEXT_MAX_BYTES", "102400")),'
)

with open(path, "w") as f:
    f.write(text)
print("Successfully patched server API max row limits")
