-- =====================================================================
-- A3. Оптимизация запроса, падающего с ORA-01652 (Oracle)
-- =====================================================================
SET DEFINE OFF
SET SQLBLANKLINES ON
SET LINESIZE 200
SET PAGESIZE 100
COLUMN region_sum FORMAT 999G999G999G999D99

-- ---------------------------------------------------------------------
-- Исходный запрос
-- ---------------------------------------------------------------------
-- SELECT DISTINCT
--        SUBSTR(n.inn,1,2) AS region_kod,
--        n.period,
--        n.inn,
--        SUM(n.summa) OVER (PARTITION BY SUBSTR(n.inn,1,2), n.period) AS region_sum
-- FROM   nachisleniya n
-- WHERE  TO_DATE(n.data_oper,'DD.MM.YYYY') >= TO_DATE('01.01.2024','DD.MM.YYYY')
-- ORDER  BY region_kod, n.period;

-- =====================================================================
-- ПОЧЕМУ ПАДАЕТ И ПОЧЕМУ НЕЭФФЕКТИВЕН
-- =====================================================================
-- ORA-01652 = сортировке/хэшированию не хватило памяти (PGA), операция
-- ушла во временное табличное пространство TEMP, и TEMP закончилось.
-- В плане этого запроса три тяжёлые операции над ВСЕМИ строками начислений:
--
--  1. WINDOW SORT. Аналитическая SUM() OVER (PARTITION BY регион, период)
--     считается по каждой из миллионов строк-операций: Oracle сортирует
--     весь набор по ключу партиции. Миллионы строк в PGA не влезают → TEMP.
--
--  2. SORT/HASH UNIQUE для DISTINCT. Окно не схлопывает строки: на выходе
--     столько же миллионов строк, сколько на входе (по строке на операцию,
--     у каждой — одинаковая region_sum). Затем DISTINCT ещё раз
--     сортирует/хэширует эти миллионы, чтобы оставить по строке на
--     регион+период+ИНН. DISTINCT здесь — костыль, компенсирующий то, что
--     вместо GROUP BY взяли оконную функцию.
--
--  3. ORDER BY — ещё одна сортировка результата (иногда совмещается с п.1/2,
--     но не гарантированно).
--
--  Дополнительно:
--  4. TO_DATE(n.data_oper, …) применяется к КОЛОНКЕ → предикат не
--     «sargable»: обычный индекс по data_oper не используется, секционирование
--     по дате (если бы было) не даёт pruning, функция вычисляется на каждой
--     строке. Плюс риск: одна «битая» строка ('31.02.2024', '', '2024-01-05')
--     роняет весь запрос с ORA-01847/ORA-01861 после долгого выполнения.
--     Кроме того, оптимизатор не может оценить селективность выражения и
--     ошибается с кардинальностью (по умолчанию 5 % для диапазона по функции).
--  5. Тащим лишнее: в окно идут все строки с исходной гранулярностью, хотя
--     для ответа достаточно сумм по ИНН — сначала свернуть, потом считать.
--  6. Смысловой вопрос: region_sum дублируется в каждой строке ИНН. Если
--     заказчику нужны только суммы по регионам/периодам — список ИНН не
--     нужен вовсе и результат сокращается до десятков строк.
--     Это надо уточнить у заказчика выгрузки.
--
-- =====================================================================
-- ПРИЁМЫ ОПТИМИЗАЦИИ / ОБХОДА (без расширения TEMP)
-- =====================================================================
--  1. Агрегировать ДО аналитики: GROUP BY регион, период, ИНН (HASH GROUP BY,
--     память ∝ числу групп, а не строк), затем окно или join по уже
--     свёрнутому набору. DISTINCT исчезает. Это главный приём.
--  2. Убрать окно совсем: суммы по региону+периоду — отдельный маленький
--     GROUP BY, присоединяемый HASH JOIN'ом к агрегату по ИНН.
--     Сортировок не остаётся (кроме финального ORDER BY).
--  3. Сделать фильтр sargable:
--     а) если по смыслу подходит отчётный период — фильтровать по period
--        (n7.period >= '202401': текст фиксированной длины 'YYYYMM'
--        сравнивается корректно), тогда работает индекс/pruning по period;
--     б) если нужна именно дата операции — виртуальная колонка
--        data_oper_dt AS (TO_DATE(data_oper,'DD.MM.YYYY')) + индекс/секционирование
--        по ней, либо function-based index по тому же выражению;
--     в) ON CONVERSION ERROR (12.2+), чтобы «битые» даты не роняли запрос
--        (и отдельно считать, сколько таких строк, — молча терять нельзя).
--  4. Убрать ORDER BY, если результат уходит в Excel/файл/таблицу — там
--     отсортируют. Сортировать миллионы строк на сервере ради выгрузки
--     бессмысленно. Если порядок нужен — сортировать маленький агрегат.
--  5. Разбить на порции (chunking): цикл по периодам/регионам,
--     INSERT /*+ APPEND */ в таблицу результата, COMMIT на порцию.
--     Каждая порция укладывается в PGA/TEMP; при сбое перезапускается
--     одна порция, а не весь расчёт (пример PL/SQL — ниже).
--  6. Секционирование nachisleniya по period (RANGE/LIST, INTERVAL) —
--     partition pruning + partition-wise агрегация. Долгосрочное решение,
--     через DBA.
--  7. Предрасчёт: материализованное представление / витрина
--     «ИНН × период × КБК» с ночным обновлением. Ad-hoc запросы идут в
--     витрину на тысячи строк, а не в сырые миллионы.
--  8. Сузить чтение: покрывающий индекс (period, inn, summa) → INDEX FAST
--     FULL SCAN по узкому сегменту вместо полного чтения широкой таблицы.
--  9. Тактический приём на сессию: ALTER SESSION SET workarea_size_policy=MANUAL
--     + sort_area_size/hash_area_size побольше — сортировка останется в
--     PGA. Использовать осторожно (PGA_AGGREGATE_LIMIT, соседние сессии) и
--     лучше по согласованию с DBA. И НЕ включать PARALLEL «для скорости»:
--     параллельные слейвы потребляют TEMP суммарно больше.
-- 10. Диагностика до/после: /*+ GATHER_PLAN_STATISTICS */ +
--     DBMS_XPLAN.DISPLAY_CURSOR(format => 'ALLSTATS LAST') — колонки
--     Used-Mem / Used-Tmp показывают, какая операция съела TEMP;
--     V$TEMPSEG_USAGE / V$SQL_WORKAREA_ACTIVE — в моменте.
--
-- =====================================================================
-- ПЕРЕПИСАННЫЙ ВАРИАНТ (основной) — та же семантика, что у исходного
-- =====================================================================
-- Фильтр по дате операции сохранён (это исходная бизнес-логика), но:
--  * DEFAULT NULL ON CONVERSION ERROR — битая дата не роняет расчёт;
--  * DATE-литерал вместо второго TO_DATE;
--  * сначала свёртка до ИНН, потом суммы региона из свёрнутого набора;
--  * окно и DISTINCT убраны, суммы региона — через HASH JOIN.
-- Результат построчно совпадает с исходным запросом (проверка — ниже).

WITH
inn_agg AS (                                     -- 1) свёртка: регион × период × ИНН
    SELECT SUBSTR(n7.inn, 1, 2)  AS region_kod,
           n7.period,
           n7.inn,
           SUM(n7.summa)         AS inn_sum
    FROM   nachisleniya n7
    WHERE  TO_DATE(n7.data_oper DEFAULT NULL ON CONVERSION ERROR, 'DD.MM.YYYY')
               >= DATE '2024-01-01'
    GROUP  BY SUBSTR(n7.inn, 1, 2), n7.period, n7.inn
),
region_agg AS (                                  -- 2) суммы региона × периода (десятки строк)
    SELECT region_kod, period, SUM(inn_sum) AS region_sum
    FROM   inn_agg
    GROUP  BY region_kod, period
),
calc_final AS (                                  -- 3) HASH JOIN маленького к среднему
    SELECT i.region_kod, i.period, i.inn, r.region_sum
    FROM   inn_agg    i
    JOIN   region_agg r ON r.region_kod = i.region_kod
                       AND r.period     = i.period
)
SELECT region_kod, period, inn, region_sum
FROM   calc_final
ORDER  BY region_kod, period;           -- убрать, если сортирует потребитель
-- Ожидаемо на тестовых данных: 480 строк (8 регионов × 6 периодов × 10 ИНН).


-- ---------------------------------------------------------------------
-- Вариант Б: то же самое через окно, но по свёрнутому набору.
-- Короче и читабельнее; окно сортирует уже не миллионы операций, а
-- строки «ИНН × период». Подходит, если таких строк умеренно.
-- ---------------------------------------------------------------------
WITH
calc_final AS (
    SELECT SUBSTR(n7.inn, 1, 2)                     AS region_kod,
           n7.period,
           n7.inn,
           SUM(SUM(n7.summa)) OVER (PARTITION BY SUBSTR(n7.inn, 1, 2), n7.period)
                                                    AS region_sum
    FROM   nachisleniya n7
    WHERE  TO_DATE(n7.data_oper DEFAULT NULL ON CONVERSION ERROR, 'DD.MM.YYYY')
               >= DATE '2024-01-01'
    GROUP  BY SUBSTR(n7.inn, 1, 2), n7.period, n7.inn
)
SELECT region_kod, period, inn, region_sum
FROM   calc_final
ORDER  BY region_kod, period;


-- ---------------------------------------------------------------------
-- Вариант В: если по смыслу достаточно отчётного периода (допущение —
-- согласовать!). Предикат по колонке без функции → индекс / pruning по
-- period. Внимание: семантика другая — доначисление в 2024 г. за 2023 г.
-- (period '2023xx', data_oper '…2024') сюда НЕ попадёт, а в исходный
-- запрос попало бы. На тестовых данных period всегда = месяц data_oper,
-- поэтому результат совпадает.
-- ---------------------------------------------------------------------
WITH
inn_agg AS (
    SELECT SUBSTR(n7.inn, 1, 2) AS region_kod, n7.period, n7.inn,
           SUM(n7.summa)        AS inn_sum
    FROM   nachisleniya n7
    WHERE  n7.period >= '202401'
    GROUP  BY SUBSTR(n7.inn, 1, 2), n7.period, n7.inn
),
calc_final AS (
    SELECT i.region_kod, i.period, i.inn,
           SUM(i.inn_sum) OVER (PARTITION BY i.region_kod, i.period) AS region_sum
    FROM   inn_agg i
)
SELECT region_kod, period, inn, region_sum
FROM   calc_final
ORDER  BY region_kod, period;


-- ---------------------------------------------------------------------
-- Вариант Г: если ИНН в выгрузке не нужны (уточнить у заказчика) —
-- только суммы по регионам. 48 строк вместо миллионов.
-- ---------------------------------------------------------------------
WITH
calc_final AS (
    SELECT SUBSTR(n7.inn, 1, 2) AS region_kod, n7.period,
           COUNT(DISTINCT n7.inn) AS inn_cnt,
           SUM(n7.summa)          AS region_sum
    FROM   nachisleniya n7
    WHERE  TO_DATE(n7.data_oper DEFAULT NULL ON CONVERSION ERROR, 'DD.MM.YYYY')
               >= DATE '2024-01-01'
    GROUP  BY SUBSTR(n7.inn, 1, 2), n7.period
)
SELECT region_kod, period, inn_cnt, region_sum
FROM   calc_final
ORDER  BY region_kod, period;


-- =====================================================================
-- ПРОВЕРКА ЭКВИВАЛЕНТНОСТИ: исходный запрос MINUS новый и наоборот.
-- Ожидаем 0 и 0. (На проде так не делать — исходный упадёт; здесь
-- данных мало.)
-- =====================================================================
WITH
old_q AS (
    SELECT DISTINCT SUBSTR(n.inn,1,2) AS region_kod, n.period, n.inn,
           SUM(n.summa) OVER (PARTITION BY SUBSTR(n.inn,1,2), n.period) AS region_sum
    FROM   nachisleniya n
    WHERE  TO_DATE(n.data_oper,'DD.MM.YYYY') >= TO_DATE('01.01.2024','DD.MM.YYYY')
),
inn_agg AS (
    SELECT SUBSTR(n7.inn, 1, 2) AS region_kod, n7.period, n7.inn, SUM(n7.summa) AS inn_sum
    FROM   nachisleniya n7
    WHERE  TO_DATE(n7.data_oper DEFAULT NULL ON CONVERSION ERROR, 'DD.MM.YYYY') >= DATE '2024-01-01'
    GROUP  BY SUBSTR(n7.inn, 1, 2), n7.period, n7.inn
),
calc_final AS (
    SELECT i.region_kod, i.period, i.inn,
           SUM(i.inn_sum) OVER (PARTITION BY i.region_kod, i.period) AS region_sum
    FROM   inn_agg i
)
SELECT 'old_minus_new' AS chk, COUNT(*) AS cnt
FROM  (SELECT * FROM old_q MINUS SELECT * FROM calc_final)
UNION ALL
SELECT 'new_minus_old', COUNT(*)
FROM  (SELECT * FROM calc_final MINUS SELECT * FROM old_q);

-- Сколько дат не распознаётся (такие строки новый запрос пропускает —
-- их нужно показать заказчику, а не терять молча). Ожидаем 0.
SELECT COUNT(*) AS bad_dates
FROM   nachisleniya n7
WHERE  n7.data_oper IS NOT NULL
AND    VALIDATE_CONVERSION(n7.data_oper AS DATE, 'DD.MM.YYYY') = 0;


-- =====================================================================
-- ДОЛГОСРОЧНЫЕ ИЗМЕНЕНИЯ (DDL — НЕ выполнять на проде без DBA/согласования)
-- =====================================================================
-- -- виртуальная колонка + индекс: фильтр по дате становится sargable
-- ALTER TABLE nachisleniya ADD (
--     data_oper_dt DATE GENERATED ALWAYS AS (TO_DATE(data_oper, 'DD.MM.YYYY')) VIRTUAL
-- );
-- CREATE INDEX ix_nach_doper_dt ON nachisleniya (data_oper_dt);
-- -- (перед этим убедиться, что битых дат нет: иначе DDL упадёт)
--
-- -- покрывающий индекс для свёртки без чтения таблицы
-- CREATE INDEX ix_nach_period_inn_sum ON nachisleniya (period, inn, summa);
--
-- -- секционирование по периоду (новая таблица + перегрузка / DBMS_REDEFINITION)
-- -- PARTITION BY LIST (period) AUTOMATIC   (12.2+)


-- =====================================================================
-- ОБХОД ЧЕРЕЗ ПОРЦИИ (chunking): по одному периоду за проход
-- =====================================================================
-- CREATE TABLE a3_result (
--     region_kod VARCHAR2(2), period VARCHAR2(6), inn VARCHAR2(12), region_sum NUMBER(18,2)
-- );
--
-- BEGIN
--     -- список периодов: HASH UNIQUE на десятки групп, TEMP не нужен.
--     -- Фильтр по period здесь НЕ ставим — критерий отбора остаётся датой
--     -- операции (см. семантику), period — только ключ нарезки порций.
--     FOR r IN (SELECT DISTINCT n7.period
--               FROM   nachisleniya n7
--               ORDER  BY n7.period)
--     LOOP
--         INSERT /*+ APPEND */ INTO a3_result (region_kod, period, inn, region_sum)
--         WITH inn_agg AS (
--             SELECT SUBSTR(n7.inn,1,2) AS region_kod, n7.period, n7.inn, SUM(n7.summa) AS inn_sum
--             FROM   nachisleniya n7
--             WHERE  n7.period = r.period
--             AND    TO_DATE(n7.data_oper DEFAULT NULL ON CONVERSION ERROR,'DD.MM.YYYY') >= DATE '2024-01-01'
--             GROUP  BY SUBSTR(n7.inn,1,2), n7.period, n7.inn
--         ),
--         calc_final AS (
--             SELECT i.region_kod, i.period, i.inn,
--                    SUM(i.inn_sum) OVER (PARTITION BY i.region_kod) AS region_sum
--             FROM   inn_agg i
--         )
--         SELECT region_kod, period, inn, region_sum FROM calc_final;
--         COMMIT;   -- после APPEND обязателен COMMIT перед следующим INSERT в ту же таблицу
--     END LOOP;
-- END;
-- /
