import sys
import yaml

with open("repos/noetl/tests/fixtures/playbooks/pft_flow_test/test_pft_flow.yaml", "r") as f:
    playbook_yaml = yaml.safe_load(f)

# Mock Pydantic classes to mimic the engine's behavior
class Loop:
    def __init__(self, **kwargs):
        pass

class Step:
    def __init__(self, step, loop=None, **kwargs):
        self.step = step
        self.loop = loop

class Playbook:
    def __init__(self, workflow=None, **kwargs):
        self.workflow = [Step(**w) for w in workflow] if workflow else []

playbook = Playbook(**playbook_yaml)

loop_steps = set()
for step in playbook.workflow:
    if hasattr(step, 'loop') and step.loop:
        loop_steps.add(step.step)

print(f"Loop Steps: {loop_steps}")
