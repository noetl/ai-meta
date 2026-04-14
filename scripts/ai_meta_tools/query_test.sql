EXPLAIN ANALYZE
                        WITH issued AS (
                            SELECT
                                meta->>'command_id' AS command_id,
                                NULLIF(meta->>'loop_iteration_index', '')::int AS loop_iteration_index,
                                created_at AS issued_at
                            FROM noetl.event
                            WHERE execution_id = '604592715833016770'
                              AND node_name = 'fetch_assessments:task_sequence'
                              AND event_type = 'command.issued'
                              
                        ),
                        started AS (
                            SELECT
                                COALESCE(
                                    meta->>'command_id',
                                    result->'context'->>'command_id',
                                    context->>'command_id'
                                ) AS command_id,
                                MAX(created_at) AS started_at
                            FROM noetl.event
                            WHERE execution_id = '604592715833016770'
                              AND node_name = 'fetch_assessments:task_sequence'
                              AND event_type = 'command.started'
                              AND COALESCE(
                                    meta->>'command_id',
                                    result->'context'->>'command_id',
                                    context->>'command_id'
                                  ) IS NOT NULL
                              AND COALESCE(
                                    meta->>'command_id',
                                    result->'context'->>'command_id',
                                    context->>'command_id'
                                  ) IN (
                                    SELECT command_id FROM issued WHERE command_id IS NOT NULL
                                  )
                            GROUP BY COALESCE(
                                    meta->>'command_id',
                                    result->'context'->>'command_id',
                                    context->>'command_id'
                                )
                        ),
                        terminal AS (
                            SELECT
                                COALESCE(
                                    meta->>'command_id',
                                    result->'context'->>'command_id',
                                    context->>'command_id'
                                ) AS command_id
                            FROM noetl.event
                            WHERE execution_id = '604592715833016770'
                              AND node_name = 'fetch_assessments:task_sequence'
                              AND event_type IN ('call.done', 'call.error')
                              AND COALESCE(
                                    meta->>'command_id',
                                    result->'context'->>'command_id',
                                    context->>'command_id'
                                  ) IN (
                                    SELECT command_id FROM issued WHERE command_id IS NOT NULL
                                  )
                        )
                        SELECT i.loop_iteration_index
                        FROM issued i
                        LEFT JOIN started s ON i.command_id = s.command_id
                        LEFT JOIN terminal t ON i.command_id = t.command_id
                        WHERE t.command_id IS NULL
                          AND (
                              s.command_id IS NULL
                              AND i.issued_at < NOW() - INTERVAL '1 seconds'
                          )
                        ORDER BY i.loop_iteration_index ASC
                        LIMIT 10;
