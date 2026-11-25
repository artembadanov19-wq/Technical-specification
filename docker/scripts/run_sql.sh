#!/bin/bash
# ---------------------------------------------------------------------
# Запуск SQL-файла(ов) под пользователем test с таймингом и эхом команд.
#   docker exec -it oracle-test /opt/solution/scripts/run_sql.sh A1_top5_dolzhnikov.sql
#   docker exec -it oracle-test /opt/solution/scripts/run_sql.sh all
# Имя можно указать без пути — ищется в /opt/solution/A_SQL.
# ---------------------------------------------------------------------
export NLS_LANG=AMERICAN_AMERICA.AL32UTF8
DIR=/opt/solution/A_SQL
CONN="${APP_USER}/${APP_USER_PASSWORD}@//localhost:1521/FREEPDB1"

if [ "$1" = "all" ] || [ $# -eq 0 ]; then
    set -- A1_top5_dolzhnikov.sql A2_naydite_oshibku.sql A3_optimizaciya.sql B1_plsql_vygruzka_bonus.sql
fi

for f in "$@"; do
    [ -f "$f" ] || f="$DIR/$f"
    echo "================================================================"
    echo ">>> $f"
    echo "================================================================"
    sqlplus -s "$CONN" <<SQL
SET ECHO ON
SET TIMING ON
SET FEEDBACK ON
@$f
EXIT
SQL
done
