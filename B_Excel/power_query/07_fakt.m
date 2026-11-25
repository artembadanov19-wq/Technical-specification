// Факт для сводной: только налоговые КБК, гранулярность ИНН × КБК × период.
// Недоимка = начислено − оплачено.
//  * агрегируем начисления и поступления ПО ОТДЕЛЬНОСТИ, потом соединяем
//    (прямое соединение строк размножило бы суммы — см. SQL A2)
//  * FULL OUTER: начисления без поступлений сохраняются (оплачено = 0)
let
    NachTax   = Table.SelectRows(nach_clean, each [priznak_nalog] = "Y"),
    PostTax   = Table.SelectRows(post_clean, each [priznak_nalog] = "Y"),
    NachAgg   = Table.Group(NachTax, {"inn", "kbk", "period"},
                    {{"nachisleno", each List.Sum([summa]), type number}}),
    PostAgg   = Table.Group(PostTax, {"inn", "kbk", "period"},
                    {{"oplacheno", each List.Sum([summa]), type number}}),
    PostKeys  = Table.RenameColumns(PostAgg, {{"inn", "p_inn"}, {"kbk", "p_kbk"}, {"period", "p_period"}}),
    Joined    = Table.Join(NachAgg, {"inn", "kbk", "period"},
                           PostKeys, {"p_inn", "p_kbk", "p_period"}, JoinKind.FullOuter),
    KeyInn    = Table.AddColumn(Joined, "inn_",    each if [inn]    <> null then [inn]    else [p_inn],    type text),
    KeyKbk    = Table.AddColumn(KeyInn, "kbk_",    each if [kbk]    <> null then [kbk]    else [p_kbk],    type text),
    KeyPer    = Table.AddColumn(KeyKbk, "period_", each if [period] <> null then [period] else [p_period], type text),
    DropOld   = Table.RemoveColumns(KeyPer, {"inn", "kbk", "period", "p_inn", "p_kbk", "p_period"}),
    Keys      = Table.RenameColumns(DropOld, {{"inn_", "inn"}, {"kbk_", "kbk"}, {"period_", "period"}}),
    NullTo0   = Table.ReplaceValue(Keys, null, 0, Replacer.ReplaceValue, {"nachisleno", "oplacheno"}),
    AddNed    = Table.AddColumn(NullTo0, "nedoimka", each [nachisleno] - [oplacheno], type number),
    Rounded   = Table.TransformColumns(AddNed, {
                    {"nachisleno", each Number.Round(_, 2), type number},
                    {"oplacheno",  each Number.Round(_, 2), type number},
                    {"nedoimka",   each Number.Round(_, 2), type number}}),
    AddRegion = Table.AddColumn(Rounded, "region_kod", each Text.Start([inn], 2), type text),
    JoinReg   = Table.NestedJoin(AddRegion, {"region_kod"}, regiony, {"region_kod"}, "r", JoinKind.LeftOuter),
    ExpReg    = Table.ExpandTableColumn(JoinReg, "r", {"region_name", "fed_okrug"}),
    JoinKbk   = Table.NestedJoin(ExpReg, {"kbk"}, kbk, {"kbk"}, "k", JoinKind.LeftOuter),
    ExpKbk    = Table.ExpandTableColumn(JoinKbk, "k", {"kbk_naim"}),
    Result    = Table.SelectColumns(ExpKbk, {"inn", "region_kod", "region_name", "fed_okrug",
                    "kbk", "kbk_naim", "period", "nachisleno", "oplacheno", "nedoimka"}),
    Sorted    = Table.Sort(Result, {{"inn", Order.Ascending}, {"kbk", Order.Ascending}, {"period", Order.Ascending}})
in
    Sorted
