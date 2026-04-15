import re

path = "repos/noetl/tests/fixtures/playbooks/pft_flow_test/test_pft_flow.yaml"
with open(path, "r") as f:
    text = f.read()

# Fix the template paths to match the postgres tool output structure
text = text.replace("in: '{{ claim_patients_for_assessments.rows }}'", "in: '{{ claim_patients_for_assessments.command_0.rows }}'")
text = text.replace("in: '{{ claim_patients_for_conditions.rows }}'", "in: '{{ claim_patients_for_conditions.command_0.rows }}'")
text = text.replace("in: '{{ claim_patients_for_medications.rows }}'", "in: '{{ claim_patients_for_medications.command_0.rows }}'")
text = text.replace("in: '{{ claim_patients_for_vital_signs.rows }}'", "in: '{{ claim_patients_for_vital_signs.command_0.rows }}'")
text = text.replace("in: '{{ claim_patients_for_demographics.rows }}'", "in: '{{ claim_patients_for_demographics.command_0.rows }}'")

with open(path, "w") as f:
    f.write(text)
print("Successfully fixed playbook templates")
