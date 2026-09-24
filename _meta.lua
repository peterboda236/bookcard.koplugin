local _ = require("gettext")

-- One-line plugin-manager description, picked per UI language. Deliberately
-- NOT run through gettext: the plugin manager reads _meta.lua before the
-- plugin's own locale/*.po files are loaded.
local DESCRIPTIONS = {
    en = "Book card is a new sleep screen for KOReader, heavily inspired by the idea and visual design of CrossPoint's sleep screen implementation.",
    hu = "A Book card egy új alvóképernyő a KOReaderhez, amelyet nagyban ihletett a CrossPoint alvóképernyő-megvalósításának ötlete és vizuális megjelenése.",
    uk = "Book card — новий екран сну для KOReader, натхненний ідеєю та візуальним дизайном реалізації екрана сну CrossPoint.",
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
    version = "1.5.4",
}
