import re

path = "repos/noetl/tests/fixtures/playbooks/pft_flow_test/test_pft_flow.yaml"
with open(path, "r") as f:
    text = f.read()

# Change claim_batch_size to 20 to keep SQL result payloads well under the 16KB limit
# since local dev clusters don't have S3/GCS artifact storage configured.
text = text.replace("claim_batch_size: 100", "claim_batch_size: 20")

with open(path, "w") as f:
    f.write(text)

print("Successfully reduced claim_batch_size to 20")
