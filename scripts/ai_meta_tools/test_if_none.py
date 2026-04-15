control_args = {"__loop_claimed_index": 0}
claimed_index = control_args.get("__loop_claimed_index")

# Wait, if claimed_index is 0, is "if claimed_index" True or False?!
if claimed_index:
    print("It evaluated to True")
else:
    print("It evaluated to False!")

if claimed_index is not None:
    print("It is explicitly not None")
