import re

with open("repos/noetl/tests/unit/dsl/engine/test_loop_parallel_dispatch.py", "r") as f:
    text = f.read()

# Fix test_snapshot_loop_collections_captures_progress_counts
text = re.sub(
    r'"results": \[{}, {}, {}, {}\],',
    r'"completed_count": 4,',
    text
)

# Fix test_restore_loop_collection_snapshot_skips_when_cached_smaller_than_required
text = re.sub(
    r'"results": \[{}, {}, {}\],',
    r'"completed_count": 3,',
    text
)

# Fix test_loop_continue_rerenders_when_replayed_cached_collection_is_empty
text = re.sub(
    r'"results": \[\],',
    r'"completed_count": 0,',
    text
)

text = re.sub(
    r'assert len\(state.loop_state\["run_batch_workers"\]\["collection"\]\) == 3',
    r'assert state.loop_state["run_batch_workers"]["collection_size"] == 3',
    text
)

with open("repos/noetl/tests/unit/dsl/engine/test_loop_parallel_dispatch.py", "w") as f:
    f.write(text)
print("Tests fixed.")
