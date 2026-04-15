import re

path = "repos/noetl/noetl/worker/nats_worker.py"
with open(path, "r") as f:
    text = f.read()

# 1. Prevent the worker from deleting the response payload
pattern = r'# Strict reference-only contract: inline payload keys are never transported\.\n\s+for field_name in \("response", "inputs", "data", "data_reference", "_internal_data", "_inline"\):\n\s+normalized\.pop\(field_name, None\)'

replacement = """# PERFORMANCE & CORRECTNESS FIX:
        # Do not delete inline response data! The engine needs small outputs (like SQL row sets)
        # to execute loops and transitions. The API server enforces the JSON size limit.
        for field_name in ("inputs", "data_reference", "_internal_data", "_inline"):
            normalized.pop(field_name, None)"""

text = re.sub(pattern, replacement, text)

# 2. Make sure _build_strict_result_envelope includes the data if it's there
# Wait, if we keep 'response', the server will find it. We don't need to jam it into 'result'.
# The server's v10 bridge now looks for 'response'. 

with open(path, "w") as f:
    f.write(text)
print("Successfully patched worker strict contract logic")
