import re

with open("repos/noetl/noetl/core/dsl/v2/engine/store.py", "r") as f:
    content = f.read()

replacement = """        sql = \"\"\"
            UPDATE noetl.execution 
            SET state = %s, 
                updated_at = CURRENT_TIMESTAMP,
                end_time = CASE
                    WHEN noetl.execution.end_time IS NULL AND %s IN ('COMPLETED', 'FAILED', 'CANCELLED') THEN CURRENT_TIMESTAMP
                    ELSE noetl.execution.end_time
                END,
                status = CASE 
                    WHEN status IN ('COMPLETED', 'FAILED', 'CANCELLED') THEN status 
                    ELSE %s 
                END,
                last_event_id = GREATEST(COALESCE(last_event_id, 0), %s)
            WHERE execution_id = %s
        \"\"\"
        params = (json.dumps(state_dict), status, status, last_event_id, int(state.execution_id))"""

content = re.sub(
    r'        sql = \"\"\"\n            UPDATE noetl\.execution \n            SET state = %s, \n                updated_at = CURRENT_TIMESTAMP,\n                status = CASE \n                    WHEN status IN \(\'COMPLETED\', \'FAILED\', \'CANCELLED\'\) THEN status \n                    ELSE %s \n                END,\n                last_event_id = GREATEST\(COALESCE\(last_event_id, 0\), %s\)\n            WHERE execution_id = %s\n        \"\"\"\n        params = \(json\.dumps\(state_dict\), status, last_event_id, int\(state\.execution_id\)\)',
    replacement,
    content
)

with open("repos/noetl/noetl/core/dsl/v2/engine/store.py", "w") as f:
    f.write(content)

