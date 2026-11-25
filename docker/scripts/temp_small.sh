#!/bin/bash
# ---------------------------------------------------------------------
# Переключает временное ТП пользователя test (для демо ORA-01652 в A3).
#   docker exec -it oracle-test /opt/solution/scripts/temp_small.sh on    # TEMP_SMALL, 16 МБ
#   docker exec -it oracle-test /opt/solution/scripts/temp_small.sh off   # обычный TEMP
# ---------------------------------------------------------------------
export NLS_LANG=AMERICAN_AMERICA.AL32UTF8
if [ "$1" = "on" ]; then TS=TEMP_SMALL; else TS=TEMP; fi
sqlplus -s / as sysdba <<SQL
ALTER SESSION SET CONTAINER = FREEPDB1;
ALTER USER ${APP_USER} TEMPORARY TABLESPACE ${TS};
COLUMN username FORMAT A10
COLUMN temporary_tablespace FORMAT A20
SELECT username, temporary_tablespace FROM dba_users WHERE username = UPPER('${APP_USER}');
EXIT
SQL
