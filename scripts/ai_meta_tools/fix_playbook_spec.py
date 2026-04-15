import re

path = "repos/noetl/tests/fixtures/playbooks/pft_flow_test/test_pft_flow.yaml"
with open(path, "r") as f:
    text = f.read()

# Revert to a hardcoded int because Pydantic is failing to parse the template string
loop_replacement = """      spec:
        mode: parallel
        max_in_flight: 100"""

text = text.replace("max_in_flight: '{{ workload.max_in_flight | int }}'", "max_in_flight: 100")

with open(path, "w") as f:
    f.write(text)

print("Successfully reverted playbook to use static integer for max_in_flight")
