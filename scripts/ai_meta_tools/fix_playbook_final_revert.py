import re

path = "repos/noetl/tests/fixtures/playbooks/pft_flow_test/test_pft_flow.yaml"
with open(path, "r") as f:
    text = f.read()

# Restore original batch size
text = text.replace("claim_batch_size: 20", "claim_batch_size: 100")

with open(path, "w") as f:
    f.write(text)

print("Successfully reverted claim_batch_size to 100")
