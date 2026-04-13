import re

filepath = "repos/noetl/noetl/core/dsl/v2/engine.py"
with open(filepath, "r") as f:
    content = f.read()

# Fix the modulus arithmetic logic. The issue with `190 % 100 = 90` is perfectly correct.
# However, if we had `completed_count=190`, `snapshot_completed_count` from NATS might actually
# be tracking the *current epoch only* natively (e.g. `90`).
# So if `snapshot_completed_count` is valid and < `snapshot_epoch_size`, we should prefer the
# snapshot's state directly, rather than mathematically guessing across all events.

target_pattern = r"                epoch_relative_count = completed_count % snapshot_epoch_size\n                if epoch_relative_count == 0 and completed_count > 0:\n                    # If we perfectly finished N epochs, the relative count of the current \(just-finished\) epoch is its size\n                    epoch_relative_count = snapshot_epoch_size\n                    \n                epoch_relative_scheduled = scheduled_count % snapshot_epoch_size\n                if epoch_relative_scheduled == 0 and scheduled_count > 0:\n                    epoch_relative_scheduled = snapshot_epoch_size"

replacement = """                # Prefer the explicit epoch-scoped progress tracked in the NATS snapshot,
                # falling back to modulus estimation if the snapshot is empty/missing.
                epoch_relative_count = snapshot_completed_count
                if epoch_relative_count == 0 and completed_count > 0 and (completed_count % snapshot_epoch_size) > 0:
                    epoch_relative_count = completed_count % snapshot_epoch_size
                elif epoch_relative_count == 0 and completed_count > 0 and (completed_count % snapshot_epoch_size) == 0:
                    epoch_relative_count = snapshot_epoch_size
                    
                epoch_relative_scheduled = snapshot_scheduled_count
                if epoch_relative_scheduled == 0 and scheduled_count > 0 and (scheduled_count % snapshot_epoch_size) > 0:
                    epoch_relative_scheduled = scheduled_count % snapshot_epoch_size
                elif epoch_relative_scheduled == 0 and scheduled_count > 0 and (scheduled_count % snapshot_epoch_size) == 0:
                    epoch_relative_scheduled = snapshot_epoch_size"""

if re.search(target_pattern, content):
    content = re.sub(target_pattern, replacement, content)
    with open(filepath, "w") as f:
        f.write(content)
    print("Patched successfully!")
else:
    print("Pattern not found!")
