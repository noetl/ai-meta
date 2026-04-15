import re

path = "repos/noetl/noetl/worker/nats_worker.py"
with open(path, "r") as f:
    text = f.read()

# Remove the fallback logic that destroys inline data
old_block = """                if is_result_ref(processed_response):
                    logger.info(
                        f"[RESULT] Step {step}: stored result for event transport | "
                        f"store={processed_response.get('_store', 'unknown')} | "
                        f"size={processed_response.get('_size_bytes', 0)}b"
                    )
                    response_for_events = processed_response
                else:
                    # Keep event payload bounded even if store write fails.
                    logger.warning(
                        "[RESULT] Step %s: result persistence did not return ref; using compact fallback",
                        step,
                    )
                    response_for_events = processed_response if isinstance(processed_response, dict) else {"_value": None}"""

new_block = """                if is_result_ref(processed_response):
                    logger.info(
                        f"[RESULT] Step {step}: stored result for event transport | "
                        f"store={processed_response.get('_store', 'unknown')} | "
                        f"size={processed_response.get('_size_bytes', 0)}b"
                    )
                response_for_events = processed_response"""

text = text.replace(old_block, new_block)

with open(path, "w") as f:
    f.write(text)
print("Successfully patched worker fallback logic")
