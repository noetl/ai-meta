import re

with open("repos/noetl/noetl/core/dsl/engine/executor/queries.py", "r") as f:
    text = f.read()

# Fix _find_missing_loop_iteration_indices
text = re.sub(
    r'COALESCE\(\s*meta->>\'command_id\',\s*result->\'context\'->>\'command_id\',\s*context->>\'command_id\'\s*\)',
    r"meta->>'command_id'",
    text
)

# Fix _count_loop_terminal_iterations
text = re.sub(
    r'SELECT COALESCE\(\s*NULLIF\(meta->>\'loop_iteration_index\', \'\'\)::int,\s*NULLIF\(result->\'context\'->>\'loop_iteration_index\', \'\'\)::int,\s*NULLIF\(context->>\'loop_iteration_index\', \'\'\)::int\s*\)',
    r"SELECT NULLIF(meta->>'loop_iteration_index', '')::int",
    text
)

text = re.sub(
    r'AND COALESCE\(\s*meta->>\'loop_event_id\',\s*meta->>\'__loop_epoch_id\',\s*result->\'context\'->>\'loop_event_id\',\s*result->>\'loop_event_id\',\s*context->>\'loop_event_id\'\s*\) = %s',
    r"AND COALESCE(meta->>'loop_event_id', meta->>'__loop_epoch_id') = %s",
    text
)

with open("repos/noetl/noetl/core/dsl/engine/executor/queries.py", "w") as f:
    f.write(text)
print("Updated queries.py")
