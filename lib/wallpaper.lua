--[[
Book card - a background picture behind the whole card, plus translucent
"backdrop" panels so text stays legible over it.

Modeled after Bookshelf's lib/bookshelf_wallpaper.lua, trimmed down to what
Book card actually needs: ONE full-screen picture (there is only one card,
not a library of shelves), and a single opacity knob for the panels behind
each piece of text, instead of a whole scrim/panel system.

  <KOReader settings dir>/bookcard/wallpapers/    where pictures are read from

  Wallpaper.SETTING            "bookcard_wallpaper" - chosen file name, or
                                false/unset for "no picture" (the default,
                                which keeps the plain background exactly as
                                before this feature existed)
  Wallpaper.OPACITY_SETTING    "bookcard_text_bg_opacity" - 0..1

  Wallpaper.isActive()         true if a wallpaper is set and its file exists
  Wallpaper.opacity()          current text-backdrop opacity, 0..1
  Wallpaper.opacityLabel()     human label for the current opacity ("Low", ...)
  Wallpaper.currentLabel()     human label for the current wallpaper ("None", ...)

  Wallpaper.bg(w, h, night)    a paintable w x h widget for the picture, or
                                nil if there is none / it could not be decoded
  Wallpaper.panel(w, h, color, opacity, radius)
                                a paintable translucent rectangle (for behind
                                a piece of text), or nil if opacity is 0
  Wallpaper.free()             drop the decoded picture (call after changing
                                which file is selected)

  Wallpaper.buildPickerMenu()  sub_item_table: "None" + every picture found
  Wallpaper.buildOpacityMenu() sub_item_table: the named opacity levels
]]--

local deps = ...
local Locale = deps.Locale
local Prefs  = deps.Prefs
local _ = Locale._

local Blitbuffer = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local Geom = require("ui/geometry")
local Widget = require("ui/widget/widget")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local M = {}

M.SETTING         = "bookcard_wallpaper"
M.OPACITY_SETTING = "bookcard_text_bg_opacity"
M.SUBDIR          = "bookcard/wallpapers"
M.DEFAULT_OPACITY = 0.6
M.RANDOM          = "*random*"   -- stored in SETTING when "Random" is chosen

M.EXTS = { png = true, jpg = true, jpeg = true, bmp = true, gif = true, webp = true }

-- Named opacity levels for the "Text background opacity" menu. 0 ("Off")
-- is a real, useful choice: a wallpaper with no backdrop behind the text at
-- all, for pictures calm enough not to need one.
M.LEVELS = {
    { value = 0,    label = function() return _("Off") end },
    { value = 0.35, label = function() return _("Low") end },
    { value = 0.6,  label = function() return _("Moderate") end },
    { value = 0.85, label = function() return _("High") end },
    { value = 1,    label = function() return _("Solid") end },
}

-- ---------------------------------------------------------------------------
-- Where the pictures live
-- ---------------------------------------------------------------------------
function M.dir()
    return DataStorage:getSettingsDir() .. "/" .. M.SUBDIR
end

function M.ensureDir()
    local d = M.dir()
    if lfs.attributes(d, "mode") == "directory" then return true end
    local ok = pcall(require("util").makePath, d .. "/")
    return ok and lfs.attributes(d, "mode") == "directory"
end

-- list() -> { { name, label }, ... } sorted by label. `name` is the plain
-- file name (what gets stored in the setting); `label` drops the extension.
function M.list()
    M.ensureDir()
    local d = M.dir()
    local out = {}
    pcall(function()
        for name in lfs.dir(d) do
            local ext = name:match("%.([^%.]+)$")
            if name ~= "." and name ~= ".." and ext and M.EXTS[ext:lower()] then
                out[#out + 1] = { name = name, label = name:match("^(.+)%.[^%.]+$") or name }
            end
        end
    end)
    table.sort(out, function(a, b) return a.label:lower() < b.label:lower() end)
    return out
end

-- pathFor(name) -> absolute path, or nil if there is no such file. Refuses
-- anything carrying a path separator: `name` comes out of settings, which a
-- reader can hand-edit.
function M.pathFor(name)
    if type(name) ~= "string" or name == "" then return nil end
    if name:find("/", 1, true) or name:find("\\", 1, true) then return nil end
    if name == "." or name == ".." then return nil end
    local path = M.dir() .. "/" .. name
    if lfs.attributes(path, "mode") ~= "file" then return nil end
    return path
end

-- ---------------------------------------------------------------------------
-- Which one is chosen
-- ---------------------------------------------------------------------------
function M.selectedName()
    local v = Prefs.read(M.SETTING, false)
    if type(v) == "string" and v ~= "" then return v end
    return nil
end

function M.isRandom()
    return M.selectedName() == M.RANDOM
end

-- reroll() -- forget the current random pick, so the next activeName() picks
-- a fresh picture. Called each time a card is built. Harmless when "Random"
-- is not the chosen mode.
function M.reroll()
    M._random_name = nil
end

-- activeName() -> the file name to actually draw: the chosen one, or (in
-- Random mode) one picked at random from the folder. The pick is kept until
-- reroll() so isActive() and bg() within one build agree on the picture.
-- Returns nil when there is nothing to draw.
function M.activeName()
    local name = M.selectedName()
    if name ~= M.RANDOM then return name end
    if M._random_name and M.pathFor(M._random_name) then
        return M._random_name
    end
    local list = M.list()
    if #list == 0 then return nil end
    -- Avoid showing the very same picture twice in a row when there is a choice.
    local pool = list
    if #list > 1 and M._last_random_name then
        pool = {}
        for _i, it in ipairs(list) do
            if it.name ~= M._last_random_name then pool[#pool + 1] = it end
        end
    end
    local pick = pool[math.random(#pool)]
    M._random_name = pick.name
    M._last_random_name = pick.name
    return pick.name
end

function M.isActive()
    local name = M.activeName()
    return name ~= nil and M.pathFor(name) ~= nil
end

function M.currentLabel()
    local name = M.selectedName()
    if not name then return _("None") end
    if name == M.RANDOM then return _("Random") end
    for _i, it in ipairs(M.list()) do
        if it.name == name then return it.label end
    end
    return name
end

function M.opacity()
    local v = Prefs.read(M.OPACITY_SETTING, nil)
    if type(v) ~= "number" then return M.DEFAULT_OPACITY end
    if v < 0 then return 0 end
    if v > 1 then return 1 end
    return v
end

function M.opacityLabel()
    local cur = M.opacity()
    for _i, lvl in ipairs(M.LEVELS) do
        if math.abs(lvl.value - cur) < 0.01 then return lvl.label() end
    end
    return tostring(math.floor(cur * 100 + 0.5)) .. "%"
end

-- ---------------------------------------------------------------------------
-- The decoded picture (one cached entry - a full screen bitmap is a few MB;
-- see Bookshelf's own wallpaper module for why holding more is not worth it)
-- ---------------------------------------------------------------------------
M._bg, M._bg_key = nil, nil

local Background = Widget:extend{ bb = nil, w = 0, h = 0 }

function Background:getSize()
    return Geom:new{ w = self.w, h = self.h }
end

function Background:paintTo(target, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.w, h = self.h }
    if not self.bb then return end
    pcall(function()
        target:blitFrom(self.bb, x, y, 0, 0, self.w, self.h)
    end)
end

-- free() -- drop the decoded backdrop. Freed on the next tick rather than
-- immediately: the widget holding it may still be in the live tree for one
-- more paint (same reasoning, and same fix, as Bookshelf's wallpaper module).
function M.free()
    local old = M._bg
    M._bg, M._bg_key = nil, nil
    if not (old and old.bb) then return end
    local bb = old.bb
    local ok_ui, UIManager = pcall(require, "ui/uimanager")
    if ok_ui and UIManager and UIManager.nextTick then
        UIManager:nextTick(function()
            old.bb = nil
            pcall(function() if bb.free then bb:free() end end)
        end)
    else
        old.bb = nil
        pcall(function() if bb.free then bb:free() end end)
    end
end

-- bg(w, h, night) -> a paintable w x h widget for the current wallpaper, or
-- nil. `night` must be Screen.night_mode: KOReader inverts the whole panel
-- at refresh when it is on, so a picture that should look like itself has to
-- be painted pre-inverted, exactly like the cover.
function M.bg(w, h, night)
    local name = M.activeName()
    if not name or not w or not h or w <= 0 or h <= 0 then return nil end
    local path = M.pathFor(name)
    if not path then return nil end

    local key = path .. "|" .. w .. "x" .. h .. (night and "|n" or "")
    if M._bg and M._bg_key == key then return M._bg end
    M.free()

    local ok, bb = pcall(function()
        local RenderImage = require("ui/renderimage")
        return RenderImage:renderImageFile(path, false, w, h)
    end)
    if not ok or not bb then
        logger.info("[bookcard] wallpaper could not be decoded:", path)
        return nil
    end
    if night and bb.invertRect then
        pcall(function() bb:invertRect(0, 0, bb:getWidth(), bb:getHeight()) end)
    end
    local widget = Background:new{ bb = bb, w = w, h = h }
    M._bg, M._bg_key = widget, key
    return widget
end

-- restore(target, x, y, w, h) -> true if it put the wallpaper's OWN pixels
-- back at that spot, instead of painting some flat colour there.
--
-- Chrome that "cuts" a shape - a rounded cover corner, say - normally does
-- it by painting the page's ground colour back over itself: on a plain page
-- that ground is just a colour, so that works. Over a wallpaper the ground
-- is a photograph, and painting a flat colour there instead punches a
-- visible solid-colour square right where a rounded corner should reveal
-- the picture behind it (this is exactly why rounded cover corners looked
-- wrong over a wallpaper before this existed).
--
-- Because the cached picture is drawn full-screen at (0, 0), screen (x, y)
-- IS wallpaper (x, y): restoring is one small blit from the same
-- coordinates, no cropping math needed. Returns false (leaving the caller's
-- original flat-colour paint in place) whenever there is no wallpaper, or
-- the cached bitmap does not cover the full screen the caller is painting
-- to (e.g. it was decoded for a different rotation and has not been
-- rebuilt yet) - restoring the wrong part of the picture would be worse
-- than the flat colour it is trying to improve on.
function M.restore(target, x, y, w, h)
    if not (M._bg and M._bg.bb) then return false end
    if not target or not w or not h or w <= 0 or h <= 0 then return false end
    if not (target.getWidth and target.getHeight) then return false end
    if target:getWidth() ~= M._bg.w or target:getHeight() ~= M._bg.h then return false end
    local ok = pcall(function()
        target:blitFrom(M._bg.bb, x, y, x, y, w, h)
    end)
    return ok and true or false
end

-- ---------------------------------------------------------------------------
-- Translucent panels, for behind a piece of text
-- ---------------------------------------------------------------------------

-- _roundedSpans(x, y, w, h, r) -> row spans tiling a rounded rect EXACTLY
-- ONCE each, so a blended fill is not painted twice on the corners (which
-- would come out darker than the rest of the panel). No anti-aliasing:
-- a one-pixel stair step is invisible on an e-ink screen.
local function roundedSpans(x, y, w, h, r)
    r = math.min(r or 0, math.floor(w / 2), math.floor(h / 2))
    if r <= 0 then return { { x = x, y = y, w = w, h = h } } end
    local spans = {}
    for i = 0, r - 1 do
        local dy = r - i - 0.5
        local inset = math.floor(r - math.sqrt(r * r - dy * dy) + 0.5)
        local sw = w - inset * 2
        if sw > 0 then
            spans[#spans + 1] = { x = x + inset, y = y + i,         w = sw, h = 1 }
            spans[#spans + 1] = { x = x + inset, y = y + h - 1 - i, w = sw, h = 1 }
        end
    end
    local mid_h = h - r * 2
    if mid_h > 0 then
        spans[#spans + 1] = { x = x, y = y + r, w = w, h = mid_h }
    end
    return spans
end

-- blend(target, x, y, w, h, color, strength, radius) -> true if it painted.
-- Tints the rect toward `color` at `strength` (0..1) using blendRectRGB32,
-- so whatever is already there (the wallpaper) shows through underneath.
-- Falls back to an opaque fill wherever the C blitter is unavailable, or the
-- panel was asked to be fully solid (strength >= 1) - the common case for a
-- reader who wants maximum legibility.
function M.blend(target, x, y, w, h, color, strength, radius)
    if not target or not color then return false end
    if not w or not h or w <= 0 or h <= 0 then return false end
    strength = strength or M.DEFAULT_OPACITY
    if strength <= 0 then return false end
    if strength > 1 then strength = 1 end
    if not Blitbuffer.ColorRGB32 then return false end

    return pcall(function()
        local no_cbb = type(target.canUseCbb) == "function" and not target:canUseCbb()
        local opaque = strength >= 1 or not target.blendRectRGB32 or no_cbb
        local tint
        if not opaque then
            local c = color.getColorRGB32 and color:getColorRGB32() or color
            local alpha = math.min(255, math.floor(255 * strength + 0.5))
            tint = Blitbuffer.ColorRGB32(c:getR(), c:getG(), c:getB(), alpha)
        end
        for _i, s in ipairs(roundedSpans(x, y, w, h, radius or 0)) do
            if opaque then
                target:paintRect(s.x, s.y, s.w, s.h, color)
            else
                target:blendRectRGB32(s.x, s.y, s.w, s.h, tint)
            end
        end
    end)
end

local Panel = Widget:extend{
    w = 0, h = 0, color = nil, strength = 0, radius = 0,
}

function Panel:getSize()
    return Geom:new{ w = self.w, h = self.h }
end

function Panel:paintTo(target, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.w, h = self.h }
    M.blend(target, x, y, self.w, self.h, self.color, self.strength, self.radius)
end

-- panel(w, h, color, opacity, radius) -> a paintable widget, or nil when
-- there is nothing to paint (opacity 0, or a bad size).
function M.panel(w, h, color, opacity, radius)
    if not color or not opacity or opacity <= 0 then return nil end
    if not w or not h or w <= 0 or h <= 0 then return nil end
    return Panel:new{ w = w, h = h, color = color, strength = opacity, radius = radius or 0 }
end

-- ---------------------------------------------------------------------------
-- mask(): for widgets that paint their OWN opaque background (TextBoxWidget,
-- unlike plain TextWidget, always fills itself with bgcolor and blits the
-- result as a solid block - it has no transparent mode). That is why the
-- title looked like it had a solid box behind it even with a panel drawn
-- underneath: the title's own opaque fill was covering the panel.
--
-- The fix: render the inner widget onto a plain WHITE/BLACK scratch buffer
-- (so its own colors don't matter), which is then just a glyph-coverage
-- mask; colorblitFrom uses that coverage as ALPHA, so painting it with
-- `fgcolor` draws only the glyphs, leaving everything around them alone -
-- the panel and the wallpaper show through exactly like they do around any
-- other text.
--
-- `inner` should be built with bgcolor = COLOR_WHITE and fgcolor =
-- COLOR_BLACK (its own colors are discarded; only the shape survives). The
-- REAL colour is `fgcolor` here.
-- ---------------------------------------------------------------------------
local Mask = Widget:extend{ inner = nil, fgcolor = nil, _mask = nil }

function Mask:getSize()
    return self.inner:getSize()
end

function Mask:_build()
    local sz = self.inner:getSize()
    if not sz or sz.w <= 0 or sz.h <= 0 then return nil end
    local scratch = Blitbuffer.new(sz.w, sz.h, Blitbuffer.TYPE_BB8)
    scratch:fill(Blitbuffer.COLOR_WHITE)
    self.inner:paintTo(scratch, 0, 0)
    scratch:invertRect(0, 0, sz.w, sz.h)
    return scratch
end

function Mask:paintTo(target, x, y)
    local sz = self:getSize()
    self.dimen = Geom:new{ x = x, y = y, w = sz.w, h = sz.h }
    if not self._mask then
        local ok, m = pcall(self._build, self)
        if not ok or not m then
            -- Better an opaque block of readable text than nothing.
            return self.inner:paintTo(target, x, y)
        end
        self._mask = m
    end
    local m = self._mask
    pcall(function()
        target:colorblitFrom(m, x, y, 0, 0, m:getWidth(), m:getHeight(), self.fgcolor)
    end)
end

-- contentWidth() -> the width of the actual rendered text (the widest of
-- its lines, up to the first 2 - this card never shows more), or nil if it
-- can't be determined. Mask:getSize() always reports the FULL width of the
-- box the inner TextBoxWidget was given (that is what TextBoxWidget itself
-- returns: it is a box of a fixed width, not shrink-wrapped to its
-- content). For a short title that meant the backdrop panel behind it
-- stretched all the way to the edge of the column, well past where the
-- title text itself ends - unlike the author/series lines below it, which
-- use plain TextWidgets sized to their own real text width, so their
-- panels hug the text exactly. This reads TextBoxWidget's own per-line
-- layout (vertical_string_list[n].width, the same numbers it uses
-- internally to center/align each line) to get that same tight fit for
-- the title. Wrapped in pcall and returns nil on failure, so a caller can
-- always fall back to the full box width.
function Mask:contentWidth()
    local inner = self.inner
    if type(inner) ~= "table" then return nil end
    local ok, w = pcall(function()
        if inner.getSize then inner:getSize() end -- forces layout, fills vertical_string_list
        local list = inner.vertical_string_list
        if type(list) ~= "table" then return nil end
        local max_w = 0
        for i = 1, math.min(#list, 2) do
            local line = list[i]
            if line and type(line.width) == "number" and line.width > max_w then
                max_w = line.width
            end
        end
        return max_w > 0 and max_w or nil
    end)
    if ok and type(w) == "number" then return w end
    return nil
end

function Mask:free()
    if self._mask then
        pcall(function() if self._mask.free then self._mask:free() end end)
        self._mask = nil
    end
    if self.inner and self.inner.free then pcall(function() self.inner:free() end) end
end
Mask.onCloseWidget = Mask.free

-- mask(active, inner, fgcolor) -> a widget, or `inner` untouched when
-- `active` is false (the normal, no-wallpaper case: unchanged appearance).
function M.mask(active, inner, fgcolor)
    if not active or type(inner) ~= "table" then return inner end
    return Mask:new{ inner = inner, fgcolor = fgcolor or Blitbuffer.COLOR_BLACK }
end

-- ---------------------------------------------------------------------------
-- Menus
-- ---------------------------------------------------------------------------

-- buildPickerMenu() -> sub_item_table for "Wallpaper": "None" first (so
-- turning it off never depends on finding a row in a long list), then
-- "Random" (a different picture from the folder each time the card is
-- built), a separator line, then every
-- picture found in the folder, then a disabled footnote naming the folder -
-- shown whether or not it is empty, so a reader who already has one never
-- has to delete it to discover where to add their own.
function M.buildPickerMenu()
    local items = {}
    items[#items + 1] = {
        text = _("None"),
        radio = true,
        checked_func = function() return M.selectedName() == nil end,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            Prefs.save(M.SETTING, false)
            M.free()
            if touchmenu_instance then touchmenu_instance:updateItems() end
        end,
    }
    items[#items + 1] = {
        text = _("Random"),
        radio = true,
        checked_func = function() return M.isRandom() end,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            Prefs.save(M.SETTING, M.RANDOM)
            M.reroll()
            M.free()
            if touchmenu_instance then touchmenu_instance:updateItems() end
        end,
        separator = true,
    }
    local list = M.list()
    for i, it in ipairs(list) do
        items[#items + 1] = {
            text = it.label,
            radio = true,
            checked_func = function() return M.selectedName() == it.name end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                Prefs.save(M.SETTING, it.name)
                M.free()
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
            separator = (i == #list) or nil,
        }
    end
    if #list == 0 then
        items[#items + 1] = {
            text = Locale.tpl(_("No images in {dir}"), { dir = M.dir() or "?" }),
            enabled = false,
            separator = true,
        }
    end
    items[#items + 1] = {
        text = Locale.tpl(_("Images are loaded from {dir}"), { dir = M.dir() or "?" }),
        enabled = false,
    }
    return items
end

-- buildOpacityMenu() -> sub_item_table for "Text background opacity": the
-- named levels above, as a radio group.
function M.buildOpacityMenu()
    local items = {}
    for _i, lvl in ipairs(M.LEVELS) do
        local value = lvl.value
        items[#items + 1] = {
            text = lvl.label(),
            radio = true,
            checked_func = function() return math.abs(M.opacity() - value) < 0.01 end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                Prefs.save(M.OPACITY_SETTING, value)
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
        }
    end
    return items
end

return M
