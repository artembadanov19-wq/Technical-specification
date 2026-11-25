// Недоимка по налогоплательщику (сумма по налоговым КБК за все периоды).
// Источник для INDEX/ПОИСКПОЗ на листе «Формулы».
let
    Grouped   = Table.Group(fakt, {"inn", "region_kod", "region_name", "fed_okrug"}, {
                    {"nachisleno", each List.Sum([nachisleno]), type number},
                    {"oplacheno",  each List.Sum([oplacheno]),  type number},
                    {"nedoimka",   each List.Sum([nedoimka]),   type number}}),
    Rounded   = Table.TransformColumns(Grouped, {
                    {"nachisleno", each Number.Round(_, 2), type number},
                    {"oplacheno",  each Number.Round(_, 2), type number},
                    {"nedoimka",   each Number.Round(_, 2), type number}}),
    Sorted    = Table.Sort(Rounded, {{"nedoimka", Order.Descending}})
in
    Sorted
