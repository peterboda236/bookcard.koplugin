local _ = require("gettext")

-- One-line plugin-manager description, picked per UI language. Deliberately
-- NOT run through gettext: the plugin manager reads _meta.lua before the
-- plugin's own locale/*.po files are loaded.
local DESCRIPTIONS = {
    en = "Book card is a new sleep screen for KOReader, heavily inspired by the idea and visual design of CrossPoint's sleep screen implementation.",
    hu = "A Book card egy új alvóképernyő a KOReaderhez, amelyet nagyban ihletett a CrossPoint alvóképernyő-megvalósításának ötlete és vizuális megjelenése.",
    uk = "Book card — новий екран сну для KOReader, натхненний ідеєю та візуальним дизайном реалізації екрана сну CrossPoint.",
    es = "Book card es una nueva pantalla de suspensión para KOReader, inspirada en gran medida en la idea y el diseño visual de la implementación de pantalla de suspensión de CrossPoint.",
    de = "Book card ist ein neuer Ruhebildschirm für KOReader, stark inspiriert von der Idee und dem visuellen Design der Ruhebildschirm-Implementierung von CrossPoint.",
    fr = "Book card est un nouvel écran de veille pour KOReader, largement inspiré par l'idée et le design visuel de l'écran de veille de CrossPoint.",
    -- "pt" covers both pt_PT and pt_BR, since only the first two letters of the
    -- language code are matched below.
    pt = "O Book card é um novo ecrã de suspensão para o KOReader, fortemente inspirado na ideia e no design visual da implementação do ecrã de suspensão do CrossPoint.",
    zh = "Book card 是 KOReader 的全新休眠屏幕，其创意和视觉设计在很大程度上受到 CrossPoint 休眠屏幕实现的启发。",
}

local function pickDescription()
    local lang = "en"
    if G_reader_settings and G_reader_settings.readSetting then
        lang = G_reader_settings:readSetting("language") or "en"
    end
    local base = tostring(lang):match("^([a-z][a-z])") or "en"
    return DESCRIPTIONS[base] or DESCRIPTIONS.en
end

return {
    -- Keep `name`: some KOReader releases key the plugin-manager
    -- enable/disable toggle off what they find here.
    name = "bookcard",
    fullname = _("Book card"),
    description = pickDescription(),
    version = "1.5.7",
}
