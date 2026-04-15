import re

path = "repos/noetl/noetl/server/api/core/commands.py"
with open(path, "r") as f:
    text = f.read()

# Update _build_reference_only_result to correctly handle top-level response data
old_block = """        context = _bounded_context(payload_result.get("context") or payload.get("response", {}).get("context"))
        if isinstance(context, dict): result_obj["context"] = context
    else:
        if isinstance(payload.get("reference"), dict):
            result_obj["reference"] = payload.get("reference")
        direct_context = _bounded_context(payload.get("context") or payload.get("response", {}).get("context"))
        if isinstance(direct_context, dict): result_obj["context"] = direct_context"""

# New logic: Fallback to the whole payload_result if no 'context' key is found
new_block = """        # v10 Bridge: Use 'context' key if present, otherwise treat the whole result/response as context
        raw_context = payload_result.get("context") or payload_result
        context = _bounded_context(raw_context)
        if isinstance(context, dict): result_obj["context"] = context
    else:
        if isinstance(payload.get("reference"), dict):
            result_obj["reference"] = payload.get("reference")
        # Fallback for direct payload
        raw_direct = payload.get("context") or payload.get("response") or payload
        direct_context = _bounded_context(raw_direct)
        if isinstance(direct_context, dict): result_obj["context"] = direct_context"""

text = text.replace(old_block, new_block)

with open(path, "w") as f:
    f.write(text)
print("Successfully patched server commands.py with FINAL v10 bridge")
