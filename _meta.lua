local _ = require("gettext")

-- One-line plugin-manager description, picked per UI language. Deliberately
-- NOT run through gettext: the plugin manager reads _meta.lua before the
-- plugin's own locale/*.po files are loaded.
local DESCRIPTIONS = {
    en = "Book Card is a new sleep screen for KOReader, heavily inspired by the idea and visual design of CrossPoint's sleep screen implementation.",
    hu = "A Book Card egy új alvóképernyő a KOReaderhez, amelyet nagyban ihletett a CrossPoint alvóképernyő-megvalósításának ötlete és vizuális megjelenése.",
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
    fullname = _("Book Card"),
    description = pickDescription(),
    version = "1.1.1",
}
