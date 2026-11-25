#!/bin/bash
# ---------------------------------------------------------------------
# Выполняется entrypoint'ом gvenzl один раз, при первом старте БД.
# Файл подключается через source — поэтому без exit.
# ---------------------------------------------------------------------
export NLS_LANG=AMERICAN_AMERICA.AL32UTF8

echo ">>> [init] гранты и временное ТП для демо A3"
sqlplus -s / as sysdba <<SQL
WHENEVER SQLERROR CONTINUE
ALTER SESSION SET CONTAINER = FREEPDB1;
-- для DBMS_XPLAN.DISPLAY_CURSOR и AUTOTRACE (просмотр планов и статистик)
GRANT SELECT ANY DICTIONARY TO ${APP_USER};
-- маленькое временное ТП (16 МБ, без автоувеличения) — чтобы воспроизвести ORA-01652
DECLARE
    v_dir VARCHAR2(512);
BEGIN
    SELECT SUBSTR(file_name, 1, INSTR(file_name, '/', -1))
    INTO   v_dir
    FROM   dba_data_files
    WHERE  ROWNUM = 1;
    EXECUTE IMMEDIATE 'CREATE TEMPORARY TABLESPACE temp_small TEMPFILE '''
                      || v_dir || 'temp_small01.dbf'' SIZE 16M AUTOEXTEND OFF';
END;
/
EXIT
SQL

echo ">>> [init] загрузка schema_setup.sql в схему ${APP_USER}"
sqlplus -s "${APP_USER}/${APP_USER_PASSWORD}@//localhost:1521/FREEPDB1" <<SQL
SET FEEDBACK OFF
@/opt/solution/data/schema_setup.sql
SET FEEDBACK ON
SELECT 'nachisleniya' AS tbl, COUNT(*) AS cnt FROM nachisleniya
UNION ALL SELECT 'postupleniya', COUNT(*) FROM postupleniya
UNION ALL SELECT 'nalogoplatelshchiki', COUNT(*) FROM nalogoplatelshchiki
UNION ALL SELECT 'kbk_spr', COUNT(*) FROM kbk_spr
UNION ALL SELECT 'excluded_kbk', COUNT(*) FROM excluded_kbk
UNION ALL SELECT 'regiony', COUNT(*) FROM regiony;
EXIT
SQL
echo ">>> [init] готово"
