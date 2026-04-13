import time
import json
import duckdb

huge_payload = {"data": [{"id": i, "value": "a" * 100} for i in range(100000)]}

t0 = time.time()
json_str = json.dumps(huge_payload)
sql = f"SELECT count(*) FROM read_json_auto('{json_str}')"
print(f"string prep: {time.time() - t0:.3f}s")

# Wait, read_json_auto doesn't take raw JSON strings, it takes file paths!
# DuckDB doesn't allow parsing huge literal strings in read_json easily unless it's a JSON type literal?
