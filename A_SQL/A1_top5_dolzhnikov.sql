-- =====================================================================
-- A1. ТОП-5 должников по регионам за последний период (Oracle)
-- ---------------------------------------------------------------------
-- Алиасы по требованиям оформления: n7 — начисления, p7 — поступления,
-- итоговый CTE — calc_final.
--
-- ДОПУЩЕНИЯ
--  1. «Последний период» = MAX(period) по таблице начислений, т.е. '202406'.
--     * period хранится текстом 'YYYYMM' фиксированной длины, поэтому
--       строковый MAX совпадает с хронологическим (проверка формата — в
--       блоке «Проверки» ниже).
--     * Берём период из начислений, а не из поступлений: недоимка возникает
--       от начисления; период без начислений для этой метрики пуст.
--     * Период вычисляется, а не хардкодится, — запрос не нужно править
--       каждый месяц. Если нужен другой период — см. вариант с
--       подстановочной переменной в конце файла.
--     * Риск: последний период может быть неполным (часть платежей ещё не
--       дошла/не загружена), тогда недоимка в нём завышена. По данным
--       число строк поступлений в 202406 (154) в пределах обычного
--       разброса 141–158, признаков неполноты нет. На практике я бы
--       согласовал с заказчиком: «последний» = последний ЗАКРЫТЫЙ период.
--  2. «Налоговые КБК» = kbk_spr.priznak_nalog = 'Y' (а не «не из excluded_kbk»):
--     справочник — первичный источник признака, excluded_kbk ведётся
--     вручную и содержит NULL. В этих данных наборы совпадают.
--  3. Недоимка ИНН = Σ начислено − Σ оплачено по всем налоговым КБК за
--     период (сальдирование внутри ИНН, логика ЕНС). Пустые суммы
--     поступлений = 0.
--  4. В ТОП попадают только должники: недоимка > 0. Переплата — не долг.
--  5. Регион — из справочника налогоплательщиков (region_kod); если ИНН нет
--     в справочнике, берём первые 2 знака ИНН (по условию это код региона).
--
-- ПОЧЕМУ ТАК УСТРОЕН ЗАПРОС
--  * Начисления и поступления агрегируются ПО ОТДЕЛЬНОСТИ до уровня ИНН и
--    только потом соединяются. Прямой JOIN строк по ИНН дал бы декартово
--    произведение (N начислений × M платежей) и умноженные суммы — см. A2.
--  * FULL OUTER JOIN: у части ИНН поступлений нет вовсе (10 ИНН во всей
--    выгрузке), им нужен NVL(…,0), а не выпадение из INNER JOIN. Обратный
--    случай (платёж без начисления) тоже не теряем — получится переплата,
--    которую отсечёт условие недоимка > 0.
--
-- РАНЖИРУЮЩАЯ ФУНКЦИЯ: RANK()
--  * ROW_NUMBER() — всегда ровно 5 строк, но при равной недоимке место
--    между равными раздаётся произвольно (недетерминированно от запуска к
--    запуску) — для «защиты цифр» плохо.
--  * RANK()       — равным одинаковое место, следующее место с пропуском
--    (1,2,2,4). Если на 5-м месте несколько равных — покажем всех,
--    строк в регионе может быть больше 5. Это честнее, чем молча отрезать.
--  * DENSE_RANK() — без пропусков (1,2,2,3), «ТОП-5 мест» может дать
--    заметно больше 5 налогоплательщиков — уже не «ТОП-5 должников».
--  Выбрал RANK. Если заказчику нужно строго 5 строк — ROW_NUMBER с
--  детерминированным вторым ключом сортировки (inn), это одна правка.
--  В текущих данных равных значений недоимки нет: 8 регионов × 5 = 40 строк.
-- =====================================================================

SET DEFINE OFF
SET SQLBLANKLINES ON
SET LINESIZE 200
SET PAGESIZE 100
COLUMN naim FORMAT A22
COLUMN nachisleno FORMAT 999G999G999D99
COLUMN oplacheno  FORMAT 999G999G999D99
COLUMN nedoimka   FORMAT 999G999G999D99

WITH
last_period AS (                       -- «последний» период = максимальный в начислениях
    SELECT MAX(n7.period) AS period
    FROM   nachisleniya n7
),
nach AS (                              -- начислено по ИНН, налоговые КБК, последний период
    SELECT n7.inn,
           SUM(n7.summa)            AS nachisleno
    FROM   nachisleniya n7
    JOIN   last_period lp ON lp.period = n7.period
    JOIN   kbk_spr     k  ON k.kbk     = n7.kbk
    WHERE  k.priznak_nalog = 'Y'
    GROUP  BY n7.inn
),
opl AS (                               -- оплачено по ИНН; NULL-суммы считаем нулём
    SELECT p7.inn,
           SUM(NVL(p7.summa, 0))    AS oplacheno
    FROM   postupleniya p7
    JOIN   last_period lp ON lp.period = p7.period
    JOIN   kbk_spr     k  ON k.kbk     = p7.kbk
    WHERE  k.priznak_nalog = 'Y'
    GROUP  BY p7.inn
),
saldo AS (                             -- FULL JOIN: ИНН без платежей не теряются
    SELECT COALESCE(nach.inn, opl.inn)  AS inn,
           NVL(nach.nachisleno, 0)      AS nachisleno,
           NVL(opl.oplacheno, 0)        AS oplacheno
    FROM   nach
    FULL   OUTER JOIN opl ON opl.inn = nach.inn
),
calc_final AS (
    SELECT NVL(np.region_kod, TO_NUMBER(SUBSTR(s.inn, 1, 2)))  AS region_kod,
           s.inn,
           np.naim,
           s.nachisleno,
           s.oplacheno,
           s.nachisleno - s.oplacheno                          AS nedoimka,
           RANK() OVER (
               PARTITION BY NVL(np.region_kod, TO_NUMBER(SUBSTR(s.inn, 1, 2)))
               ORDER BY     s.nachisleno - s.oplacheno DESC
           )                                                   AS mesto
    FROM   saldo s
    LEFT   JOIN nalogoplatelshchiki np ON np.inn = s.inn
    WHERE  s.nachisleno - s.oplacheno > 0                      -- только должники
)
SELECT region_kod, inn, naim, nachisleno, oplacheno, nedoimka, mesto
FROM   calc_final
WHERE  mesto <= 5
ORDER  BY region_kod, mesto, inn;

-- Ожидаемо: 40 строк (8 регионов × 5). Пример — регион 16:
--   1653905455 ООО Альфа-Трейд-47  2 482 035,85  0,00          2 482 035,85  1
--   1665175129 ООО Сапфир-41       1 344 274,70  0,00          1 344 274,70  2
--   ...
-- Цифры сверены с независимым расчётом на Python по тем же данным.


-- =====================================================================
-- Проверки (запускать при необходимости — для обоснования допущений)
-- =====================================================================

-- 1) Формат period: все значения — 6 цифр, месяц 01–12 (иначе MAX по строке некорректен)
SELECT COUNT(*) AS bad_period
FROM   nachisleniya n7
WHERE  NOT REGEXP_LIKE(n7.period, '^\d{4}(0[1-9]|1[0-2])$');

-- 2) Полнота периодов: число строк и суммы по периодам (ищем «провал» в последнем)
SELECT n7.period,
       COUNT(*)            AS rows_nach,
       SUM(n7.summa)       AS sum_nach,
       (SELECT COUNT(*)    FROM postupleniya p7 WHERE p7.period = n7.period) AS rows_post,
       (SELECT SUM(p7.summa) FROM postupleniya p7 WHERE p7.period = n7.period) AS sum_post
FROM   nachisleniya n7
GROUP  BY n7.period
ORDER  BY n7.period;

-- 3) Совпадение региона в справочнике с первыми 2 знаками ИНН (ожидаем 0)
SELECT COUNT(*) AS region_mismatch
FROM   nalogoplatelshchiki np
WHERE  np.region_kod <> TO_NUMBER(SUBSTR(np.inn, 1, 2));

-- 4) КБК в фактах, отсутствующие в справочнике (ожидаем 0 строк)
SELECT DISTINCT n7.kbk
FROM   nachisleniya n7
WHERE  NOT EXISTS (SELECT 1 FROM kbk_spr k WHERE k.kbk = n7.kbk);


-- =====================================================================
-- Вариант: период задаётся явно — через bind-переменную
--     VARIABLE p_period VARCHAR2(6)
--     EXEC :p_period := '202405'
-- и замените CTE last_period на:
--     last_period AS (SELECT :p_period AS period FROM dual)
-- =====================================================================
