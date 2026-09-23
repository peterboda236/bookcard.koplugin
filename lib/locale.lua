--[[
Book card - localisation and number/date/duration formatting.

Translations live in locale/<lang>.po and are looked up BEFORE KOReader's own
gettext, so the plugin can add strings without touching KOReader's catalogs.
The loader is intentionally tiny: flat msgid -> msgstr pairs (each possibly
wrapped over several quoted lines), no gettext plural forms - plurals are two
independent msgid entries (see N_).

Exposes:
  _(msg)                      translate
  N_(singular, plural, n)     translate with plural handling
  tpl(str, vars)              replace {name} placeholders
  formatNumber(n, decimals)   locale-aware number (HU: "1,2" / EN: "1.2")
  formatDuration(secs)        "12h 51 min" / "55 min" / "<1 min"
  shortDate(ts)               "Aug 30" (adds the year if not the current one)
]]--

local gettext = require("gettext")

local deps = ...
local PLUGIN_DIR = deps.PluginUtil.dir

local M = {}

local function unescapePO(s)
    return (s:gsub("\\n", "\n"):gsub("\\t", "\t"):gsub('\\"', '"'):gsub("\\\\", "\\"))
end

local function loadPOFile(path)
    local map = {}
    local f = io.open(path, "r")
    if not f then return map end

    local key, value = nil, nil
    local in_key, in_value = false, false

    local function commit()
        if key and value and key ~= "" and value ~= "" then
            map[key] = value
        end
        key, value, in_key, in_value = nil, nil, false, false
    end

    for raw in f:lines() do
        local line = raw:match("^%s*(.-)%s*$")
        local msgid  = line:match('^msgid%s+"(.*)"$')
        local msgstr = line:match('^msgstr%s+"(.*)"$')
        local cont   = line:match('^"(.*)"$')
        if msgid ~= nil then
            commit()
            key, in_key, in_value = unescapePO(msgid), true, false
        elseif msgstr ~= nil then
            value, in_value, in_key = unescapePO(msgstr), true, false
        elseif cont ~= nil then
            local piece = unescapePO(cont)
            if in_value then
                value = (value or "") .. piece
            elseif in_key then
                key = (key or "") .. piece
            end
        elseif line == "" or line:match("^#") then
            commit()
        end
    end
    commit()
    f:close()
    return map
end

local function currentLang()
    local lang = "en"
    if G_reader_settings and G_reader_settings.readSetting then
        lang = G_reader_settings:readSetting("language") or "en"
    end
    return lang
end

function M.langBase()
    local lang = currentLang()
    return lang:match("^([a-z]+)") or lang
end

local _map_cache = {}
local function getMap()
    local lang = currentLang()
    if _map_cache[lang] ~= nil then return _map_cache[lang] end
    local full = lang:gsub("-", "_")
    local base = M.langBase()
    local candidates = { full }
    if full ~= base then candidates[#candidates + 1] = base end
    local map = {}
    for i = 1, #candidates do
        map = loadPOFile(PLUGIN_DIR .. "locale/" .. candidates[i] .. ".po")
        if next(map) ~= nil then break end
    end
    _map_cache[lang] = map
    return map
end

local function _(msg)
    return getMap()[msg] or gettext(msg)
end
M._ = _

function M.N_(singular, plural, n)
    local map = getMap()
    local s, p = map[singular], map[plural]
    if s or p then
        if n == 1 then return s or p end
        return p or s
    end
    return gettext.ngettext(singular, plural, n)
end

function M.tpl(str, vars)
    return (str:gsub("{(%w+)}", function(k)
        local v = vars[k]
        if v == nil then return "{" .. k .. "}" end
        return tostring(v)
    end))
end

function M.formatNumber(n, decimals)
    if n == nil then return "" end
    decimals = decimals or 0
    local s = string.format("%." .. decimals .. "f", n)
    if M.langBase() == "hu" or M.langBase() == "de" or M.langBase() == "fr"
            or M.langBase() == "pt" or M.langBase() == "uk" or M.langBase() == "es" then
        s = s:gsub("%.", ",")
    end
    return s
end

-- Same rounding as KOReader's datetime.secondsToClock(..., without_seconds):
-- whole hours, minutes rounded, and 60 minutes carried into the hour.
function M.formatDuration(secs)
    if not secs or secs ~= secs then return nil end
    if secs < 0 then secs = 0 end
    local hours = math.floor(secs / 3600)
    local mins = math.floor((secs % 3600) / 60 + 0.5)
    if mins == 60 then hours, mins = hours + 1, 0 end
    if hours == 0 and mins == 0 then
        if secs > 0 then return _("<1 min") end
        return string.format(_("%d min"), 0)
    end
    if hours == 0 then
        return string.format(_("%d min"), mins)
    end
    return string.format(_("%dh %d min"), hours, mins)
end

local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun",
                 "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

function M.shortDate(ts)
    if not ts or ts <= 0 then return nil end
    local t = os.date("*t", ts)
    local vars = { month = _(MONTHS[t.month]), day = t.day, year = t.year }
    if t.year ~= os.date("*t").year then
        return M.tpl(_("{month} {day}, {year}"), vars)
    end
    return M.tpl(_("{month} {day}"), vars)
end

return M
