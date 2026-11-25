-- =====================================================================
-- A3 — ДЕМО: воспроизводим ORA-01652 и показываем, что новый запрос
-- укладывается в те же ресурсы. Только для тестового стенда (Docker).
--
-- Порядок:
--   1) docker exec -it oracle-test /opt/solution/scripts/temp_small.sh on
--      (временное ТП пользователя test -> TEMP_SMALL, 16 МБ, без автоувеличения)
--   2) docker exec -it oracle-test /opt/solution/scripts/run_sql.sh A3_demo_ora01652.sql
--   3) docker exec -it oracle-test /opt/solution/scripts/temp_small.sh off
--
-- Что ожидать:
--   * исходный запрос  -> ORA-01652: unable to extend temp segment ... TEMP_SMALL
--   * новый запрос     -> отрабатывает; в статистике «sorts (disk)» = 0 или
--                         единицы, время — доли секунды/секунды.
-- Без шага 1 (обычный TEMP с автоувеличением) исходный запрос не упадёт,
-- но в AUTOTRACE будет видно «sorts (disk)» > 0 и разницу во времени.
-- =====================================================================
SET DEFINE OFF
SET SQLBLANKLINES ON
SET LINESIZE 200
SET PAGESIZE 200
SET TIMING ON

-- ---------------------------------------------------------------------
-- 1. «Продовая» таблица: 1200 × 2000 = 2,4 млн строк, ~4000 ИНН
-- ---------------------------------------------------------------------
BEGIN EXECUTE IMMEDIATE 'DROP TABLE nachisleniya_big PURGE'; EXCEPTION WHEN OTHERS THEN IF SQLCODE != -942 THEN RAISE; END IF; END;
/

CREATE TABLE nachisleniya_big NOLOGGING AS
SELECT n.id + (g.l - 1) * 100000                                         AS id,
       SUBSTR(n.inn, 1, 2)
       || LPAD(TO_CHAR(MOD(TO_NUMBER(SUBSTR(n.inn, 3)) + MOD(g.l, 50) * 7919, 100000000)), 8, '0')
                                                                          AS inn,
       n.kbk,
       n.period,
       ROUND(n.summa * (0.5 + MOD(g.l, 100) / 100), 2)                    AS summa,
       n.data_oper
FROM   nachisleniya n
CROSS  JOIN (SELECT LEVEL AS l FROM dual CONNECT BY LEVEL <= 2000) g;

EXEC DBMS_STATS.GATHER_TABLE_STATS(USER, 'NACHISLENIYA_BIG')

SELECT COUNT(*) AS rows_cnt, COUNT(DISTINCT inn) AS inn_cnt FROM nachisleniya_big;

-- ---------------------------------------------------------------------
-- 2. Ограничиваем память сессии под сортировки (имитация нагруженного
--    прода, где PGA на всех не хватает)
-- ---------------------------------------------------------------------
ALTER SESSION SET workarea_size_policy = MANUAL;
ALTER SESSION SET sort_area_size = 1048576;
ALTER SESSION SET hash_area_size = 2097152;

-- строки результата не печатаем — нужны план, статистика и время
SET AUTOTRACE TRACEONLY EXPLAIN STATISTICS

-- ---------------------------------------------------------------------
-- 3. ИСХОДНЫЙ запрос (ожидаем ORA-01652 на TEMP_SMALL)
-- ---------------------------------------------------------------------
SELECT DISTINCT
       SUBSTR(n.inn,1,2) AS region_kod,
       n.period,
       n.inn,
       SUM(n.summa) OVER (PARTITION BY SUBSTR(n.inn,1,2), n.period) AS region_sum
FROM   nachisleniya_big n
WHERE  TO_DATE(n.data_oper,'DD.MM.YYYY') >= TO_DATE('01.01.2024','DD.MM.YYYY')
ORDER  BY region_kod, n.period;

-- ---------------------------------------------------------------------
-- 4. НОВЫЙ запрос (основной вариант из A3_optimizaciya.sql)
-- ---------------------------------------------------------------------
WITH
inn_agg AS (
    SELECT SUBSTR(n7.inn, 1, 2)  AS region_kod,
           n7.period,
           n7.inn,
           SUM(n7.summa)         AS inn_sum
    FROM   nachisleniya_big n7
    WHERE  TO_DATE(n7.data_oper DEFAULT NULL ON CONVERSION ERROR, 'DD.MM.YYYY')
               >= DATE '2024-01-01'
    GROUP  BY SUBSTR(n7.inn, 1, 2), n7.period, n7.inn
),
region_agg AS (
    SELECT region_kod, period, SUM(inn_sum) AS region_sum
    FROM   inn_agg
    GROUP  BY region_kod, period
),
calc_final AS (
    SELECT i.region_kod, i.period, i.inn, r.region_sum
    FROM   inn_agg    i
    JOIN   region_agg r ON r.region_kod = i.region_kod
                       AND r.period     = i.period
)
SELECT region_kod, period, inn, region_sum
FROM   calc_final
ORDER  BY region_kod, period;

SET AUTOTRACE OFF

-- ---------------------------------------------------------------------
-- 5. Возврат настроек и уборка
-- ---------------------------------------------------------------------
ALTER SESSION SET workarea_size_policy = AUTO;
-- DROP TABLE nachisleniya_big PURGE;   -- раскомментировать, если не нужна
