import asyncio
from noetl.core.dsl.v2.playbook import Playbook

# load test_pft_flow.yaml
import yaml
with open("repos/noetl/tests/fixtures/playbooks/pft_flow_test/test_pft_flow.yaml", "r") as f:
    data = yaml.safe_load(f)

pb = Playbook(**data)
loop_steps = set()
if hasattr(pb, 'workflow') and pb.workflow:
    for step in pb.workflow:
        if hasattr(step, 'loop') and step.loop:
            loop_steps.add(step.step)

print("Loop steps in playbook:", loop_steps)
