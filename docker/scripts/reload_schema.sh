#!/bin/bash
# Перезалить исходные данные (если что-то сломали в схеме).
#   docker exec -it oracle-test /opt/solution/scripts/reload_schema.sh
export NLS_LANG=AMERICAN_AMERICA.AL32UTF8
sqlplus -s "${APP_USER}/${APP_USER_PASSWORD}@//localhost:1521/FREEPDB1" <<SQL
SET FEEDBACK OFF
@/opt/solution/data/schema_setup.sql
SET FEEDBACK ON
SELECT COUNT(*) AS nachisleniya FROM nachisleniya;
EXIT
SQL
