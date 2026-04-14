import re

with open("repos/noetl/noetl/core/dsl/engine/executor/commands.py", "r") as f:
    text = f.read()

# Add timers to _create_command_for_step
replacement = """            tool_config = {"tasks": pipeline}  # Worker expects "tasks" key
            
        import time
        t_pre_command = time.time()
        logger.info(f"PERF: Pre-Command {step.step}")
        
        # Extract next targets
"""
text = text.replace('            tool_config = {"tasks": pipeline}  # Worker expects "tasks" key\n        else:', replacement + "        else:")

replacement2 = """        command_metadata = {
                key: value for key, value in command_metadata.items() if value is not None
            }

        t_pre_pydantic = time.time()
        logger.info(f"PERF: Pre-Pydantic {step.step}")
        
        command = Command(
"""
text = text.replace('        command_metadata = {\n                key: value for key, value in command_metadata.items() if value is not None\n            }\n\n        command = Command(', replacement2)

replacement3 = """            metadata=command_metadata,
        )
        
        t_post_pydantic = time.time()
        logger.info(f"PERF: Post-Pydantic {step.step}, took {t_post_pydantic - t_pre_pydantic:.3f}s")

        return command"""
text = text.replace('            metadata=command_metadata,\n        )\n\n        return command', replacement3)

with open("repos/noetl/noetl/core/dsl/engine/executor/commands.py", "w") as f:
    f.write(text)

print("Updated commands.py")
