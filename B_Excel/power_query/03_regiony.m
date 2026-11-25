// Справочник регионов: обрезка пробелов, код региона = 2 символа,
// названия В ВЕРХНЕМ РЕГИСТРЕ -> «Первая заглавная».
let
    Folder    = if Text.EndsWith(DataFolder, "\") or Text.EndsWith(DataFolder, "/") then DataFolder
                else DataFolder & (if Text.Contains(DataFolder, "/") then "/" else "\"),
    Source    = Csv.Document(File.Contents(Folder & "regiony.csv"),
                    [Delimiter = ";", Encoding = 65001, QuoteStyle = QuoteStyle.Csv]),
    Promoted  = Table.PromoteHeaders(Source, [PromoteAllScalars = true]),
    CleanHdr  = Table.TransformColumnNames(Promoted, each Text.Trim(Text.Replace(_, "#(FEFF)", ""))),
    Trimmed   = Table.TransformColumns(CleanHdr, {},
                    each if _ is text then Text.Trim(Text.Clean(_)) else _),
    Typed     = Table.TransformColumns(Trimmed, {
                    {"region_kod",  each Text.PadStart(_, 2, "0"), type text},
                    {"region_name", each
                        let
                            oneSpace = Text.Combine(List.Select(Text.Split(_, " "), each _ <> ""), " ")
                        in
                            if oneSpace = Text.Upper(oneSpace)
                            then Text.Upper(Text.Start(oneSpace, 1)) & Text.Lower(Text.Middle(oneSpace, 1))
                            else oneSpace,
                        type text},
                    {"fed_okrug",   Text.Upper, type text}
                }),
    Dedup     = Table.Distinct(Typed, {"region_kod"})
in
    Dedup
