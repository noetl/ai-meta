CREATE OR REPLACE FUNCTION noetl.trg_execution_state_upsert()
RETURNS TRIGGER AS $$
DECLARE
    new_status VARCHAR;
    is_terminal BOOLEAN := FALSE;
BEGIN
    -- OPTIMIZATION: Skip execution table updates for ALL high-frequency events.
    -- The StateStore.save_state method already handles updating status and last_event_id.
    -- We only need the trigger for the absolute initial creation to avoid foreign key errors.
    IF NOT (NEW.event_type IN (
        'playbook.initialized', 'workflow.initialized'
    )) THEN
        RETURN NEW;
    END IF;

    new_status := 'RUNNING';

    INSERT INTO noetl.execution (
        execution_id, catalog_id, parent_execution_id, status, last_event_type, last_node_name,
        last_event_id, start_time, end_time, error, created_at, updated_at
    )
    VALUES (
        NEW.execution_id, 
        NEW.catalog_id, 
        NEW.parent_execution_id,
        new_status,
        NEW.event_type,
        NEW.node_name,
        NEW.event_id,
        NEW.created_at,
        NULL,
        NEW.error,
        NEW.created_at, 
        NEW.created_at
    )
    ON CONFLICT (execution_id) DO NOTHING;
        
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
