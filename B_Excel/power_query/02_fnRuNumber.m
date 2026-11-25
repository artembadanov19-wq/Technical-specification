// Функция: «русское» число -> number.
// '1 234 567,89' -> 1234567.89 ; '' / null -> null
// Убираем обычные, неразрывные (00A0) и узкие (202F) пробелы-разряды,
// запятую меняем на точку и парсим в фиксированной культуре en-US —
// результат не зависит от региональных настроек Windows.
(txt as nullable text) as nullable number =>
let
    t         = if txt = null then "" else Text.Trim(txt),
    noSpaces  = Text.Remove(t, {" ", "#(00A0)", "#(202F)"}),
    result    = if noSpaces = "" then null
                else Number.FromText(Text.Replace(noSpaces, ",", "."), "en-US")
in
    result
