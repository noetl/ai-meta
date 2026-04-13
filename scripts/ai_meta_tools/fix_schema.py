import re
filepath = "repos/noetl/noetl/database/ddl/postgres/schema_ddl.sql"
with open(filepath, "r") as f:
    content = f.read()

# The first create table is from lines 516-528
pattern = r"CREATE TABLE IF NOT EXISTS noetl\.execution \(\n    execution_id    BIGINT PRIMARY KEY,\n    catalog_id      BIGINT NOT NULL REFERENCES noetl\.catalog\(catalog_id\),\n    status          VARCHAR NOT NULL,\n    start_time      TIMESTAMP WITH TIME ZONE,\n    end_time        TIMESTAMP WITH TIME ZONE,\n    error           TEXT,\n    created_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,\n    updated_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP\n\);\n\nCREATE INDEX IF NOT EXISTS idx_execution_status ON noetl\.execution \(status\);\nCREATE INDEX IF NOT EXISTS idx_execution_catalog_id ON noetl\.execution \(catalog_id\);\nCREATE INDEX IF NOT EXISTS idx_execution_created_at ON noetl\.execution \(created_at DESC\);\n"
content = re.sub(pattern, "", content)

with open(filepath, "w") as f:
    f.write(content)
