--[[
Book card - user-configurable fonts, for these text roles:

  title       book title
  author      author line
  series      series / #index line
  quote       the random highlighted quote (Card elements > Highlighted quote)
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

local CheckButton     = require("ui/widget/checkbutton")
local ConfirmBox      = require("ui/widget/confirmbox")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InfoMessage     = require("ui/widget/infomessage")
local InputContainer  = require("ui/widget/container/inputcontainer")
local InputDialog     = require("ui/widget/inputdialog")
local LeftContainer   = require("ui/widget/container/leftcontainer")
local Screen          = require("device").screen
local Size            = require("ui/size")
local SortWidget      = require("ui/widget/sortwidget")
local SpinWidget      = require("ui/widget/spinwidget")
local UIManager       = require("ui/uimanager")
local VerticalSpan    = require("ui/widget/verticalspan")
local gettext         = require("gettext")
local C_              = gettext.pgettext
local Tmpl            = require("ffi/util").template

-- Shared modules, passed in as one named table by main.lua (see there).
local deps = ...
local Locale, Prefs = deps.Locale, deps.Prefs
local _ = Locale._

-- Order the "Fonts" menu is built in; matches the Colors menu's KEY_ORDER
-- (lib/colors.lua) role for role.
local KEY_ORDER = {
    "title", "author", "series", "quote", "stat_value", "stat_label", "bottom", "battery",
}

-- Defaults: NotoSans (regular/bold/italic and friends) for every role,
-- instead of KOReader's generic "tfont"/"cfont" aliases.
local DEFAULT_NAME = {
    title      = "NotoSans-Bold.ttf",
    author     = "NotoSans-Italic.ttf",
    series     = "NotoSans-Bold.ttf",
    quote      = "NotoSans-Italic.ttf",
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
    quote      = 13,
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
--
-- Delegates to KOReader's own "fontlist" module instead of scanning
-- directories by hand: fontlist already knows every path KOReader itself
-- treats as a font source (its bundle, the platform's external font dir,
-- and any extra folders the user has added in KOReader's own font
-- settings), so this sees exactly what KOReader/other plugins (e.g.
-- bookshelf) see -- no separate, narrower directory list to keep in sync.
local function scanFontFiles()
    local ok_fl, FontList = pcall(require, "fontlist")
    if not ok_fl or not FontList then return {} end
    local ok_list, list = pcall(FontList.getFontList, FontList)
    if not ok_list or not list then return {} end
    return list
end

-- Last path component of a font entry (the entries KOReader's fontlist
-- returns may be full paths; this plugin's own defaults are bare file
-- names).
local function baseName(path)
    return (tostring(path):match("([^/\\]+)$")) or tostring(path)
end

-- Splits a file name into its extension-less "stem" and its extension
-- (lowercased, no dot). Used to recognize that e.g. "NotoSans-Regular.ttf"
-- and "NotoSans-Regular.woff2" are the *same* font shipped in different
-- formats, not two different fonts.
local function splitExt(name)
    local stem, ext = name:match("^(.*)%.([^.]+)$")
    if not stem then return name, "" end
    return stem, ext:lower()
end

-- What to actually show the user for a stored name/path: just the font's
-- own file-name stem, no folder path and no extension (e.g. a stored value
-- of "/mnt/onboard/fonts/NotoSans-Bold.ttf" displays as "NotoSans-Bold").
-- The real value (with path/extension, whatever buildFace/persist needs)
-- is never changed by this - it's a display-only helper.
local function displayStem(name)
    return (splitExt(baseName(name)))
end

-- Preference order when the same font stem is found in more than one
-- format: pick the single "best" one to show/use, instead of listing every
-- format as a separate entry. Anything not listed here sorts after woff2.
local EXT_RANK = { ttf = 1, ttc = 2, otf = 3, woff2 = 4, woff = 5 }
local function extRank(ext)
    return EXT_RANK[ext] or 99
end

-- Builds the list of selectable names for one role's picker menu: this
-- role's own default file first, then every font file found on disk -
-- de-duplicated BY FONT STEM (file name without extension, case-
-- insensitive), so the same font shipped as e.g. .ttf/.otf/.woff/.woff2,
-- or living in several folders (bundle, external fonts dir, user-added
-- folders...), shows up only once - preferring .ttf, then .ttc, .otf,
-- .woff2, .woff (EXT_RANK above), then whatever's left. KOReader's
-- internal font-alias keys (Font.fontmap, e.g. "tfont", "cfont") are
-- deliberately left out of this list - they're only used as silent
-- fallbacks in buildFace, not meant to be picked directly.
--
-- Returns a list of { name = <value to persist>, label = <shown in menu> }.
local function getPickerEntries(key)
    local entries, seen = {}, {}

    local default_file = M.getDefaultName(key)
    table.insert(entries, { name = default_file, label = displayStem(default_file) })
    seen[displayStem(default_file):lower()] = true

    -- best[stem] = { name = file, label = <display stem>, rank = extRank(ext) }
    local best = {}
    for _, file in ipairs(scanFontFiles()) do
        if type(file) == "string" and file ~= "" then
            local base = baseName(file)
            local stem_disp, ext = splitExt(base)
            local stem_key = stem_disp:lower()
            if not seen[stem_key] then
                local rank = extRank(ext)
                local current = best[stem_key]
                if not current or rank < current.rank then
                    best[stem_key] = { name = file, label = stem_disp, rank = rank }
                end
            end
        end
    end

    local found = {}
    for _, e in pairs(best) do
        table.insert(found, e)
    end
    table.sort(found, function(a, b)
        local la, lb = a.label:lower(), b.label:lower()
        if la == lb then return a.label < b.label end
        return la < lb
    end)
    for _, e in ipairs(found) do
        table.insert(entries, { name = e.name, label = e.label })
    end

    return entries
end

-- Pick-from-list font chooser ------------------------------------------
--
-- Shows every discoverable font file (this role's default plus every font
-- file found on disk) as a full-screen paged list, single choice (radio
-- buttons), every font's name drawn in that font's own typeface. Tapping a
-- row selects that font and closes the list. A thin subclass of KOReader's
-- own SortWidget (title bar, page navigation footer, close button) with
-- reordering switched off and our own row widget.
--
-- The free-text InputDialog (showNameInputDialog below) is kept as a
-- separate "Custom" entry for names this scan can't find (e.g. unusual
-- install locations, or a KOReader font alias like "tfont"/"cfont").

-- Size the font names are drawn at: KOReader's own list-item size
-- ("smallinfofont"), i.e. the same size the plain font list used before.
local function sampleSizeDefault()
    local sizemap = Font.sizemap
    return (sizemap and sizemap.smallinfofont) or 22
end

-- Sample face for one picker row. Never errors: a font file that can't be
-- loaded simply shows its name in KOReader's default UI font.
local function sampleFace(font_name, size)
    local ok, face = pcall(Font.getFace, Font, font_name, size)
    if ok and face then return face end
    return Font:getFace("smallinfofont")
end

-- One row: KOReader's own radio button (ui/widget/checkbutton in "radio"
-- mode: the standard "◉ " / "◯ " mark on the left, then the label) - the
-- same widget KOReader's radio-button dialogs are built from - with the
-- font's name drawn in that font.
local FontPickerItem = InputContainer:extend{
    item        = nil,
    width       = nil,
    height      = nil,
    face        = nil,
    show_parent = nil,
}

function FontPickerItem:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }

    local button = CheckButton:new{
        text        = self.item.text,
        radio       = true,
        checked     = (self.item.checked_func and self.item.checked_func()) and true or false,
        face        = self.face or Font:getFace("smallinfofont"),
        width       = self.width - Size.padding.default,
        single_line = true,
        bordersize  = 0,
        margin      = 0,
        padding     = 0,
        show_parent = self.show_parent or self,
        parent      = self.show_parent or self,
        callback    = function()
            if self.item.callback then
                self.item.callback()
            end
        end,
    }

    self[1] = FrameContainer:new{
        padding           = 0,
        bordersize        = 0,
        focusable         = true,
        focus_border_size = Size.border.thin,
        LeftContainer:new{
            dimen = Geom:new{ w = self.width, h = self.height },
            button,
        },
    }
end

local FontPickerWidget = SortWidget:extend{
    modal             = true,
    covers_fullscreen = true,
    sort_disabled     = true,
}

function FontPickerWidget:init()
    self.show_page = self.show_page or 1
    SortWidget.init(self)

    -- No cancel / accept buttons in the footer: same-width spacers instead,
    -- so the page navigation stays centred (see BookListWidget:init).
    self.page_info[1] = HorizontalSpan:new{ width = self.footer_button_width }
    self.page_info[#self.page_info] = HorizontalSpan:new{ width = self.footer_button_width }
    local footer_row = self.layout and self.layout[#self.layout]
    if footer_row and #footer_row > 2 then
        table.remove(footer_row, 1)
        table.remove(footer_row)
    end

    self:_fitRows()
end

-- SortWidget works out for itself how many rows fit on a page; keep that
-- as it is and just open on the page that holds the currently selected font.
function FontPickerWidget:_fitRows()
    local per_page = math.max(1, self.items_per_page or 1)
    self.pages = math.max(1, math.ceil(#self.item_table / per_page))

    for idx, item in ipairs(self.item_table) do
        if item.checked_func and item.checked_func() then
            self.show_page = math.ceil(idx / per_page)
            break
        end
    end
    if self.show_page > self.pages then self.show_page = self.pages end
    if self.show_page < 1 then self.show_page = 1 end

    self:_populateItems()
end

function FontPickerWidget:_close()
    UIManager:close(self)
    UIManager:setDirty(nil, "ui")
    return true
end

function FontPickerWidget:onClose()         return self:_close() end
function FontPickerWidget:onReturn()        return self:_close() end
function FontPickerWidget:onCancelOrClose() return self:_close() end

-- Lays out one page of rows (a copy of SortWidget's own, without the
-- item-moving parts, with FontPickerItem in place of SortItemWidget).
function FontPickerWidget:_populateItems()
    self.main_content:clear()
    self.layout = { self.layout[#self.layout] } -- keep the footer row

    local size       = sampleSizeDefault()
    local idx_offset = (self.show_page - 1) * self.items_per_page
    local page_last  = math.min(idx_offset + self.items_per_page, #self.item_table)
    for idx = idx_offset + 1, page_last do
        local item = self.item_table[idx]
        table.insert(self.main_content, VerticalSpan:new{ width = self.item_margin })
        local row = FontPickerItem:new{
            height      = self.item_height,
            width       = self.item_width,
            item        = item,
            face        = sampleFace(item.font_name or item.text, size),
            show_parent = self,
        }
        table.insert(self.layout, #self.layout, { row })
        table.insert(self.main_content, row)
    end
    self:moveFocusTo(1, 1)

    self.footer_page:setText(
        Tmpl(C_("Pagination", "%1 / %2"), self.show_page, self.pages),
        self.footer_center_width)
    if self.pages > 1 then
        self.footer_page:enable()
    else
        self.footer_page:disableWithoutDimming()
    end
    self.footer_left:enableDisable(self.show_page > 1)
    self.footer_right:enableDisable(self.show_page < self.pages)
    self.footer_first_up:enableDisable(self.show_page > 1)
    self.footer_last_down:enableDisable(self.show_page < self.pages)

    UIManager:setDirty(self, function()
        return "ui", self.dimen
    end)
end

local function showFontPickerMenu(key, touchmenu_instance, on_change)
    local entries = getPickerEntries(key)
    local item_table = {}
    local picker
    for _idx, entry in ipairs(entries) do
        table.insert(item_table, {
            text      = entry.label,
            font_name = entry.name,
            checked_func = function()
                local current = M.getName(key) or M.getDefaultName(key)
                return displayStem(current):lower() == entry.label:lower()
            end,
            callback = function()
                M.setName(key, entry.name)
                picker:_close()
                if touchmenu_instance then touchmenu_instance:updateItems() end
                if on_change then on_change() end
            end,
        })
    end

    picker = FontPickerWidget:new{
        title      = labelFor(key) .. ": " .. _("Choose a font"),
        item_table = item_table,
    }
    UIManager:show(picker)
end

function labelFor(key)
    local labels = {
        title      = _("Title"),
        author     = _("Author"),
        series     = _("Series"),
        quote      = _("Highlighted quote"),
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
                return _("Font") .. ": " .. displayStem(M.getName(key) or M.getDefaultName(key))
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
                return labelFor(key) .. ": " .. displayStem(name) .. " @ " .. sizeText(key)
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
