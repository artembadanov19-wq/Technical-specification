// Начисления: очистка «грязной» выгрузки (nachisleniya_raw.csv).
//  * разделитель «;», UTF-8 (с BOM)
//  * все поля читаются как текст (никакого автоопределения типов —
//    иначе ИНН/КБК превратятся в числа, а '1 234,56' — в ошибку)
//  * лишние пробелы (в т.ч. хвостовые в КБК) — Text.Trim
//  * суммы: запятая-десятичная и пробелы-разряды — fnRuNumber, пустые = 0
//  * дубли: одна и та же запись (id) выгружена дважды, иногда в другом
//    формате суммы ('976769,45' и '976 769,45') — поэтому дедуп по id
//    ПОСЛЕ нормализации, а не по сырому тексту строки
//  * код региона = первые 2 знака ИНН + справочники регионов и КБК
let
    Folder    = if Text.EndsWith(DataFolder, "\") or Text.EndsWith(DataFolder, "/") then DataFolder
                else DataFolder & (if Text.Contains(DataFolder, "/") then "/" else "\"),
    Source    = Csv.Document(File.Contents(Folder & "nachisleniya_raw.csv"),
                    [Delimiter = ";", Encoding = 65001, QuoteStyle = QuoteStyle.Csv]),
    Promoted  = Table.PromoteHeaders(Source, [PromoteAllScalars = true]),
    CleanHdr  = Table.TransformColumnNames(Promoted, each Text.Trim(Text.Replace(_, "#(FEFF)", ""))),
    Trimmed   = Table.TransformColumns(CleanHdr, {},
                    each if _ is text then Text.Trim(Text.Clean(_)) else _),
    Renamed   = Table.RenameColumns(Trimmed, {{"summa_nachisleno", "summa"}, {"data_operacii", "data"}}),
    Typed     = Table.TransformColumns(Renamed, {
                    {"id",    each Int64.From(_),          Int64.Type},
                    {"summa", fnRuNumber,                  type nullable number},
                    {"data",  each Date.FromText(_, "ru-RU"), type date}
                }),
    EmptyTo0  = Table.ReplaceValue(Typed, null, 0, Replacer.ReplaceValue, {"summa"}),
    Dedup     = Table.Distinct(EmptyTo0, {"id"}),
    AddRegion = Table.AddColumn(Dedup, "region_kod", each Text.Start([inn], 2), type text),
    JoinReg   = Table.NestedJoin(AddRegion, {"region_kod"}, regiony, {"region_kod"}, "r", JoinKind.LeftOuter),
    ExpReg    = Table.ExpandTableColumn(JoinReg, "r", {"region_name", "fed_okrug"}),
    JoinKbk   = Table.NestedJoin(ExpReg, {"kbk"}, kbk, {"kbk"}, "k", JoinKind.LeftOuter),
    ExpKbk    = Table.ExpandTableColumn(JoinKbk, "k", {"kbk_naim", "priznak_nalog"}),
    Result    = Table.SelectColumns(ExpKbk, {"id", "inn", "kbk", "period", "summa", "data",
                    "region_kod", "region_name", "fed_okrug", "kbk_naim", "priznak_nalog"}),
    Sorted    = Table.Sort(Result, {{"id", Order.Ascending}})
in
    Sorted
