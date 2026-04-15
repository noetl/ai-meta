import re

path = "repos/noetl/tests/fixtures/playbooks/pft_flow_test/test_pft_flow.yaml"
with open(path, "r") as f:
    text = f.read()

# Revert to 20 to ensure the SQL rows payload stays well under the 16KB threshold,
# preventing the worker from stripping the payload and causing infinite retry loops.
text = text.replace("claim_batch_size: 100", "claim_batch_size: 20")

with open(path, "w") as f:
    f.write(text)

print("Successfully restored claim_batch_size to 20 to fit within the 16KB local worker limit!")
