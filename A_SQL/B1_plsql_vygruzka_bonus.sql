-- =====================================================================
-- B1 (бонус). PL/SQL: регулярная выгрузка недоимки
-- ---------------------------------------------------------------------
-- В разделе «Что и как прислать» упомянут файл B1, но отдельной задачи
-- B1 в тексте нет. Допущение: имелся в виду PL/SQL (он есть в списке
-- проверяемой техники). Делаю небольшую процедуру регулярной выгрузки —
-- ту самую, о которой кейс E3: set-based вместо курсорного цикла,
-- параметры вместо хардкода, обработка ошибок, лог, комментарии.
--
-- Что делает: за период (и, опционально, регион) пересчитывает недоимку
-- по ИНН (налоговые КБК) в таблицу nedoimka_vygruzka. Повторный запуск
-- за тот же период идемпотентен: старый срез удаляется и пишется заново
-- в одной транзакции.
-- =====================================================================
SET DEFINE OFF
SET SQLBLANKLINES ON
SET SERVEROUTPUT ON
SET LINESIZE 200

-- ---------- объекты (пересоздаются) ----------
BEGIN EXECUTE IMMEDIATE 'DROP TABLE nedoimka_vygruzka PURGE'; EXCEPTION WHEN OTHERS THEN IF SQLCODE != -942 THEN RAISE; END IF; END;
/
BEGIN EXECUTE IMMEDIATE 'DROP TABLE etl_log PURGE'; EXCEPTION WHEN OTHERS THEN IF SQLCODE != -942 THEN RAISE; END IF; END;
/

CREATE TABLE etl_log (
    log_id      NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    proc_name   VARCHAR2(100),
    params      VARCHAR2(400),
    status      VARCHAR2(10),          -- OK / ERROR
    rows_cnt    NUMBER,
    msg         VARCHAR2(4000),
    started_at  TIMESTAMP,
    finished_at TIMESTAMP DEFAULT SYSTIMESTAMP
);

CREATE TABLE nedoimka_vygruzka (
    period      VARCHAR2(6)   NOT NULL,
    region_kod  NUMBER(2)     NOT NULL,
    inn         VARCHAR2(12)  NOT NULL,
    naim        VARCHAR2(200),
    nachisleno  NUMBER(18,2)  NOT NULL,
    oplacheno   NUMBER(18,2)  NOT NULL,
    nedoimka    NUMBER(18,2)  NOT NULL,
    loaded_at   DATE DEFAULT SYSDATE NOT NULL,
    CONSTRAINT pk_nedoimka_vygruzka PRIMARY KEY (period, inn)
);

-- ---------- логирование в автономной транзакции ----------
-- Запись в лог переживает ROLLBACK основной транзакции — иначе при ошибке
-- мы потеряли бы и данные, и сам факт ошибки.
CREATE OR REPLACE PROCEDURE p_etl_log (
    p_proc    IN VARCHAR2,
    p_params  IN VARCHAR2,
    p_status  IN VARCHAR2,
    p_rows    IN NUMBER,
    p_msg     IN VARCHAR2,
    p_started IN TIMESTAMP
) IS
    PRAGMA AUTONOMOUS_TRANSACTION;
BEGIN
    INSERT INTO etl_log (proc_name, params, status, rows_cnt, msg, started_at)
    VALUES (p_proc, p_params, p_status, p_rows, SUBSTR(p_msg, 1, 4000), p_started);
    COMMIT;
END p_etl_log;
/

-- ---------- основная процедура ----------
CREATE OR REPLACE PROCEDURE p_nedoimka_vygruzka (
    p_period IN  VARCHAR2,               -- 'YYYYMM', обязательный
    p_region IN  NUMBER DEFAULT NULL,    -- NULL = все регионы
    p_rows   OUT NUMBER                  -- сколько строк записано
) IS
    c_proc    CONSTANT VARCHAR2(100) := 'P_NEDOIMKA_VYGRUZKA';
    v_params  VARCHAR2(400) := 'period=' || p_period || ', region=' || NVL(TO_CHAR(p_region), 'ALL');
    v_started TIMESTAMP     := SYSTIMESTAMP;
    v_cnt     NUMBER;
BEGIN
    -- 1. Валидация параметров: падаем сразу и понятно, а не через 40 минут
    IF p_period IS NULL OR NOT REGEXP_LIKE(p_period, '^\d{4}(0[1-9]|1[0-2])$') THEN
        RAISE_APPLICATION_ERROR(-20001, 'Некорректный период: "' || p_period || '", ожидается YYYYMM');
    END IF;

    SELECT COUNT(*) INTO v_cnt FROM nachisleniya n7 WHERE n7.period = p_period AND ROWNUM = 1;
    IF v_cnt = 0 THEN
        RAISE_APPLICATION_ERROR(-20002, 'Нет начислений за период ' || p_period);
    END IF;

    -- 2. Идемпотентность: удаляем прежний срез за те же параметры
    DELETE FROM nedoimka_vygruzka v
    WHERE  v.period = p_period
    AND   (p_region IS NULL OR v.region_kod = p_region);

    -- 3. Один set-based INSERT вместо построчного цикла.
    --    Агрегируем начисления и поступления раздельно, затем FULL JOIN (см. A1/A2).
    INSERT INTO nedoimka_vygruzka (period, region_kod, inn, naim, nachisleno, oplacheno, nedoimka)
    WITH
    nach AS (
        SELECT n7.inn, SUM(n7.summa) AS nachisleno
        FROM   nachisleniya n7
        JOIN   kbk_spr k ON k.kbk = n7.kbk AND k.priznak_nalog = 'Y'
        WHERE  n7.period = p_period
        GROUP  BY n7.inn
    ),
    opl AS (
        SELECT p7.inn, SUM(NVL(p7.summa, 0)) AS oplacheno
        FROM   postupleniya p7
        JOIN   kbk_spr k ON k.kbk = p7.kbk AND k.priznak_nalog = 'Y'
        WHERE  p7.period = p_period
        GROUP  BY p7.inn
    ),
    calc_final AS (
        SELECT COALESCE(nach.inn, opl.inn)  AS inn,
               NVL(nach.nachisleno, 0)      AS nachisleno,
               NVL(opl.oplacheno, 0)        AS oplacheno
        FROM   nach
        FULL   OUTER JOIN opl ON opl.inn = nach.inn
    )
    SELECT p_period,
           NVL(np.region_kod, TO_NUMBER(SUBSTR(c.inn, 1, 2))),
           c.inn,
           np.naim,
           c.nachisleno,
           c.oplacheno,
           c.nachisleno - c.oplacheno
    FROM   calc_final c
    LEFT   JOIN nalogoplatelshchiki np ON np.inn = c.inn
    WHERE  p_region IS NULL
       OR  NVL(np.region_kod, TO_NUMBER(SUBSTR(c.inn, 1, 2))) = p_region;

    p_rows := SQL%ROWCOUNT;
    COMMIT;
    p_etl_log(c_proc, v_params, 'OK', p_rows, NULL, v_started);

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;                                            -- не оставляем полусрез
        p_etl_log(c_proc, v_params, 'ERROR', NULL,
                  SQLERRM || CHR(10) || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, v_started);
        RAISE;                                               -- ошибку не глушим
END p_nedoimka_vygruzka;
/
SHOW ERRORS

-- ---------- пример запуска ----------
DECLARE
    v_rows NUMBER;
BEGIN
    p_nedoimka_vygruzka(p_period => '202406', p_rows => v_rows);
    DBMS_OUTPUT.PUT_LINE('202406, все регионы: записано строк ' || v_rows);

    p_nedoimka_vygruzka(p_period => '202405', p_region => 77, p_rows => v_rows);
    DBMS_OUTPUT.PUT_LINE('202405, регион 77: записано строк ' || v_rows);
END;
/

-- ошибка параметра попадает в лог и пробрасывается наверх
DECLARE
    v_rows NUMBER;
BEGIN
    p_nedoimka_vygruzka(p_period => '2024-06', p_rows => v_rows);
EXCEPTION
    WHEN OTHERS THEN DBMS_OUTPUT.PUT_LINE('Ожидаемая ошибка: ' || SQLERRM);
END;
/

SELECT period, COUNT(*) AS rows_cnt, SUM(nedoimka) AS nedoimka
FROM   nedoimka_vygruzka
GROUP  BY period
ORDER  BY period;

COLUMN params FORMAT A35
COLUMN msg    FORMAT A60 WORD_WRAPPED
SELECT log_id, status, params, rows_cnt, msg FROM etl_log ORDER BY log_id;
