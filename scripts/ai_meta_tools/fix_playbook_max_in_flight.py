import re

path = "repos/noetl/tests/fixtures/playbooks/pft_flow_test/test_pft_flow.yaml"
with open(path, "r") as f:
    text = f.read()

# 1. Add max_in_flight to workload
workload_pattern = r'workload:\n  api_url: http://paginated-api\.test-server\.svc\.cluster\.local:5555\n  page_size: 10\n  num_facilities: 10\n  patients_per_facility: 1000\n  claim_batch_size: 100'
workload_replacement = """workload:
  api_url: http://paginated-api.test-server.svc.cluster.local:5555
  page_size: 10
  num_facilities: 10
  patients_per_facility: 1000
  claim_batch_size: 100
  max_in_flight: 20"""

if 'max_in_flight: 20' not in text:
    text = re.sub(workload_pattern, workload_replacement, text)

# 2. Replace hardcoded max_in_flight: 20 with variable in all loops
loop_pattern = r'      spec:\n        mode: parallel\n        max_in_flight: 20'
loop_replacement = """      spec:
        mode: parallel
        max_in_flight: '{{ workload.max_in_flight | int }}'"""

text = re.sub(loop_pattern, loop_replacement, text)

with open(path, "w") as f:
    f.write(text)

print("Successfully patched playbook with dynamic max_in_flight")
