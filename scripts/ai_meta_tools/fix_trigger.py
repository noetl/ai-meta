import re

with open("repos/noetl/noetl/database/ddl/postgres/schema_ddl.sql", "r") as f:
    content = f.read()

optimized_trigger = """CREATE OR REPLACE FUNCTION noetl.trg_execution_state_upsert()
RETURNS TRIGGER AS $$
DECLARE
    new_status VARCHAR;
    is_terminal BOOLEAN := FALSE;
BEGIN
    -- OPTIMIZATION: Skip execution table updates for high-frequency informational events
    -- to reduce lock contention on the execution table.
    IF NOT (NEW.event_type IN (
        'playbook.initialized', 'playbook.completed', 'playbook.failed',
        'workflow.initialized', 'workflow.completed', 'workflow.failed',
        'execution.cancelled', 'step.enter', 'step.exit', 'loop.done', 'command.failed'
    )) THEN
        RETURN NEW;
    END IF;

    -- Determine the overall execution status from the event
"""

content = re.sub(
    r'CREATE OR REPLACE FUNCTION noetl\.trg_execution_state_upsert\(\).*?BEGIN\n\s+-- Determine the overall execution status from the event',
    optimized_trigger.strip(),
    content,
    flags=re.DOTALL
)

with open("repos/noetl/noetl/database/ddl/postgres/schema_ddl.sql", "w") as f:
    f.write(content)

