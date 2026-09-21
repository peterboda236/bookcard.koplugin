--[[
Book Card - user-configurable text/battery colors.

The card already follows KOReader's night mode / "Background" setting
(see card_view.lua's palette()), so "default" here means "follow that
theme", not a fixed hex. A role keeps following the theme until the user
picks a color for it in the Colors menu; "Reset to default" clears it
back to following the theme again. getColor() takes the caller's current
theme color as a fallback for that reason.

  title       book title
  author      author line
  series      series / #index line
  stat_value  the big numbers in the statistics column (and the title, which
              shares its size with them, uses its own "title" key above)
  stat_label  the small labels under each statistic
  bottom      the streak text and the reader-type text (bottom row)
  battery     the battery glyph + percentage

Colors are stored as "#RRGGBB" hex strings in G_reader_settings, same as
KOReader itself (see Blitbuffer.colorFromString) - any hex code the user can
look up works here too.

Loaded once by main.lua and handed to card_view.lua.

Exposes:
  getColor(key, fallback)  Blitbuffer color object: the user's custom color
                            for `key` if set, otherwise `fallback` (typically
                            pal.fg from card_view's current theme)
  getHex(key)               current custom "#RRGGBB" value, or nil if the
                             role is still following the theme
  setHex(key, hex)          validate + persist; returns true/false
  resetToDefault(key)       go back to following the theme
  isDefault(key)            true if the role is still following the theme
  buildMenu(on_change)      KOReader sub_item_table for the "Colors" menu;
                            on_change() is called after any color is changed
                            or reset, so the caller can refresh open popups
]]--

local Blitbuffer  = require("ffi/blitbuffer")
local ConfirmBox  = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local UIManager   = require("ui/uimanager")

-- Shared modules, passed in as one named table by main.lua (see there).
local deps = ...
local Locale, PluginUtil, Prefs = deps.Locale, deps.PluginUtil, deps.Prefs
local _ = Locale._

-- Load ColorWheelWidget from this plugin's own directory (not on
-- package.path, so require() won't find it) - via the shared loader.
local ColorWheelWidget = PluginUtil.load("widgets/colorwheelwidget.lua")

-- Order the "Colors" menu is built in; matches the Fonts menu's KEY_ORDER
-- (lib/fonts.lua) role for role.
local KEY_ORDER = {
    "title", "author", "series", "stat_value", "stat_label", "bottom", "battery",
}

local SETTINGS_PREFIX = "bookcard_color_"

local function normalizeHex(hex)
    if type(hex) ~= "string" then return nil end
    hex = hex:gsub("%s+", "")
    if hex == "" then return nil end
    if hex:sub(1, 1) ~= "#" then hex = "#" .. hex end
    hex = hex:upper()
    if hex:match("^#%x%x%x%x%x%x$") then return hex end
    return nil
end

-- Converts a "#RRGGBB" hex string to HSV (hue 0..360, saturation/value
-- 0..1), so the color wheel can open already pointing at whatever color
-- is currently set for `key` (or black, if the role is still following
-- the theme), instead of always resetting to red.
local function hexToHsv(hex)
    local n = normalizeHex(hex) or "#000000"
    local r = tonumber(n:sub(2, 3), 16) / 255
    local g = tonumber(n:sub(4, 5), 16) / 255
    local b = tonumber(n:sub(6, 7), 16) / 255
    local max, min = math.max(r, g, b), math.min(r, g, b)
    local delta = max - min
    local h = 0
    if delta > 0 then
        if max == r then
            h = 60 * (((g - b) / delta) % 6)
        elseif max == g then
            h = 60 * (((b - r) / delta) + 2)
        else
            h = 60 * (((r - g) / delta) + 4)
        end
    end
    if h < 0 then h = h + 360 end
    local s = (max == 0) and 0 or (delta / max)
    return h, s, max
end

local function readHex(key)
    return normalizeHex(Prefs.read(SETTINGS_PREFIX .. key, nil))
end

local function saveHex(key, hex)
    Prefs.save(SETTINGS_PREFIX .. key, hex)
end

-- Small cache of built Blitbuffer color objects, avoiding reparsing the hex
-- string and hitting G_reader_settings on every single card draw.
-- Invalidated whenever the relevant color changes (setHex/resetToDefault).
local _color_cache = {}

local function buildColor(hex)
    local ok, color = pcall(Blitbuffer.colorFromString, hex)
    if ok and color then return color end
    return nil
end

local M = {}

function M.getHex(key)
    return readHex(key)
end

function M.isDefault(key)
    return readHex(key) == nil
end

-- `fallback` is a ready Blitbuffer color (card_view.lua's pal.fg), used
-- as-is whenever `key` hasn't been customized.
function M.getColor(key, fallback)
    local hex = readHex(key)
    if not hex then return fallback end
    local cached = _color_cache[key]
    if cached and cached.hex == hex then
        return cached.color
    end
    local color = buildColor(hex) or fallback
    _color_cache[key] = { hex = hex, color = color }
    return color
end

function M.setHex(key, hex)
    local n = normalizeHex(hex)
    if not n then return false end
    saveHex(key, n)
    _color_cache[key] = nil
    return true
end

function M.resetToDefault(key)
    saveHex(key, nil)
    _color_cache[key] = nil
end

-- Menu ---------------------------------------------------------------

local function labelFor(key)
    local labels = {
        title      = _("Title color"),
        author     = _("Author color"),
        series     = _("Series color"),
        stat_value = _("Statistics value color"),
        stat_label = _("Statistics label color"),
        bottom     = _("Streak / reader type color"),
        battery    = _("Battery color"),
    }
    return labels[key] or key
end

-- Opens the color wheel for `key`, pre-set to its current color (or black,
-- if it is still following the theme). Applying it saves the resulting hex
-- straight away (same as "Save" in the hex input dialog) and refreshes the
-- menu/open popups the same way.
local function showColorWheel(key, touchmenu_instance, on_change)
    local h, s, v = hexToHsv(M.getHex(key))
    UIManager:show(ColorWheelWidget:new{
        title_text = labelFor(key),
        hue        = h,
        saturation = s,
        value      = v,
        cancel_text       = _("Cancel"),
        ok_text           = _("Apply"),
        brightness_format = _("Brightness: %d%%"),
        callback = function(hex)
            M.setHex(key, hex)
            if touchmenu_instance then touchmenu_instance:updateItems() end
            if on_change then on_change() end
        end,
    })
end

local function showHexInputDialog(key, touchmenu_instance, on_change)
    local dialog
    dialog = InputDialog:new{
        title   = labelFor(key),
        input   = M.getHex(key) or "",
        input_hint = "#RRGGBB",
        description = _("Enter a hex color code (e.g. #1E90FF), the way KOReader expects it. Leave empty to follow the card's usual background/theme color."),
        buttons = {
            {
                {
                    text = _("Pick with color wheel"),
                    callback = function()
                        UIManager:close(dialog)
                        showColorWheel(key, touchmenu_instance, on_change)
                    end,
                },
            },
            {
                {
                    text = _("Cancel"),
                    id   = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Default"),
                    callback = function()
                        M.resetToDefault(key)
                        UIManager:close(dialog)
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                        if on_change then on_change() end
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local text = dialog:getInputText()
                        if M.setHex(key, text) then
                            UIManager:close(dialog)
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                            if on_change then on_change() end
                        else
                            UIManager:show(InfoMessage:new{
                                text = _("Not a valid hex color code, e.g. #1E90FF."),
                            })
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

local function colorItem(key, on_change)
    return {
        text_func = function()
            return labelFor(key) .. ": " .. (M.getHex(key) or _("Default (follows theme)"))
        end,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            showHexInputDialog(key, touchmenu_instance, on_change)
        end,
    }
end

-- Returns the sub_item_table for a "Colors" menu entry. on_change (optional)
-- is invoked every time a color is changed or reset, so the caller can e.g.
-- refresh any currently open preview. The menu itself is always kept in
-- sync via the touchmenu_instance KOReader passes into every callback.
function M.buildMenu(on_change)
    local sub_item_table = {}
    for _, key in ipairs(KEY_ORDER) do
        table.insert(sub_item_table, colorItem(key, on_change))
    end
    table.insert(sub_item_table, {
        text = _("Reset all colors to default"),
        keep_menu_open = true,
        separator = true,
        callback = function(touchmenu_instance)
            UIManager:show(ConfirmBox:new{
                text = _("Reset all colors to follow the theme again?"),
                ok_text = _("Reset"),
                ok_callback = function()
                    for _, key in ipairs(KEY_ORDER) do
                        M.resetToDefault(key)
                    end
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                    if on_change then on_change() end
                end,
            })
        end,
    })
    return sub_item_table
end

return M
