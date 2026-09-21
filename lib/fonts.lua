--[[
Book Card - user-configurable fonts, for these text roles:

  title       book title
  author      author line
  series      series / #index line
  stat_value  the big numbers in the statistics column
  stat_label  the small labels under each statistic
  bottom      the streak text and the reader-type text (bottom row)
  battery     the battery percentage

Most sizes (title, author, series, stat_value, stat_label) are not fixed -
card_view.lua computes them from however much space is left on the screen,
so every card fits regardless of device/orientation. "default size" means
"let card_view.lua keep computing it" (getFace's `resolved_size` argument
below); only a user-set custom size switches a role to a fixed size.
bottom/battery instead have real fixed defaults (14/13, see DEFAULT_SIZE).

Default font names are NotoSans (Regular/Bold/Italic and friends) for
every role, rather than KOReader's generic "tfont"/"cfont" aliases, so
cards look consistent regardless of the device's system font.

Loaded once by main.lua and handed to card_view.lua.

Exposes:
  getFace(key, resolved_size)  ready-to-use Font face for TextWidget/
                                TextBoxWidget "face ="; `resolved_size` is
                                what card_view.lua would otherwise use for
                                this role (its own dynamic calculation, or
                                nil for bottom/battery) - only used when the
                                user hasn't set a custom size for `key`
  getName(key) / getSize(key)  current custom values (nil if unset -> default)
  getDefaultName(key)          the original in-code default font
  setName(key, name) / setSize(key, size)
                                validate + persist; return true/false
  resetToDefault(key)          go back to the original font AND to
                                card_view.lua's own sizing for this role
  buildMenu(on_change)         KOReader sub_item_table for the "Fonts" menu;
                                on_change() is called after any font is
                                changed or reset, so the caller can refresh
                                open popups
]]--

local ConfirmBox  = require("ui/widget/confirmbox")
local Font        = require("ui/font")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu        = require("ui/widget/menu")
local SpinWidget  = require("ui/widget/spinwidget")
local UIManager   = require("ui/uimanager")

-- Shared modules, passed in as one named table by main.lua (see there).
local deps = ...
local Locale, PluginUtil, Prefs = deps.Locale, deps.PluginUtil, deps.Prefs
local _ = Locale._

-- Order the "Fonts" menu is built in; matches the Colors menu's KEY_ORDER
-- (lib/colors.lua) role for role.
local KEY_ORDER = {
    "title", "author", "series", "stat_value", "stat_label", "bottom", "battery",
}

-- Defaults: NotoSans (regular/bold/italic and friends) for every role,
-- instead of KOReader's generic "tfont"/"cfont" aliases.
local DEFAULT_NAME = {
    title      = "NotoSans-Bold.ttf",
    author     = "NotoSans-Italic.ttf",
    series     = "NotoSans-Bold.ttf",
    stat_value = "NotoSans-Bold.ttf",
    stat_label = "NotoSans-Regular.ttf",
    bottom     = "NotoSans-Regular.ttf",
    battery    = "NotoSans-Bold.ttf",
}

-- Only bottom/battery had a fixed size before this menu existed; the rest
-- are sized dynamically by card_view.lua (see header comment above) and so
-- have no entry here - getFace() falls back to its `resolved_size` argument
-- for those instead. Used only as the spinner's starting point/"Default"
-- value in the menu for those two roles.
local DEFAULT_SIZE = {
    bottom  = 14,
    battery = 14,
}

-- Used only to seed the size spinner for the dynamically-sized roles with
-- a sensible starting number (their typical on-screen size) - the actual
-- default behavior for these roles is "whatever card_view.lua computes",
-- not this number; it is never itself persisted or applied unless the user
-- explicitly moves the spinner and taps "Set".
local SPINNER_START_SIZE = {
    title      = 22,
    author     = 13,
    series     = 13,
    stat_value = 22,
    stat_label = 13,
}

local SETTINGS_NAME_PREFIX = "bookcard_font_name_"
local SETTINGS_SIZE_PREFIX = "bookcard_font_size_"

local MIN_SIZE, MAX_SIZE = 6, 60

local function readSetting(key)
    return Prefs.read(key, nil)
end

local function saveSetting(key, value)
    Prefs.save(key, value)
end

local function normalizeName(name)
    if type(name) ~= "string" then return nil end
    name = name:gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then return nil end
    return name
end

local function normalizeSize(size)
    size = tonumber(size)
    if not size then return nil end
    size = math.floor(size + 0.5)
    if size < MIN_SIZE or size > MAX_SIZE then return nil end
    return size
end

local M = {}

function M.getDefaultName(key) return DEFAULT_NAME[key] end

function M.getName(key)
    return normalizeName(readSetting(SETTINGS_NAME_PREFIX .. key))
end

function M.getSize(key)
    return normalizeSize(readSetting(SETTINGS_SIZE_PREFIX .. key))
end

function M.setName(key, name)
    local n = normalizeName(name)
    if not n then return false end
    saveSetting(SETTINGS_NAME_PREFIX .. key, n)
    M._invalidate(key)
    return true
end

function M.setSize(key, size)
    local n = normalizeSize(size)
    if not n then return false end
    saveSetting(SETTINGS_SIZE_PREFIX .. key, n)
    M._invalidate(key)
    return true
end

function M.resetToDefault(key)
    saveSetting(SETTINGS_NAME_PREFIX .. key, nil)
    saveSetting(SETTINGS_SIZE_PREFIX .. key, nil)
    M._invalidate(key)
end

function M.isDefault(key)
    return M.getName(key) == nil and M.getSize(key) == nil
end

-- Small cache of built Font faces, avoiding re-hitting Freetype/
-- G_reader_settings on every single card draw. Invalidated whenever the
-- relevant font setting changes (setName/setSize/resetToDefault above).
local _face_cache = {}

function M._invalidate(key)
    _face_cache[key] = nil
end

-- Tries the requested font (file name or Font.fontmap key) at the given
-- size, then falls back to NotoSans-Regular, and finally to KOReader's own
-- default content font ("cfont") as a last resort. Never errors.
local function buildFace(font, size)
    local ok, face = pcall(Font.getFace, Font, font, size)
    if ok and face then return face end

    ok, face = pcall(Font.getFace, Font, "NotoSans-Regular.ttf", size)
    if ok and face then return face end

    return Font:getFace("cfont", size)
end

-- `resolved_size` is card_view.lua's own dynamically-computed size for this
-- role (or nil for bottom/battery, which fall back to DEFAULT_SIZE) - only
-- used when the user hasn't set a custom size for `key`.
function M.getFace(key, resolved_size)
    local name = M.getName(key) or DEFAULT_NAME[key]
    local size = M.getSize(key) or resolved_size or DEFAULT_SIZE[key] or 14
    size = math.max(6, math.floor(size))

    local cache_key = name .. "@" .. size
    local cached = _face_cache[key]
    if cached and cached.cache_key == cache_key then
        return cached.face
    end

    local face = buildFace(name, size)
    _face_cache[key] = { cache_key = cache_key, face = face }
    return face
end

-- Menu ---------------------------------------------------------------

-- Forward declaration: showFontPickerMenu (below) needs labelFor for its
-- title, but is defined before labelFor for readability (discovery/picker
-- helpers grouped together, ahead of the rest of the menu-building code).
local labelFor

-- Font-file discovery, so the menu can offer a pick-from-list option
-- instead of forcing the user to type an exact file name/alias.
local FONT_EXTENSIONS = { ttf = true, otf = true, ttc = true, otc = true }

-- The plugin lives at <koreader_root>/plugins/<name>.koplugin/, so two
-- levels up is KOReader's own bundled "fonts" directory.
local function koreaderFontsDir()
    return PluginUtil.dir .. "../../fonts/"
end

-- Scans KOReader's bundled fonts dir plus the user data dir's "fonts"
-- folder (where sideloaded/custom fonts usually live) for font files.
-- Never errors: if lfs or a directory isn't available, just returns
-- whatever was found up to that point (possibly nothing).
local function scanDirForFonts(lfs, dir, found, seen)
    -- lfs.dir() itself normally doesn't error even for a missing directory -
    -- the error only surfaces once the returned iterator is actually
    -- called - so the whole loop (not just the initial lfs.dir() call)
    -- has to run inside pcall.
    pcall(function()
        for entry in lfs.dir(dir) do
            local ext = entry:match("%.([%a]+)$")
            if ext and FONT_EXTENSIONS[ext:lower()] and not seen[entry] then
                seen[entry] = true
                table.insert(found, entry)
            end
        end
    end)
end

local function scanFontFiles()
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then ok_lfs, lfs = pcall(require, "lfs") end
    if not ok_lfs then return {} end

    local dirs = { koreaderFontsDir() }
    local ok_ds, DataStorage = pcall(require, "datastorage")
    if ok_ds and DataStorage.getDataDir then
        table.insert(dirs, DataStorage:getDataDir() .. "/fonts/")
    end

    local found, seen = {}, {}
    for _, dir in ipairs(dirs) do
        -- Skip directories that don't exist/aren't readable, so we never
        -- even attempt to iterate them.
        local ok_attr, attr = pcall(lfs.attributes, dir, "mode")
        if ok_attr and attr == "directory" then
            scanDirForFonts(lfs, dir, found, seen)
        end
    end
    table.sort(found, function(a, b) return a:lower() < b:lower() end)
    return found
end

-- Builds the list of selectable names for one role's picker menu: this
-- role's own default file first, then every font file found on disk -
-- de-duplicated, in that priority order. KOReader's internal font-alias
-- keys (Font.fontmap, e.g. "tfont", "cfont") are deliberately left out of
-- this list - they're only used as silent fallbacks in buildFace, not
-- meant to be picked directly, and would just clutter/confuse the top of
-- the list with cryptic short names.
local function getPickerEntries(key)
    local entries, seen = {}, {}

    local default_file = M.getDefaultName(key)
    table.insert(entries, default_file)
    seen[default_file] = true

    for _, file in ipairs(scanFontFiles()) do
        if not seen[file] then
            seen[file] = true
            table.insert(entries, file)
        end
    end

    return entries
end

-- Pick-from-list font chooser: shows every discoverable font file
-- (this role's default plus every font file found on disk) as a
-- checkable Menu, so the user usually never has to type a font name by
-- hand. The free-text InputDialog (showNameInputDialog below) is kept as
-- a separate "Custom" entry for names this scan can't find (e.g. unusual
-- install locations, or a KOReader font alias like "tfont"/"cfont").
local function showFontPickerMenu(key, touchmenu_instance, on_change)
    local entries = getPickerEntries(key)
    local item_table = {}
    for _, name in ipairs(entries) do
        table.insert(item_table, {
            text = name,
            checked_func = function()
                return (M.getName(key) or M.getDefaultName(key)) == name
            end,
        })
    end

    local picker
    picker = Menu:new{
        title = labelFor(key) .. ": " .. _("Choose a font"),
        item_table = item_table,
        single_line = true,
        is_popout = false,
        is_borderless = true,
        onMenuSelect = function(_, item)
            M.setName(key, item.text)
            UIManager:close(picker)
            if touchmenu_instance then touchmenu_instance:updateItems() end
            if on_change then on_change() end
        end,
    }
    UIManager:show(picker)
end

function labelFor(key)
    local labels = {
        title      = _("Title"),
        author     = _("Author"),
        series     = _("Series"),
        stat_value = _("Statistics values"),
        stat_label = _("Statistics labels"),
        bottom     = _("Streak / reader type"),
        battery    = _("Battery percentage"),
    }
    return labels[key] or key
end

local function showNameInputDialog(key, touchmenu_instance, on_change)
    local dialog
    dialog = InputDialog:new{
        title = labelFor(key) .. ": " .. _("Font name"),
        input = M.getName(key) or M.getDefaultName(key),
        input_hint = "NotoSans-Regular.ttf",
        description = _("Enter a bundled font file name (e.g. NotoSans-Bold.ttf) or a KOReader font alias (e.g. tfont, cfont). If it can't be found, this role falls back to its default font."),
        buttons = {
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
                        saveSetting(SETTINGS_NAME_PREFIX .. key, nil)
                        M._invalidate(key)
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
                        if M.setName(key, text) then
                            UIManager:close(dialog)
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                            if on_change then on_change() end
                        else
                            UIManager:show(InfoMessage:new{
                                text = _("Please enter a non-empty font name."),
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

local function showSizeSpinner(key, touchmenu_instance, on_change)
    local default_size = DEFAULT_SIZE[key] or SPINNER_START_SIZE[key] or 14
    UIManager:show(SpinWidget:new{
        title_text    = labelFor(key) .. ": " .. _("Font size"),
        value         = M.getSize(key) or default_size,
        value_min     = MIN_SIZE,
        value_max     = MAX_SIZE,
        value_step    = 1,
        value_hold_step = 4,
        default_value = default_size,
        ok_text       = _("Set"),
        callback      = function(spin)
            M.setSize(key, spin.value)
            if touchmenu_instance then touchmenu_instance:updateItems() end
            if on_change then on_change() end
        end,
    })
end

local function sizeText(key)
    local custom = M.getSize(key)
    if custom then return tostring(custom) end
    if DEFAULT_SIZE[key] then return tostring(DEFAULT_SIZE[key]) end
    return _("Auto")
end

local function roleSubItemTable(key, on_change)
    return {
        {
            text_func = function()
                return _("Font") .. ": " .. (M.getName(key) or M.getDefaultName(key))
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                showFontPickerMenu(key, touchmenu_instance, on_change)
            end,
        },
        {
            text = _("Custom font name (type manually)"),
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                showNameInputDialog(key, touchmenu_instance, on_change)
            end,
        },
        {
            text_func = function()
                return _("Font size") .. ": " .. sizeText(key)
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                showSizeSpinner(key, touchmenu_instance, on_change)
            end,
        },
        {
            text = _("Reset to default"),
            keep_menu_open = true,
            separator = true,
            callback = function(touchmenu_instance)
                M.resetToDefault(key)
                if touchmenu_instance then touchmenu_instance:updateItems() end
                if on_change then on_change() end
            end,
        },
    }
end

local function groupSubItemTable(keys, on_change)
    local sub_item_table = {}
    for _, key in ipairs(keys) do
        table.insert(sub_item_table, {
            text_func = function()
                local name = M.getName(key) or M.getDefaultName(key)
                return labelFor(key) .. ": " .. name .. " @ " .. sizeText(key)
            end,
            keep_menu_open = true,
            sub_item_table = roleSubItemTable(key, on_change),
        })
    end
    return sub_item_table
end

-- Returns the sub_item_table for a "Fonts" menu entry. on_change (optional)
-- is invoked every time a font is changed or reset, so the caller can e.g.
-- refresh any currently open preview. The menu itself is always kept in
-- sync via the touchmenu_instance KOReader passes into every callback.
function M.buildMenu(on_change)
    local sub_item_table = groupSubItemTable(KEY_ORDER, on_change)
    table.insert(sub_item_table, {
        text = _("Reset all fonts to default"),
        keep_menu_open = true,
        separator = true,
        callback = function(touchmenu_instance)
            UIManager:show(ConfirmBox:new{
                text = _("Reset all fonts to their default values?"),
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
