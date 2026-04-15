import re

path = "repos/noetl/noetl/core/dsl/engine/executor/commands.py"
with open(path, "r") as f:
    text = f.read()

# 1. Initialize collection safely
marker = '        """Create a command to execute a step."""'
if 'collection = []' not in text:
    text = text.replace(marker, marker + "\n        collection = []  # Default for safety")

# 2. Support claimed index
text = text.replace(
    'claimed_index: Optional[int] = None',
    'claimed_index: Optional[int] = control_args.get("__loop_claimed_index")'
)

# 3. Fix _nats_slot_incremented
text = text.replace(
    '_nats_slot_incremented = False',
    '_nats_slot_incremented = claimed_index is not None'
)

# 4. Wrap the claim call with None check for collection
# Old: claimed_index = await nats_cache.claim_next_loop_index(...)
# New: if claimed_index is None and collection is not None: claimed_index = await nats_cache.claim_next_loop_index(...)

pattern = r'claimed_index = await nats_cache\.claim_next_loop_index\(\s*str\(state\.execution_id\),\s*step\.step,\s*collection_size=len\(collection\),\s*max_in_flight=max_in_flight,\s*event_id=resolved_loop_event_id,\s*\)'

replacement = """if claimed_index is None and collection is not None:
                        claimed_index = await nats_cache.claim_next_loop_index(
                            str(state.execution_id),
                            step.step,
                            collection_size=len(collection),
                            max_in_flight=max_in_flight,
                            event_id=resolved_loop_event_id,
                        )"""

text = re.sub(pattern, replacement, text)

with open(path, "w") as f:
    f.write(text)
print("Surgically patched commands.py")
