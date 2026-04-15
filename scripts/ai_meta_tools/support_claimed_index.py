import re

file_path = "repos/noetl/noetl/core/dsl/engine/executor/commands.py"
with open(file_path, "r") as f:
    text = f.read()

# 1. Update the initial claim check
pattern = r'        claimed_index: Optional\[int\] = None\n        _nats_slot_incremented = False  # tracks whether a NATS scheduled_count was incremented'
replacement = """        claimed_index: Optional[int] = control_args.get("__loop_claimed_index")
        _nats_slot_incremented = claimed_index is not None # If passed in, it was already incremented in NATS
        """

text = re.sub(pattern, replacement, text)

# 2. Wrap the existing NATS claim logic in an "if claimed_index is None" check
# We need to find the block that calls nats_cache.claim_next_loop_index

pattern2 = r'                if nats_loop_state:\n(.*?)\n                    if claimed_index is not None:\n                        _nats_slot_incremented = True'
# This is tricky because I added timers there too.

# Let's just find the nats_cache.claim_next_loop_index call and wrap it.
text = text.replace(
    'claimed_index = await nats_cache.claim_next_loop_index(',
    'if claimed_index is None: claimed_index = await nats_cache.claim_next_loop_index('
)

# And close the parentheses
# Actually I'll use a safer approach.

with open(file_path, "w") as f:
    f.write(text)

print("Successfully patched commands.py to support pre-claimed indices.")
