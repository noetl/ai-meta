import re

filepath = "repos/noetl/noetl/core/dsl/v2/engine.py"
with open(filepath, "r") as f:
    content = f.read()

# Replace the incorrect epoch_relative calculation
target_pattern = r"            if completed_count > snapshot_epoch_size:\n                epoch_relative_count = max\(0, snapshot_completed_count\)\n                epoch_relative_scheduled = max\(epoch_relative_count, snapshot_scheduled_count\)"
replacement = """            if completed_count > snapshot_epoch_size:
                # Use modulus to get the actual completed/scheduled count within the CURRENT epoch,
                # ensuring that exactly completing a multiple of epoch_size returns the full size,
                # rather than 0, unless no work has been done in the current epoch.
                epoch_relative_count = completed_count % snapshot_epoch_size
                if epoch_relative_count == 0 and completed_count > 0:
                    # If we perfectly finished N epochs, the relative count of the current (just-finished) epoch is its size
                    epoch_relative_count = snapshot_epoch_size
                    
                epoch_relative_scheduled = scheduled_count % snapshot_epoch_size
                if epoch_relative_scheduled == 0 and scheduled_count > 0:
                    epoch_relative_scheduled = snapshot_epoch_size"""

if re.search(target_pattern, content):
    content = re.sub(target_pattern, replacement, content)
    with open(filepath, "w") as f:
        f.write(content)
    print("Patched successfully!")
else:
    print("Pattern not found!")
