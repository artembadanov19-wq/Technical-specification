# Oracle в Docker для проверки блока A

Используется Oracle Database 23ai Free (образ `gvenzl/oracle-free`, работает и на Intel/AMD, и на Apple Silicon). Нужен Docker Desktop с 2–3 ГБ свободной памяти.

## Запуск

```bash
cd docker
docker compose up -d --build
docker compose logs -f oracle      # ждём строку "DATABASE IS READY TO USE!" (1–3 мин при первом старте)
```

При первом старте автоматически выполняется следующее:
* создаётся пользователь `test/test` в PDB `FREEPDB1`;
* загружается `data/schema_setup.sql` — в логе будет таблица с числом строк (nachisleniya 1200, postupleniya 917 и т.д.);
* пользователю выдаётся доступ к словарю для просмотра планов (AUTOTRACE / DBMS_XPLAN);
* создаётся маленькое временное ТП `TEMP_SMALL` (16 МБ) для демо ORA-01652.

## Запуск решений

```bash
# все решения подряд (A1, A2, A3, B1) — с эхом команд и таймингом
docker exec -it oracle-test /opt/solution/scripts/run_sql.sh all

# по одному
docker exec -it oracle-test /opt/solution/scripts/run_sql.sh A1_top5_dolzhnikov.sql
docker exec -it oracle-test /opt/solution/scripts/run_sql.sh A2_naydite_oshibku.sql
docker exec -it oracle-test /opt/solution/scripts/run_sql.sh A3_optimizaciya.sql
docker exec -it oracle-test /opt/solution/scripts/run_sql.sh B1_plsql_vygruzka_bonus.sql
```

Папка `A_SQL` смонтирована в контейнер: правите файл — сразу запускаете, пересобирать не нужно.

## Демо ORA-01652 (A3)

```bash
docker exec -it oracle-test /opt/solution/scripts/temp_small.sh on     # TEMP пользователя -> 16 МБ
docker exec -it oracle-test /opt/solution/scripts/run_sql.sh A3_demo_ora01652.sql
docker exec -it oracle-test /opt/solution/scripts/temp_small.sh off    # вернуть обычный TEMP
```

Скрипт создаёт таблицу на 2,4 млн строк и ограничивает память под сортировки. После этого исходный запрос падает с **ORA-01652**, а переписанный отрабатывает. В статистике AUTOTRACE видно `sorts (disk)` и время.

## Подключение из IDE (DBeaver / SQL Developer / DataGrip)

| Параметр | Значение |
|---|---|
| Host | localhost |
| Port | 1521 |
| Service name | FREEPDB1 |
| User / Password | test / test |

## Прочее

```bash
docker exec -it oracle-test /opt/solution/scripts/reload_schema.sh   # перезалить исходные данные
docker exec -it oracle-test sqlplus test/test@//localhost/FREEPDB1    # интерактивный SQL*Plus
docker compose down          # остановить
docker compose down -v       # остановить и удалить БД (следующий старт — с нуля)
```

Если схема не загрузилась (в логе нет таблицы с числом строк), выполните `reload_schema.sh`.
