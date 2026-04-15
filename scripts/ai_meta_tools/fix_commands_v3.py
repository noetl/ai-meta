path = "repos/noetl/noetl/core/dsl/engine/executor/commands.py"
with open(path, "r") as f:
    text = f.read()

# Wrap the claim call
text = text.replace(
    'claimed_index = await nats_cache.claim_next_loop_index(',
    'if claimed_index is None: claimed_index = await nats_cache.claim_next_loop_index('
)

# And fix _nats_slot_incremented
text = text.replace(
    '_nats_slot_incremented = False',
    '_nats_slot_incremented = claimed_index is not None'
)

with open(path, "w") as f:
    f.write(text)
print("Successfully patched commands.py v3")
