import asyncio
import asyncpg
import os

async def main():
    conn = await asyncpg.connect("postgresql://demo:demo@localhost:54321/noetl")
    
    # Try the exact load_next_facility query
    query = """
    WITH next_facility AS (
      SELECT facility_mapping_id, facility_name, facility_id, facility_org_uuid
      FROM public.pft_test_facilities
      WHERE active = TRUE
      ORDER BY facility_mapping_id ASC
      LIMIT 1
      FOR UPDATE SKIP LOCKED
    )
    UPDATE public.pft_test_facilities f
    SET active = FALSE, updated_at = NOW()
    FROM next_facility nf
    WHERE f.facility_mapping_id = nf.facility_mapping_id
    RETURNING nf.facility_mapping_id, nf.facility_name, nf.facility_id, nf.facility_org_uuid;
    """
    
    # Use execute (which is what execute_sql_statements_async uses via cursor)
    async with conn.transaction():
        async with conn.cursor() as cursor:
            await cursor.execute(query)
            print(f"Cursor description: {cursor.description}")
            if cursor.description:
                rows = await cursor.fetchmany(10)
                print(f"Rows: {rows}")
            else:
                print(f"Rowcount: {cursor.rowcount}")
                
    await conn.close()

asyncio.run(main())
