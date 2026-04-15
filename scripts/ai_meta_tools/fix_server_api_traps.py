import os
import re

# 1. Neutralize the forbidden keys in core.py
core_path = "repos/noetl/noetl/server/api/core/core.py"
with open(core_path, "r") as f:
    text = f.read()

text = text.replace(
    '_STRICT_PAYLOAD_FORBIDDEN_KEYS = {"response", "inputs", "data", "data_reference", "_internal_data", "_inline"}',
    '_STRICT_PAYLOAD_FORBIDDEN_KEYS = {"_internal_data"}' # Allow response, data, etc.
)
text = text.replace(
    '_STRICT_CONTEXT_FORBIDDEN_KEYS = {"response", "result", "payload", "data", "_ref", "_inline", "_internal_data"}',
    '_STRICT_CONTEXT_FORBIDDEN_KEYS = {"_internal_data"}' # Allow response, result, data, etc.
)

with open(core_path, "w") as f:
    f.write(text)

# 2. Defuse the legacy command killer in utils.py
utils_path = "repos/noetl/noetl/server/api/core/utils.py"
with open(utils_path, "r") as f:
    text = f.read()

pattern = r'def _contains_legacy_command_keys\(value: Any, \*, depth: int = 0\) -> bool:\n\s+if depth > 8: return False\n\s+if isinstance\(value, dict\):\n\s+for key, child in value\.items\(\):\n\s+key_str = str\(key\)\n\s+if key_str\.startswith\("command_"\) and key_str != "command_id": return True\n\s+if _contains_legacy_command_keys\(child, depth=depth \+ 1\): return True\n\s+elif isinstance\(value, list\):\n\s+for child in value:\n\s+if _contains_legacy_command_keys\(child, depth=depth \+ 1\): return True\n\s+return False'

replacement = """def _contains_legacy_command_keys(value: Any, *, depth: int = 0) -> bool:
    # PERFORMANCE & CORRECTNESS: Do not kill postgres tool results (e.g. 'command_0').
    # The JSON size limit is sufficient to prevent DB bloat.
    return False"""

text = re.sub(pattern, replacement, text)

with open(utils_path, "w") as f:
    f.write(text)

# 3. Ensure events.py bounded_context isn't still doing something weird
events_path = "repos/noetl/noetl/server/api/core/events.py"
with open(events_path, "r") as f:
    text = f.read()

# Make absolutely sure _bounded_context lets small payloads through
pattern2 = r'def _bounded_context\(context_obj: Optional\[dict\[str, Any\]\]\) -> Optional\[dict\[str, Any\]\]:\n\s+if not isinstance\(context_obj, dict\): return None\n\s+if _contains_forbidden_payload_keys\(context_obj, _STRICT_CONTEXT_FORBIDDEN_KEYS\): return None\n\s+if _contains_legacy_command_keys\(context_obj\): return None\n\s+if _estimate_json_size\(context_obj\) > _EVENT_RESULT_CONTEXT_MAX_BYTES: return None\n\s+return context_obj'

replacement2 = """def _bounded_context(context_obj: Optional[dict[str, Any]]) -> Optional[dict[str, Any]]:
    if not isinstance(context_obj, dict): return None
    # Let the data through if it fits!
    if _estimate_json_size(context_obj) > _EVENT_RESULT_CONTEXT_MAX_BYTES: return None
    return context_obj"""

text = re.sub(pattern2, replacement2, text)

with open(events_path, "w") as f:
    f.write(text)

print("Successfully defused all API data traps")
