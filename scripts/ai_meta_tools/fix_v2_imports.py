import os
import re

core_file = "repos/noetl/noetl/server/api/v2/core.py"
with open(core_file, "r") as f:
    content = f.read()

constants = """
_STRICT_RESULT_ALLOWED_KEYS = {"status", "reference", "context", "command_id"}
_STRICT_PAYLOAD_FORBIDDEN_KEYS = {"response", "inputs", "data", "data_reference", "_internal_data", "_inline"}
_STRICT_CONTEXT_FORBIDDEN_KEYS = {"response", "result", "payload", "data", "_ref", "_inline", "_internal_data"}
"""

if "_STRICT_CONTEXT_FORBIDDEN_KEYS" not in content:
    with open(core_file, "a") as f:
        f.write("\n" + constants + "\n")

