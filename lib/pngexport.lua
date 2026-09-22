--[[
Book Card - export the card as a PNG file that refreshes itself.

Why this exists: KOReader's own sleep screen (what lib/screensaver.lua hooks)
only ever appears on platforms where KOReader itself owns the "device is
asleep" screen - Kindle, Kobo, and similar. On Android, locking the screen
hands control to Android's own lock screen; KOReader is just backgrounded,
so a live KOReader widget (the normal Book Card sleep screen) is never
drawn there at all. Ink Stain Wallpaper works around exactly this by
rendering its wallpaper to a plain PNG file that the user sets as the
Android system/lock-screen wallpaper by hand (or with a wallpaper-rotation
app that watches a folder); this module gives Book Card the same escape
hatch, reusing the exact card layout from lib/screensaver.lua.

  <KOReader data dir>/screensaver/bookcard_png/bookcard_wallpaper.png
                                always written here when exporting is on

  PngExport.SETTING_ENABLED    "bookcard_image_export_enabled" - default off
  PngExport.SETTING_SAVE_PATH  "bookcard_image_export_path" - an extra
                                folder to also copy the PNG into (e.g. a
                                shared "Pictures" folder on Android, so it
                                shows up in the system's own wallpaper
                                picker); "" or unset = don't copy anywhere
                                extra
  PngExport.SETTING_INTERVAL   "bookcard_image_export_interval" - seconds
                                between automatic refreshes while enabled

  PngExport.isEnabled()        current on/off state
  PngExport.outputDir()        folder the plain (always-on) copy lives in
  PngExport.outputFile()       full path to that copy
  PngExport.customFile()       full path to the extra copy, or nil
  PngExport.write(ui)          render + write now -> true, or nil + message
  PngExport.buildPathChooser(on_done)
                                a PathChooser widget for picking the extra
                                folder; calls on_done(path) after a pick
]]--

local deps = ...
local Locale = deps.Locale
local Prefs  = deps.Prefs
local Sleep  = deps.Sleep
local _ = Locale._

local DataStorage = require("datastorage")
local Device = require("device")
local Screen = Device.screen
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local M = {}

M.SETTING_ENABLED   = "bookcard_image_export_enabled"
M.SETTING_SAVE_PATH = "bookcard_image_export_path"
M.SETTING_INTERVAL  = "bookcard_image_export_interval"

M.DEFAULT_INTERVAL = 15 * 60 -- 15 minutes

M.FILENAME = "bookcard_wallpaper.png"

-- Named refresh intervals for the menu, mirroring the shape of
-- Wallpaper.LEVELS in lib/wallpaper.lua.
M.INTERVALS = {
    { value = 5 * 60,  label = function() return _("Every 5 minutes") end },
    { value = 15 * 60, label = function() return _("Every 15 minutes") end },
    { value = 30 * 60, label = function() return _("Every 30 minutes") end },
    { value = 60 * 60, label = function() return _("Every hour") end },
}

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------
function M.isEnabled()
    return Prefs.readBool(M.SETTING_ENABLED, false)
end

function M.setEnabled(on)
    Prefs.save(M.SETTING_ENABLED, on and true or false)
end

function M.interval()
    local v = tonumber(Prefs.read(M.SETTING_INTERVAL, M.DEFAULT_INTERVAL))
    if not v or v <= 0 then return M.DEFAULT_INTERVAL end
    return v
end

function M.intervalLabel()
    local cur = M.interval()
    for _i, lvl in ipairs(M.INTERVALS) do
        if lvl.value == cur then return lvl.label() end
    end
    return tostring(math.floor(cur / 60 + 0.5)) .. " " .. _("min")
end

function M.buildIntervalMenu()
    local items = {}
    for _i, lvl in ipairs(M.INTERVALS) do
        local value = lvl.value
        items[#items + 1] = {
            text = lvl.label(),
            radio = true,
            checked_func = function() return M.interval() == value end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                Prefs.save(M.SETTING_INTERVAL, value)
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
        }
    end
    return items
end

-- ---------------------------------------------------------------------------
-- Where the files live
-- ---------------------------------------------------------------------------
function M.outputDir()
    return DataStorage:getDataDir() .. "/screensaver/bookcard_png"
end

function M.outputFile()
    return M.outputDir() .. "/" .. M.FILENAME
end

-- customFile() -> the extra copy's full path, or nil if no extra folder is
-- configured. Only ever adds/overwrites its own file name in that folder -
-- never cleaned up automatically, so it never touches anything else the
-- reader keeps there.
function M.customFile()
    local p = Prefs.read(M.SETTING_SAVE_PATH, "")
    if type(p) ~= "string" or p == "" then return nil end
    return p:gsub("/$", "") .. "/" .. M.FILENAME
end

local function ensureDir(dir)
    if lfs.attributes(dir, "mode") == "directory" then return true end
    local ok = pcall(require("util").makePath, dir .. "/")
    return ok and lfs.attributes(dir, "mode") == "directory"
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------
-- renderToBlitbuffer(ui) -> bb, or nil + a reason string ("nodata" - there
-- is no card to draw yet - or "render" - a card exists but drawing it into
-- an offscreen bitmap failed). Reuses lib/screensaver.lua's own widget
-- builder, so the exported picture is pixel-for-pixel the same card the
-- native sleep screen would show.
local function renderToBlitbuffer(ui)
    local ok_widget, widget = pcall(Sleep.buildWidget, ui)
    if not ok_widget then
        logger.warn("BookCard: buildWidget raised an error for image export:", widget)
        return nil, "render"
    end
    if not widget then
        -- No card yet: no live book, no cache, no last-opened file.
        return nil, "nodata"
    end

    local w, h = Screen:getWidth(), Screen:getHeight()
    local ok_size, size = pcall(function() return widget:getSize() end)
    if ok_size and size and size.w and size.h and size.w > 0 and size.h > 0 then
        w, h = size.w, size.h
    end

    -- Blitbuffer.new(width, height, type) is a plain constructor (called as
    -- Blitbuffer.new(...), NOT Blitbuffer:new(...)) - it must NOT be given
    -- the module table as an extra leading argument.
    local Blitbuffer = require("ffi/blitbuffer")
    local bb_type = nil
    local ok_type, t = pcall(function() return Screen.bb and Screen.bb:getType() end)
    if ok_type then bb_type = t end

    local ok_bb, bb
    if bb_type then
        ok_bb, bb = pcall(Blitbuffer.new, w, h, bb_type)
    end
    if not (ok_bb and bb) then
        ok_bb, bb = pcall(Blitbuffer.new, w, h)
    end
    if not (ok_bb and bb) then
        logger.warn("BookCard: could not allocate an offscreen bitmap for image export:", bb)
        if widget.free then pcall(function() widget:free() end) end
        return nil, "render"
    end

    local ok_paint, paint_err = pcall(function() widget:paintTo(bb, 0, 0) end)
    if widget.free then pcall(function() widget:free() end) end
    if not ok_paint then
        pcall(function() bb:free() end)
        logger.warn("BookCard: could not paint the card for image export:", paint_err)
        return nil, "render"
    end
    return bb
end

local function writeBB(bb, path)
    if bb.writeToFile then
        local ok, ret = pcall(bb.writeToFile, bb, path, "png", nil, true)
        return ok and ret and true or false
    elseif bb.writePNG then
        local ok, ret = pcall(bb.writePNG, bb, path)
        return ok and ret and true or false
    end
    return false
end

-- write(ui) -> true, or nil + a human-readable message. Always writes the
-- plain (always-on) copy first; the extra folder copy is best-effort and
-- never turns a successful export into a failure.
function M.write(ui)
    if not ensureDir(M.outputDir()) then
        return nil, _("Could not create the image export folder.")
    end
    local bb, why = renderToBlitbuffer(ui)
    if not bb then
        if why == "nodata" then
            return nil, _("No book data yet. Open a book and read a few pages first.")
        end
        return nil, _("Could not draw the card as an image (see the log for details).")
    end

    local ok = writeBB(bb, M.outputFile())
    if not ok then
        pcall(function() bb:free() end)
        return nil, _("Could not write the image file.")
    end

    local custom = M.customFile()
    if custom then
        local cdir = custom:match("^(.+)/[^/]+$")
        if cdir and ensureDir(cdir) then
            if not writeBB(bb, custom) then
                logger.warn("BookCard: could not write the extra image export copy:", custom)
            end
        end
    end

    pcall(function() bb:free() end)
    return true
end

-- ---------------------------------------------------------------------------
-- Folder picker for the extra copy
-- ---------------------------------------------------------------------------
-- buildPathChooser(on_done) -> a PathChooser widget, not yet shown, that
-- lets the reader pick the extra folder (e.g. a shared Pictures folder on
-- Android). on_done(path) is called after a folder is confirmed.
function M.buildPathChooser(on_done)
    local PathChooser = require("ui/widget/pathchooser")
    local current = Prefs.read(M.SETTING_SAVE_PATH, "")
    local start_dir = (type(current) == "string" and current ~= "") and current:gsub("/$", "") or "/"
    return PathChooser:new{
        title = _("Choose a folder to also save the image to"),
        select_file = false,
        select_directory = true,
        show_files = false,
        path = start_dir,
        onConfirm = function(path)
            if not path or path == "" then return end
            Prefs.save(M.SETTING_SAVE_PATH, path:gsub("/$", ""))
            if on_done then on_done(path) end
        end,
    }
end

function M.clearCustomPath()
    Prefs.save(M.SETTING_SAVE_PATH, "")
end

return M
