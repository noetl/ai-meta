EXPLAIN ANALYZE
                        SELECT COUNT(DISTINCT idx.loop_iteration_index) AS cnt
                        FROM (
                            SELECT NULLIF(meta->>'loop_iteration_index', '')::int AS loop_iteration_index
                            FROM noetl.event
                            WHERE execution_id = '604592715833016770'
                              AND node_name = 'fetch_assessments:task_sequence'
                              AND event_type = 'call.done'
                              AND COALESCE(meta->>'loop_event_id', meta->>'__loop_epoch_id') = 'loop_604599424102170700_1776141068433635333'
                        ) idx
                        WHERE idx.loop_iteration_index IS NOT NULL;
