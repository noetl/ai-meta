EXPLAIN ANALYZE
                        WITH issued AS (
                            SELECT
                                meta->>'command_id' AS command_id,
                                NULLIF(meta->>'loop_iteration_index', '')::int AS loop_iteration_index
                            FROM noetl.event
                            WHERE execution_id = '604592715833016770'
                              AND node_name = 'fetch_assessments:task_sequence'
                              AND event_type = 'command.issued'
                              AND meta->>'loop_event_id' = 'loop_604599424102170700_1776141068433635333'
                        ),
                        started AS (
                            SELECT DISTINCT
                                meta->>'command_id' AS command_id
                            FROM noetl.event
                            WHERE execution_id = '604592715833016770'
                              AND node_name = 'fetch_assessments:task_sequence'
                              AND event_type = 'command.started'
                              AND meta->>'command_id' IS NOT NULL
                              AND meta->>'command_id' IN (
                                    SELECT command_id FROM issued WHERE command_id IS NOT NULL
                                  )
                        ),
                        terminal AS (
                            SELECT DISTINCT
                                meta->>'command_id' AS command_id
                            FROM noetl.event
                            WHERE execution_id = '604592715833016770'
                              AND node_name = 'fetch_assessments:task_sequence'
                              AND event_type IN ('call.done', 'call.error')
                              AND meta->>'command_id' IN (
                                    SELECT command_id FROM issued WHERE command_id IS NOT NULL
                                  )
                        )
                        SELECT i.loop_iteration_index
                        FROM issued i
                        LEFT JOIN started s ON i.command_id = s.command_id
                        LEFT JOIN terminal t ON i.command_id = t.command_id
                        WHERE t.command_id IS NULL
                          AND s.command_id IS NULL
                        ORDER BY i.loop_iteration_index ASC
                        LIMIT 10;
