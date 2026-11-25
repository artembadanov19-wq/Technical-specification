# build A7-2024
"""
Блок C. Python — расчёт недоимки по «грязным» CSV-выгрузкам.

  D1. Загрузка и очистка (русские числа, дубли, пустые суммы = 0)
  D2. Недоимка по налогоплательщикам (только налоговые КБК) + ТОП-5 регионов
  D3. Аномалии: переплата (оплачено > начислено)
  Бонус: контроль качества данных

Запуск:
    python nedoimka.py                 # CSV ищутся в ../data или рядом со скриптом
    python nedoimka.py --data PATH     # явный путь к папке с CSV
    python nedoimka.py --out result.xlsx   # дополнительно сохранить результаты

Допущения (подробно — в D_Keysy/otvety_i_dopushcheniya.md):
  * Недоимка считается нарастающим итогом за все периоды выгрузки (202401–202406).
  * Недоимка по налогоплательщику = сумма начислений − сумма поступлений по всем
    налоговым КБК (сальдирование внутри ИНН, логика ЕНС).
  * Дубль = повтор записи с тем же id (после нормализации все такие строки
    совпадают по содержимому — это проверяется в контроле качества).
  * «Налоговый КБК» = priznak_nalog = 'Y' в справочнике kbk_ref.csv.
  * Код региона = первые 2 знака ИНН.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

import pandas as pd

pd.set_option("display.width", 200)
pd.set_option("display.max_columns", 20)
pd.set_option("display.float_format", lambda v: f"{v:,.2f}".replace(",", " "))

SEP = ";"
ENC = "utf-8-sig"          # в файлах есть BOM


# --------------------------------------------------------------------------- #
# Вспомогательные функции
# --------------------------------------------------------------------------- #
def find_data_dir(cli_path: str | None) -> Path:
    here = Path(__file__).resolve().parent
    candidates = [Path(cli_path)] if cli_path else [here / ".." / "data", here / "data", here]
    for c in candidates:
        if (c / "nachisleniya_raw.csv").exists():
            return c.resolve()
    sys.exit(f"Не найдены CSV. Проверено: {', '.join(map(str, candidates))}")


def read_raw(path: Path) -> pd.DataFrame:
    """Читаем всё как текст: типы назначаем сами, чтобы pandas не «угадывал»
    (ИНН/КБК с ведущими нулями, '1 234,56' и т.п.)."""
    return pd.read_csv(path, sep=SEP, encoding=ENC, dtype=str, keep_default_na=False)


_SPACES = re.compile(r"[\s  ]")   # обычные, неразрывные и узкие пробелы


def parse_ru_number(s: pd.Series) -> pd.Series:
    """'1 234 567,89' -> 1234567.89 ; '' -> NaN ; мусор -> NaN (ловим в QC)."""
    cleaned = s.str.replace(_SPACES, "", regex=True).str.replace(",", ".", regex=False)
    return pd.to_numeric(cleaned.replace("", pd.NA), errors="coerce")


def normalize_region_name(name: str) -> str:
    """Убираем лишние пробелы; ВЕРХНИЙ РЕГИСТР приводим к «Первая заглавная»."""
    name = " ".join(name.split())
    if name.isupper():
        name = name[:1].upper() + name[1:].lower()
    return name


def fmt(v: float) -> str:
    return f"{v:,.2f}".replace(",", " ")


def section(title: str) -> None:
    print("\n" + "=" * 80 + f"\n{title}\n" + "=" * 80)


# --------------------------------------------------------------------------- #
# D1. Загрузка и очистка
# --------------------------------------------------------------------------- #
def clean_operations(raw: pd.DataFrame, sum_col: str, date_col: str, qc: list) -> pd.DataFrame:
    """Общая очистка для начислений и поступлений."""
    name = sum_col.replace("summa_", "")
    df = raw.copy()

    # 1) лишние пробелы во всех текстовых полях (КБК приходят с хвостовыми пробелами)
    ws_kbk = int((df["kbk"] != df["kbk"].str.strip()).sum())
    for c in df.columns:
        df[c] = df[c].str.strip()

    # 2) суммы: «русские» числа -> float
    df["summa_raw"] = df[sum_col]
    df["summa"] = parse_ru_number(df[sum_col])
    empty = int((df["summa_raw"] == "").sum())
    bad = int((df["summa"].isna() & (df["summa_raw"] != "")).sum())

    # 3) типы
    df["id"] = pd.to_numeric(df["id"], errors="coerce").astype("Int64")
    df["data"] = pd.to_datetime(df[date_col], format="%d.%m.%Y", errors="coerce")
    bad_dates = int(df["data"].isna().sum())

    # 4) дубли: одинаковый id. Проверяем, что после нормализации дубли идентичны —
    #    иначе это не дубль, а конфликт версий, и молча удалять нельзя.
    key_cols = ["id", "inn", "kbk", "period", "summa", "data"]
    dup_by_id = int(df.duplicated("id").sum())
    dup_full = int(df.duplicated(key_cols).sum())
    raw_dup_full = int(raw.drop(columns="id").duplicated().sum())  # «наивный» подсчёт по сырым строкам
    if dup_by_id != dup_full:
        conflicts = df[df.duplicated("id", keep=False)].sort_values("id")
        print(f"ВНИМАНИЕ: {name}: есть id с разным содержимым:\n{conflicts}")
    df = df.drop_duplicates("id", keep="first")

    # 5) пустые суммы трактуем как 0 (по условию задачи)
    df["summa"] = df["summa"].fillna(0.0)

    qc.append({
        "набор": name,
        "строк в файле": len(raw),
        "дублей по id": dup_by_id,
        "из них полных (после нормализации)": dup_full,
        "дублей по «сырому» тексту": raw_dup_full,
        "строк после очистки": len(df),
        "КБК с лишними пробелами": ws_kbk,
        "пустых сумм (→0)": empty,
        "нечисловых сумм": bad,
        "нулевых сумм (после →0)": int((df["summa"] == 0).sum()),
        "отрицательных сумм": int((df["summa"] < 0).sum()),
        "битых дат": bad_dates,
        "ИНН не 10 цифр": int((~df["inn"].str.fullmatch(r"\d{10}")).sum()),
        "period не YYYYMM": int((~df["period"].str.fullmatch(r"20\d{2}(0[1-9]|1[0-2])")).sum()),
        "period ≠ месяц даты": int((df["period"] != df["data"].dt.strftime("%Y%m")).sum()),
    })
    return df[["id", "inn", "kbk", "period", "summa", "data"]]


def load_all(data_dir: Path):
    qc: list[dict] = []
    nach = clean_operations(read_raw(data_dir / "nachisleniya_raw.csv"),
                            "summa_nachisleno", "data_operacii", qc)
    post = clean_operations(read_raw(data_dir / "postupleniya_raw.csv"),
                            "summa_oplacheno", "data_platezha", qc)

    reg = read_raw(data_dir / "regiony.csv")
    reg = reg.apply(lambda c: c.str.strip())
    reg["region_kod"] = reg["region_kod"].str.zfill(2)
    reg["region_name"] = reg["region_name"].map(normalize_region_name)

    kbk = read_raw(data_dir / "kbk_ref.csv").apply(lambda c: c.str.strip())
    kbk["priznak_nalog"] = kbk["priznak_nalog"].str.upper()
    return nach, post, reg, kbk, qc


# --------------------------------------------------------------------------- #
# D2. Расчёт недоимки
# --------------------------------------------------------------------------- #
def calc(nach, post, reg, kbk):
    tax_kbk = set(kbk.loc[kbk["priznak_nalog"] == "Y", "kbk"])

    keys = ["inn", "kbk", "period"]
    n_agg = (nach[nach["kbk"].isin(tax_kbk)]
             .groupby(keys, as_index=False)["summa"].sum()
             .rename(columns={"summa": "nachisleno"}))
    p_agg = (post[post["kbk"].isin(tax_kbk)]
             .groupby(keys, as_index=False)["summa"].sum()
             .rename(columns={"summa": "oplacheno"}))

    # Сначала агрегируем, потом соединяем — иначе декартово «размножение» строк.
    # FULL OUTER: есть начисления без поступлений (и теоретически наоборот).
    fakt = n_agg.merge(p_agg, on=keys, how="outer").fillna({"nachisleno": 0.0, "oplacheno": 0.0})
    fakt["nedoimka"] = fakt["nachisleno"] - fakt["oplacheno"]
    fakt["region_kod"] = fakt["inn"].str[:2]
    fakt = fakt.merge(reg, on="region_kod", how="left")

    # Итог по налогоплательщику
    df_result = (fakt.groupby(["inn", "region_kod", "region_name", "fed_okrug"], as_index=False, dropna=False)
                 [["nachisleno", "oplacheno", "nedoimka"]].sum()
                 .sort_values("nedoimka", ascending=False, ignore_index=True))

    top_regions = (df_result.groupby(["region_kod", "region_name", "fed_okrug"], as_index=False)
                   [["nachisleno", "oplacheno", "nedoimka"]].sum()
                   .sort_values("nedoimka", ascending=False, ignore_index=True))
    top_regions.insert(0, "место", top_regions["nedoimka"].rank(method="min", ascending=False).astype(int))
    return fakt, df_result, top_regions


# --------------------------------------------------------------------------- #
# Main
# --------------------------------------------------------------------------- #
def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", help="папка с CSV")
    ap.add_argument("--out", help="сохранить результаты в .xlsx")
    args = ap.parse_args()

    data_dir = find_data_dir(args.data)
    print(f"Папка с данными: {data_dir}")

    # ---------------- D1 ----------------
    nach, post, reg, kbk, qc = load_all(data_dir)
    section("D1. Загрузка и очистка")
    print(f"Начисления: {len(nach)} строк, сумма {fmt(nach['summa'].sum())}")
    print(f"Поступления: {len(post)} строк, сумма {fmt(post['summa'].sum())}")
    print("\nСправочник регионов после нормализации:")
    print(reg.to_string(index=False))

    # ---------------- D2 ----------------
    fakt, df_result, top_regions = calc(nach, post, reg, kbk)
    section("D2. Недоимка по налогоплательщикам (налоговые КБК, 202401–202406)")
    print(f"Налогоплательщиков: {len(df_result)}; "
          f"начислено {fmt(df_result['nachisleno'].sum())}, "
          f"оплачено {fmt(df_result['oplacheno'].sum())}, "
          f"недоимка {fmt(df_result['nedoimka'].sum())}")
    print("\nТОП-10 налогоплательщиков по недоимке:")
    print(df_result.head(10).to_string(index=False))
    print("\nТОП-5 регионов по суммарной недоимке:")
    print(top_regions.head(5).to_string(index=False))

    # ---------------- D3 ----------------
    section("D3. Аномалии: переплата (оплачено > начислено), уровень ИНН")
    over = df_result[df_result["oplacheno"] > df_result["nachisleno"]].copy()
    over["pereplata"] = over["oplacheno"] - over["nachisleno"]
    over = over.sort_values("pereplata", ascending=False)
    if over.empty:
        print("Налогоплательщиков с переплатой на уровне ИНН нет.")
    else:
        print(f"Найдено: {len(over)}, сумма переплаты {fmt(over['pereplata'].sum())}")
        print(over[["inn", "region_name", "nachisleno", "oplacheno", "pereplata"]].to_string(index=False))

    # Дополнительно: переплата в разрезе ИНН+КБК+период — она «прячется» внутри
    # сальдо ИНН и на уровне ИНН не видна.
    over_det = fakt[fakt["oplacheno"] > fakt["nachisleno"]]
    print(f"\nДля справки: строк ИНН+КБК+период с переплатой: {len(over_det)} "
          f"на сумму {fmt((over_det['oplacheno'] - over_det['nachisleno']).sum())} "
          f"(у {over_det['inn'].nunique()} ИНН).")

    # ---------------- Бонус: QC ----------------
    section("Бонус. Контроль качества данных")
    print(pd.DataFrame(qc).set_index("набор").T.to_string())
    tax_kbk = set(kbk.loc[kbk["priznak_nalog"] == "Y", "kbk"])
    unknown_kbk = (set(nach["kbk"]) | set(post["kbk"])) - set(kbk["kbk"])
    unknown_reg = set(fakt["region_kod"]) - set(reg["region_kod"])
    keys_n = set(map(tuple, nach[["inn", "kbk", "period"]].values))
    keys_p = set(map(tuple, post[["inn", "kbk", "period"]].values))
    print(f"\nКБК, которых нет в справочнике: {sorted(unknown_kbk) or 'нет'}")
    print(f"Регионы ИНН, которых нет в справочнике: {sorted(unknown_reg) or 'нет'}")
    print(f"Налоговых КБК в справочнике: {len(tax_kbk)} из {len(kbk)}")
    print(f"ИНН с начислениями, но без единого поступления: "
          f"{len(set(nach['inn']) - set(post['inn']))}")
    print(f"Поступления без начисления (ИНН+КБК+период): {len(keys_p - keys_n)}")
    print(f"Начисления без поступления (ИНН+КБК+период): {len(keys_n - keys_p)}")
    print(f"Строк поступлений по периодам: {post.groupby('period').size().to_dict()}")

    if args.out:
        with pd.ExcelWriter(args.out) as xw:
            df_result.to_excel(xw, sheet_name="df_result", index=False)
            top_regions.to_excel(xw, sheet_name="top_regions", index=False)
            over.to_excel(xw, sheet_name="pereplata", index=False)
            fakt.to_excel(xw, sheet_name="fakt", index=False)
        print(f"\nРезультаты сохранены: {args.out}")


if __name__ == "__main__":
    main()
