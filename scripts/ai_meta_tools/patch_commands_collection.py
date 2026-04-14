import re

with open("repos/noetl/noetl/core/dsl/engine/executor/commands.py", "r") as f:
    text = f.read()

pattern = r"""                else:
                    rendered_collection_size = len\(collection\)
                    if \(
                        \(loop_continue_requested or loop_retry_requested\)
                        and isinstance\(previous_collection, list\)
                        and previous_size > 0
                        and rendered_collection_size < previous_size
                    \):
                        logger\.warning\(
                            "\[LOOP\] Preserving prior collection snapshot for %s continuation/retry "
                            "\(rendered_size=%s previous_size=%s\)",
                            step\.step,
                            rendered_collection_size,
                            previous_size,
                        \)
                        collection = list\(previous_collection\)
                    existing_loop_state\["collection_size"\] = len\(collection\) if hasattr\(collection, "__len__"\) else 0"""

replacement = """                else:
                    existing_loop_state["collection_size"] = len(collection) if hasattr(collection, "__len__") else 0"""

text = re.sub(pattern, replacement, text)

with open("repos/noetl/noetl/core/dsl/engine/executor/commands.py", "w") as f:
    f.write(text)
print("Updated commands.py")
