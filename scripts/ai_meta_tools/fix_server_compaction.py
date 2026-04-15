import re

path = "repos/noetl/noetl/server/api/core/events.py"
with open(path, "r") as f:
    text = f.read()

# Disable the aggressive key-based deletion that destroys postgres tool outputs
old_block = """def _bounded_context(context_obj: Optional[dict[str, Any]]) -> Optional[dict[str, Any]]:
    if not isinstance(context_obj, dict): return None
    if _contains_forbidden_payload_keys(context_obj, _STRICT_CONTEXT_FORBIDDEN_KEYS): return None
    if _contains_legacy_command_keys(context_obj): return None
    if _estimate_json_size(context_obj) > _EVENT_RESULT_CONTEXT_MAX_BYTES: return None
    return context_obj"""

new_block = """def _bounded_context(context_obj: Optional[dict[str, Any]]) -> Optional[dict[str, Any]]:
    if not isinstance(context_obj, dict): return None
    # PERFORMANCE & CORRECTNESS FIX:
    # Do not silently delete entire contexts just because they contain "data" or "command_0" keys.
    # The JSON size threshold is sufficient to prevent event table bloat.
    if _estimate_json_size(context_obj) > _EVENT_RESULT_CONTEXT_MAX_BYTES: return None
    return context_obj"""

text = text.replace(old_block, new_block)

with open(path, "w") as f:
    f.write(text)
print("Successfully patched server compaction logic")
