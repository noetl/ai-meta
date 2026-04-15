import re

with open("repos/noetl/noetl/server/api/core/batch.py", "r") as f:
    text = f.read()

replacement = """
    p_sec = time.perf_counter() - p_start
    import logging
    log = logging.getLogger(__name__)
    log.info(f"[PERF] _process_batch_job took {p_sec:.3f}s for execution {job.execution_id}")

    if p_sec > _BATCH_PROCESSING_WARN_SECONDS:
"""

text = text.replace('    p_sec = time.perf_counter() - p_start\n    if p_sec > _BATCH_PROCESSING_WARN_SECONDS:', replacement)

with open("repos/noetl/noetl/server/api/core/batch.py", "w") as f:
    f.write(text)

