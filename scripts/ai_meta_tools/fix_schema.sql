CREATE INDEX IF NOT EXISTS idx_event_idempotency_key 
ON noetl.event ((meta->>'idempotency_key'), event_id DESC) 
WHERE (meta ? 'idempotency_key');

CREATE INDEX IF NOT EXISTS idx_event_meta_command_id 
ON noetl.event ((meta->>'command_id'), event_id DESC) 
WHERE (meta ? 'command_id');

-- Increase Postgres work_mem to speed up large sorts/joins in loops
ALTER SYSTEM SET work_mem = '16MB';
SELECT pg_reload_conf();
