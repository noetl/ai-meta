import asyncio
async def async_test():
    claimed_index = None
    collection = [1] * 100
    try:
        if claimed_index >= len(collection or []):
            print("No TypeError!")
    except Exception as e:
        print(f"Exception: {e}")

asyncio.run(async_test())
