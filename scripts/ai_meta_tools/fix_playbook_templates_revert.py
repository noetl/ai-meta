import re

path = "repos/noetl/tests/fixtures/playbooks/pft_flow_test/test_pft_flow.yaml"
with open(path, "r") as f:
    text = f.read()

# Revert to original paths since command_0 is unnested for single statements
text = text.replace("in: '{{ claim_patients_for_assessments.command_0.rows }}'", "in: '{{ claim_patients_for_assessments.rows }}'")
text = text.replace("in: '{{ claim_patients_for_conditions.command_0.rows }}'", "in: '{{ claim_patients_for_conditions.rows }}'")
text = text.replace("in: '{{ claim_patients_for_medications.command_0.rows }}'", "in: '{{ claim_patients_for_medications.rows }}'")
text = text.replace("in: '{{ claim_patients_for_vital_signs.command_0.rows }}'", "in: '{{ claim_patients_for_vital_signs.rows }}'")
text = text.replace("in: '{{ claim_patients_for_demographics.command_0.rows }}'", "in: '{{ claim_patients_for_demographics.rows }}'")

with open(path, "w") as f:
    f.write(text)
print("Successfully reverted playbook templates")
