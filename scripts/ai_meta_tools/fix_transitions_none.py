import re

file_path = "repos/noetl/noetl/core/dsl/engine/executor/transitions.py"
with open(file_path, "r") as f:
    text = f.read()

# Add the collection guard
pattern = r'# PERFORMANCE OPTIMIZATION: Batch claim loop indices to avoid O\(N\) NATS round-trips\n\s+claimed_indices = await nats_cache\.claim_next_loop_indices\(\n\s+str\(state\.execution_id\),\n\s+step_def\.step,\n\s+collection_size=len\(collection\),\n\s+max_in_flight=issue_budget,\s+# budget IS max_in_flight for parallel loops\n\s+requested_count=issue_budget,\n\s+event_id=loop_event_id\n\s+\)'

replacement = """# PERFORMANCE OPTIMIZATION: Batch claim loop indices to avoid O(N) NATS round-trips
        claimed_indices = []
        if collection is not None:
            claimed_indices = await nats_cache.claim_next_loop_indices(
                str(state.execution_id),
                step_def.step,
                collection_size=len(collection),
                max_in_flight=issue_budget, # budget IS max_in_flight for parallel loops
                requested_count=issue_budget,
                event_id=loop_event_id
            )"""

text = re.sub(pattern, replacement, text)

with open(file_path, "w") as f:
    f.write(text)

print("Successfully patched transitions.py with collection guard.")
