import re

with open("repos/noetl/noetl/server/api/v2.py", "r") as f:
    content = f.read()

# Fix the exception swallowing at the end of claim_command
replacement = """    except Exception as e:
        retry_after = _record_db_unavailable_failure(e, operation="claim_command")
        if retry_after is not None:
            raise HTTPException(
                status_code=503,
                detail={"code": "db_unavailable", "message": "Database temporarily unavailable; retry shortly"},
                headers={"Retry-After": retry_after},
            )
        logger.error(f"claim_command failed with unhandled error: {e}", exc_info=True)
        raise HTTPException(
            status_code=500,
            detail={"code": "internal_error", "message": str(e)}
        )
"""

content = re.sub(
    r'    except Exception as e:\n        retry_after = _record_db_unavailable_failure\(e, operation="claim_command"\)\n        if retry_after is not None:\n            raise HTTPException\(\n                status_code=503,\n                detail=\{\n.*?\},\n                headers=\{"Retry-After": retry_after\},\n            \)',
    replacement,
    content,
    flags=re.DOTALL
)

with open("repos/noetl/noetl/server/api/v2.py", "w") as f:
    f.write(content)

