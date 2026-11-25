// Справочник КБК с признаком налоговый (Y) / неналоговый (N).
let
    Folder    = if Text.EndsWith(DataFolder, "\") or Text.EndsWith(DataFolder, "/") then DataFolder
                else DataFolder & (if Text.Contains(DataFolder, "/") then "/" else "\"),
    Source    = Csv.Document(File.Contents(Folder & "kbk_ref.csv"),
                    [Delimiter = ";", Encoding = 65001, QuoteStyle = QuoteStyle.Csv]),
    Promoted  = Table.PromoteHeaders(Source, [PromoteAllScalars = true]),
    CleanHdr  = Table.TransformColumnNames(Promoted, each Text.Trim(Text.Replace(_, "#(FEFF)", ""))),
    Trimmed   = Table.TransformColumns(CleanHdr, {},
                    each if _ is text then Text.Trim(Text.Clean(_)) else _),
    Typed     = Table.TransformColumns(Trimmed, {{"priznak_nalog", Text.Upper, type text}}),
    Dedup     = Table.Distinct(Typed, {"kbk"})
in
    Dedup
