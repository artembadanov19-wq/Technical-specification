-- =====================================================================
-- A2. Найдите ошибку (Oracle)
-- =====================================================================
SET DEFINE OFF
SET SQLBLANKLINES ON
SET LINESIZE 200
SET PAGESIZE 100
COLUMN nachisleno FORMAT 999G999G999G999D99
COLUMN oplacheno  FORMAT 999G999G999G999D99
COLUMN nedoimka   FORMAT 999G999G999G999D99

-- ---------------------------------------------------------------------
-- Исходный запрос аналитика (как есть)
-- ---------------------------------------------------------------------
SELECT n.inn, SUM(n.summa) - SUM(p.summa) AS nedoimka
FROM   nachisleniya n, postupleniya p
WHERE  n.inn = p.inn
AND    n.kbk NOT IN (SELECT kbk FROM excluded_kbk)
GROUP  BY n.inn;
-- Результат: «no rows selected» — 0 строк.

-- =====================================================================
-- ЧТО ФАКТИЧЕСКИ ВЕРНЁТ ЗАПРОС И ПОЧЕМУ
-- =====================================================================
-- На текущих данных — ПУСТОЙ результат, без ошибки.
-- В excluded_kbk есть строка с NULL. Условие
--     n.kbk NOT IN (k1, k2, k3, NULL)
-- раскрывается в  n.kbk <> k1 AND n.kbk <> k2 AND n.kbk <> k3 AND n.kbk <> NULL.
-- Сравнение с NULL даёт UNKNOWN, значит всё выражение — FALSE или UNKNOWN,
-- но никогда не TRUE. WHERE отбрасывает ВСЕ строки.
-- Это самый коварный вариант: запрос «отработал», отчёт пустой (или,
-- хуже, его подклеят к другим данным и пустоту никто не заметит).
--
-- Но даже если NULL из справочника убрать, остальные ошибки дадут
-- неверные цифры (см. демонстрацию ниже).
--
-- =====================================================================
-- СПИСОК ОШИБОК
-- =====================================================================
-- 1. NOT IN + NULL в подзапросе → 0 строк (см. выше).
--    Исправление: NOT EXISTS (не чувствителен к NULL) или
--    NOT IN (SELECT kbk FROM excluded_kbk WHERE kbk IS NOT NULL).
--    NOT EXISTS предпочтительнее: правильная семантика «анти-join»
--    без оговорок, оптимизатор строит HASH JOIN ANTI.
--
-- 2. Соединение строк по одному ИНН до агрегации → декартово произведение
--    («fan-out»). Каждая строка начислений ИНН склеивается с каждой
--    строкой его поступлений: при N начислениях и M платежах
--    SUM(n.summa) умножается на M, SUM(p.summa) — на N.
--    Пример (ИНН 7875357179, 12 начислений по неисключённым КБК, 18 платежей):
--      реально: начислено  7 157 006,65; оплачено   8 244 590,16; итог  −1 087 583,51
--      запрос:  начислено 128 826 119,70; оплачено 156 289 538,52; итог −27 463 418,82
--    Исправление: агрегировать начисления и поступления ОТДЕЛЬНО до
--    уровня ИНН, затем соединять агрегаты (1:1).
--
-- 3. Неявный INNER JOIN (запятая + WHERE n.inn = p.inn) → налогоплательщики
--    без единого платежа пропадают из результата. А это как раз самые
--    злостные должники (недоимка = 100 % начисленного): 10 ИНН, например
--    5002116283 с недоимкой 12,8 млн — крупнейшей во всей выгрузке.
--    Исправление: FULL (или LEFT) OUTER JOIN агрегатов.
--
-- 4. Исключения применены только к начислениям. Поступления по
--    исключённым КБК (штрафы, госпошлина, пени) вычитаются из налоговых
--    начислений → недоимка занижена.
--    Исправление: тот же фильтр по excluded_kbk и для p.kbk.
--
-- 5. NULL в суммах. SUM игнорирует NULL — это нормально, но если у ИНН
--    все платежи NULL (или после внешнего соединения платежей нет),
--    SUM(p.summa) = NULL и вся разность становится NULL вместо
--    «начислено − 0». Исправление: NVL(SUM(...), 0) / SUM(NVL(...,0)).
--
-- 6. (Стиль / сопровождаемость) Старый синтаксис соединения через запятую:
--    условие соединения смешано с фильтрами, легко потерять и получить
--    CROSS JOIN. Нет ORDER BY и нет колонок «начислено/оплачено» — цифру
--    недоимки невозможно проверить глазами. Явно не задан период — запрос
--    считает всё сальдо за всю историю (зафиксировал как допущение: так и
--    задумано, «недоимка нарастающим итогом»).
--
-- Допущение: «КБК не из списка исключений» трактую буквально — фильтр по
-- excluded_kbk (как в постановке), а не по kbk_spr.priznak_nalog. На этих
-- данных результат одинаковый (исключены ровно 3 неналоговых КБК).
-- Допущение: сальдируем на уровне ИНН по всем КБК и периодам.


-- =====================================================================
-- ИСПРАВЛЕННЫЙ ВАРИАНТ
-- =====================================================================
WITH
nach AS (
    SELECT n7.inn,
           SUM(n7.summa)          AS nachisleno
    FROM   nachisleniya n7
    WHERE  NOT EXISTS (SELECT 1 FROM excluded_kbk e WHERE e.kbk = n7.kbk)
    GROUP  BY n7.inn
),
opl AS (
    SELECT p7.inn,
           SUM(NVL(p7.summa, 0))  AS oplacheno
    FROM   postupleniya p7
    WHERE  NOT EXISTS (SELECT 1 FROM excluded_kbk e WHERE e.kbk = p7.kbk)
    GROUP  BY p7.inn
),
calc_final AS (
    SELECT COALESCE(nach.inn, opl.inn)                       AS inn,
           NVL(nach.nachisleno, 0)                           AS nachisleno,
           NVL(opl.oplacheno, 0)                             AS oplacheno,
           NVL(nach.nachisleno, 0) - NVL(opl.oplacheno, 0)   AS nedoimka
    FROM   nach
    FULL   OUTER JOIN opl ON opl.inn = nach.inn
)
SELECT inn, nachisleno, oplacheno, nedoimka
FROM   calc_final
ORDER  BY nedoimka DESC, inn;
-- Ожидаемо: 80 строк (все ИНН, включая 10 без платежей),
-- суммарная недоимка 315 124 335,19 (сходится с Python и Excel).


-- =====================================================================
-- ДЕМОНСТРАЦИЯ ОШИБОК (для скриншотов / пояснения на интервью)
-- =====================================================================

-- (а) NULL в списке исключений
SELECT COUNT(*) AS cnt_all, COUNT(kbk) AS cnt_not_null FROM excluded_kbk;   -- 4 и 3

-- (б) Исходный запрос, но с отфильтрованным NULL — строки появились,
--     но их 70 (а не 80), и суммы раздуты fan-out'ом
SELECT COUNT(*) AS rows_cnt, SUM(nedoimka) AS total_nedoimka
FROM (
    SELECT n.inn, SUM(n.summa) - SUM(p.summa) AS nedoimka
    FROM   nachisleniya n, postupleniya p
    WHERE  n.inn = p.inn
    AND    n.kbk NOT IN (SELECT kbk FROM excluded_kbk WHERE kbk IS NOT NULL)
    GROUP  BY n.inn
);
-- 70 строк и 2 295 765 258,91 против правильных 80 строк и 315 124 335,19

-- (в) Fan-out на одном ИНН: сколько строк даёт соединение
SELECT COUNT(*)                                   AS joined_rows,
       COUNT(DISTINCT n.id)                       AS nach_rows,
       COUNT(DISTINCT p.id)                       AS post_rows
FROM   nachisleniya n
JOIN   postupleniya p ON p.inn = n.inn
WHERE  n.inn = '7875357179'
AND    NOT EXISTS (SELECT 1 FROM excluded_kbk e WHERE e.kbk = n.kbk);
-- 216 = 12 × 18

-- (г) Налогоплательщики, которых теряет INNER JOIN
SELECT DISTINCT n7.inn
FROM   nachisleniya n7
WHERE  NOT EXISTS (SELECT 1 FROM postupleniya p7 WHERE p7.inn = n7.inn)
ORDER  BY n7.inn;   -- 10 ИНН
