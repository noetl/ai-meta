import re

file_path = "repos/noetl/noetl/core/cache/nats_kv.py"
with open(file_path, "r") as f:
    text = f.read()

# 1. Update claim_next_loop_index (singular)
pattern_singular = r'            try:\n                entry = await self\._kv\.get\(key\)\n                if not entry:\n                    return None'
replacement_singular = """            try:
                try:
                    entry = await self._kv.get(key)
                except Exception as get_exc:
                    if "key not found" in str(get_exc).lower():
                        # Lazy initialize loop state in NATS KV
                        init_state = {
                            "completed_count": 0,
                            "scheduled_count": 0,
                            "collection_size": safe_collection_size,
                            "updated_at": _utcnow_iso()
                        }
                        await self._kv.put(key, json.dumps(init_state).encode("utf-8"))
                        entry = await self._kv.get(key)
                    else:
                        raise get_exc

                if not entry:
                    return None"""

text = re.sub(pattern_singular, replacement_singular, text)

# 2. Update claim_next_loop_indices (plural)
pattern_plural = r'    async def claim_next_loop_indices\((.*?)\)\s*-> list\[int\]:\n(.*?)\n        for attempt in range\(max_retries\):\n            try:\n                entry = await self\._kv\.get\(key\)\n                if not entry:\n                    return \[\]'
# This one is trickier due to the multiline match. Let's use a simpler string replacement for the loop body.

old_block = """                entry = await self._kv.get(key)
                if not entry:
                    return []"""

new_block = """                try:
                    entry = await self._kv.get(key)
                except Exception as get_exc:
                    if "key not found" in str(get_exc).lower():
                        # Lazy initialize loop state in NATS KV
                        init_state = {
                            "completed_count": 0,
                            "scheduled_count": 0,
                            "collection_size": safe_collection_size,
                            "updated_at": _utcnow_iso()
                        }
                        await self._kv.put(key, json.dumps(init_state).encode("utf-8"))
                        entry = await self._kv.get(key)
                    else:
                        raise get_exc

                if not entry:
                    return []"""

# Find the start of claim_next_loop_indices and replace the entry check
start_idx = text.find("async def claim_next_loop_indices")
if start_idx != -1:
    # Find the next occurrence of old_block after start_idx
    block_idx = text.find(old_block, start_idx)
    if block_idx != -1:
        text = text[:block_idx] + new_block + text[block_idx+len(old_block):]

with open(file_path, "w") as f:
    f.write(text)

print("Successfully patched nats_kv.py to support lazy initialization.")
