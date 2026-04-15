import re

path = "repos/noetl/noetl/worker/nats_worker.py"
with open(path, "r") as f:
    text = f.read()

# Add logging of the final processed response
old_line = '                processed_response = await result_handler.process_result('
new_line = '                processed_response = await result_handler.process_result('
# I'll insert after the call
text = text.replace(
    '                if is_result_ref(processed_response):',
    '                logger.info(f"[DEBUG-PAYLOAD] Step {step} processed_response: {json.dumps(processed_response, default=str)[:1000]}")\n                if is_result_ref(processed_response):'
)

with open(path, "w") as f:
    f.write(text)
print("Successfully patched nats_worker.py with payload logger")
