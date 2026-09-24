--[[
Book card - export the card as a PNG file that refreshes itself.

Why this exists: KOReader's own sleep screen (what lib/screensaver.lua hooks)
only ever appears on platforms where KOReader itself owns the "device is
asleep" screen - Kindle, Kobo, and similar. On Android, locking the screen
hands control to Android's own lock screen; KOReader is just backgrounded,
so a live KOReader widget (the normal Book card sleep screen) is never
drawn there at all. Ink Stain Wallpaper works around exactly this by
rendering its wallpaper to a plain PNG file that the user sets as the
Android system/lock-screen wallpaper by hand (or with a wallpaper-rotation
app that watches a folder); this module gives Book card the same escape
hatch, reusing the exact card layout from lib/screensaver.lua.

  <KOReader data dir>/screensaver/bookcard_png/bookcard_wallpaper.<ext>
                                always written here when exporting is on
                                (<ext> = png, jpg or bmp, see below)

  PngExport.SETTING_ENABLED    "bookcard_image_export_enabled" - default off
  PngExport.SETTING_SAVE_PATH  "bookcard_image_export_path" - an extra
                                folder to also copy the PNG into (e.g. a
                                shared "Pictures" folder on Android, so it
                                shows up in the system's own wallpaper
                                picker); "" or unset = don't copy anywhere
                                extra
  PngExport.SETTING_INTERVAL   "bookcard_image_export_interval" - seconds
                                between automatic refreshes while enabled
  PngExport.SETTING_FORMAT     "bookcard_image_export_format" - "png"
                                (default), "jpg" or "bmp"
  PngExport.SETTING_ON_OPEN    "bookcard_image_export_on_open" - also
                                refresh right after a book has been
                                opened (default on, only matters while
                                exporting is enabled)
  PngExport.SETTING_POCKETBOOK "bookcard_image_export_pocketbook" - also
                                write the card as PocketBook power-off /
                                boot logo (default off, PocketBook only)

  PngExport.isEnabled()        current on/off state
  PngExport.outputDir()        folder the plain (always-on) copy lives in
  PngExport.outputFile()       full path to that copy
  PngExport.customFile()       full path to the extra copy, or nil
  PngExport.write(ui, set_startup_logo)
                                render + write now -> true, or nil + message
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
M.SETTING_ON_OPEN   = "bookcard_image_export_on_open"
M.SETTING_FORMAT    = "bookcard_image_export_format"
M.SETTING_POCKETBOOK = "bookcard_image_export_pocketbook" -- default off

M.DEFAULT_INTERVAL = 15 * 60 -- 15 minutes

M.BASENAME = "bookcard_wallpaper"

M.JPG_QUALITY = 90

-- Output formats offered in the menu. "png" is lossless and the default;
-- "jpg" is much smaller; "bmp" is uncompressed (big files, but readable by
-- practically anything).
M.FORMATS = {
    { value = "png", label = "PNG" },
    { value = "jpg", label = "JPG" },
    { value = "bmp", label = "BMP" },
}

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

function M.exportOnOpen()
    return Prefs.readBool(M.SETTING_ON_OPEN, true)
end

function M.setExportOnOpen(on)
    Prefs.save(M.SETTING_ON_OPEN, on and true or false)
end

function M.format()
    local v = Prefs.read(M.SETTING_FORMAT, "png")
    for _i, f in ipairs(M.FORMATS) do
        if f.value == v then return v end
    end
    return "png"
end

function M.formatLabel()
    local cur = M.format()
    for _i, f in ipairs(M.FORMATS) do
        if f.value == cur then return f.label end
    end
    return "PNG"
end

-- on_change() is called after a different format has been picked.
function M.buildFormatMenu(on_change)
    local items = {}
    for _i, f in ipairs(M.FORMATS) do
        local value = f.value
        items[#items + 1] = {
            text = f.label,
            radio = true,
            checked_func = function() return M.format() == value end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                if M.format() ~= value then
                    Prefs.save(M.SETTING_FORMAT, value)
                    if on_change then on_change() end
                end
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
        }
    end
    return items
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

function M.filename(fmt)
    return M.BASENAME .. "." .. (fmt or M.format())
end

function M.outputFile()
    return M.outputDir() .. "/" .. M.filename()
end

-- customFile() -> the extra copy's full path, or nil if no extra folder is
-- configured. Only ever adds/overwrites its own file name in that folder -
-- never cleaned up automatically, so it never touches anything else the
-- reader keeps there.
function M.customFile()
    local p = Prefs.read(M.SETTING_SAVE_PATH, "")
    if type(p) ~= "string" or p == "" then return nil end
    return p:gsub("/$", "") .. "/" .. M.filename()
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

-- Uncompressed 24-bit BMP, written by hand (KOReader's blitbuffer has no
-- BMP encoder). Works on a copy converted to RGB32 so it does not matter
-- what pixel format the screen uses (grayscale devices included).
local function le16(n)
    return string.char(n % 256, math.floor(n / 256) % 256)
end

local function le32(n)
    return string.char(n % 256, math.floor(n / 256) % 256,
        math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256)
end

local function writeBMP(bb, path)
    local ffi = require("ffi")
    local Blitbuffer = require("ffi/blitbuffer")
    local w, h = bb:getWidth(), bb:getHeight()

    local src = Blitbuffer.new(w, h, Blitbuffer.TYPE_BBRGB32)
    src:blitFrom(bb, 0, 0, 0, 0, w, h)

    local data = ffi.cast("uint8_t*", src.data)
    local src_stride = src.stride
    local row_bytes = w * 3
    local out_stride = row_bytes + (4 - row_bytes % 4) % 4
    local img_size = out_stride * h
    local header_size = 14 + 40

    local f, open_err = io.open(path, "wb")
    if not f then
        pcall(function() src:free() end)
        error(open_err or "cannot open file")
    end

    local ok, err = pcall(function()
        -- BITMAPFILEHEADER + BITMAPINFOHEADER (bottom-up, 24 bpp, no compression)
        f:write("BM", le32(header_size + img_size), le32(0), le32(header_size),
            le32(40), le32(w), le32(h), le16(1), le16(24), le32(0), le32(img_size),
            le32(2835), le32(2835), le32(0), le32(0))
        local row = ffi.new("uint8_t[?]", out_stride) -- zero-filled, so the padding stays 0
        for y = h - 1, 0, -1 do
            local base = y * src_stride
            local o = 0
            for x = 0, w - 1 do
                local i = base + x * 4
                -- RGB32 in memory: r, g, b, alpha. BMP wants b, g, r.
                row[o]     = data[i + 2]
                row[o + 1] = data[i + 1]
                row[o + 2] = data[i]
                o = o + 3
            end
            f:write(ffi.string(row, out_stride))
        end
    end)
    f:close()
    pcall(function() src:free() end)
    if not ok then error(err) end
    return true
end

local function writeBB(bb, path, fmt)
    if fmt == "bmp" then
        local ok, err = pcall(writeBMP, bb, path)
        if not ok then logger.warn("BookCard: BMP export failed:", err) end
        return ok and true or false
    elseif fmt == "jpg" then
        if not bb.writeToFile then return false end
        -- Remove the old file first so "file exists and is non-empty" below
        -- really means this write worked.
        os.remove(path)
        local ok, ret = pcall(bb.writeToFile, bb, path, "jpg", M.JPG_QUALITY)
        if not ok then
            logger.warn("BookCard: JPG export failed:", ret)
            return false
        end
        local size = lfs.attributes(path, "size")
        return ret ~= false and size ~= nil and size > 0
    end
    if bb.writeToFile then
        local ok, ret = pcall(bb.writeToFile, bb, path, "png", nil, true)
        return ok and ret and true or false
    elseif bb.writePNG then
        local ok, ret = pcall(bb.writePNG, bb, path)
        return ok and ret and true or false
    end
    return false
end

-- After a successful write, remove the same file name in the OTHER formats
-- (bookcard_wallpaper.png/.jpg/.bmp - only this plugin's own names), so a
-- wallpaper changer watching the folder never picks up an outdated picture
-- after the format was switched.
local function removeOtherFormats(dir, keep_fmt)
    for _i, f in ipairs(M.FORMATS) do
        if f.value ~= keep_fmt then
            os.remove(dir .. "/" .. M.filename(f.value))
        end
    end
end

-- ---------------------------------------------------------------------------
-- PocketBook: power-off / boot logo
-- ---------------------------------------------------------------------------
-- PocketBook's firmware (not KOReader) draws the picture shown when the
-- device is switched off or booting, and it reads BMP files from these
-- folders. Only used on PocketBook devices where the folder really exists;
-- on Android / Kindle / Kobo / anything else this is skipped entirely.
local PB_LOGO_ROOT = "/mnt/ext1/system/logo"
local PB_LOGO_FILE = "bookcard.bmp"

local function isPocketBook()
    local ok, res = pcall(function()
        return Device.isPocketBook ~= nil and Device:isPocketBook()
    end)
    return ok and res and lfs.attributes(PB_LOGO_ROOT, "mode") == "directory"
end

M.isPocketBook = isPocketBook

-- True only on a PocketBook AND when the user switched the option on.
function M.pocketBookEnabled()
    return isPocketBook() and Prefs.readBool(M.SETTING_POCKETBOOK, false)
end

function M.setPocketBookEnabled(on)
    Prefs.save(M.SETTING_POCKETBOOK, on and true or false)
end

-- Minimal 24-bit BMP writer (fallback when the blitbuffer cannot write BMP
-- itself). BMP rows are stored bottom-up, in B,G,R order, padded to 4 bytes.
local function writePocketBookBMPManually(bb, path)
    local ffi = require("ffi")
    local Blitbuffer = require("ffi/blitbuffer")
    local w, h = bb:getWidth(), bb:getHeight()
    local rgb = Blitbuffer.new(w, h, Blitbuffer.TYPE_BBRGB24)
    rgb:blitFrom(bb, 0, 0, 0, 0, w, h)

    local row_size = math.floor((w * 3 + 3) / 4) * 4
    local img_size = row_size * h
    local function le32(n) return string.char(n % 256, math.floor(n / 256) % 256,
        math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256) end
    local function le16(n) return string.char(n % 256, math.floor(n / 256) % 256) end

    local f = io.open(path, "wb")
    if not f then rgb:free(); return false end
    f:write("BM", le32(54 + img_size), le32(0), le32(54),
        le32(40), le32(w), le32(h), le16(1), le16(24), le32(0), le32(img_size),
        le32(2835), le32(2835), le32(0), le32(0))

    local base = ffi.cast("uint8_t*", rgb.data)
    local row = ffi.new("uint8_t[?]", row_size)
    for y = h - 1, 0, -1 do
        local src = base + y * rgb.stride
        for x = 0, w - 1 do
            row[x * 3]     = src[x * 3 + 2]
            row[x * 3 + 1] = src[x * 3 + 1]
            row[x * 3 + 2] = src[x * 3]
        end
        f:write(ffi.string(row, row_size))
    end
    f:close()
    rgb:free()
    return true
end

local function writePocketBookBMP(bb, path)
    -- Newer builds may know "bmp" natively; otherwise write it ourselves.
    if bb.writeToFile then
        local ok, ret = pcall(bb.writeToFile, bb, path, "bmp", nil, true)
        if ok and ret and lfs.attributes(path, "size") and lfs.attributes(path, "size") > 54 then
            return true
        end
    end
    local ok, ret = pcall(writePocketBookBMPManually, bb, path)
    return ok and ret and true or false
end

-- Writes the card into PocketBook's offlogo/bootlogo folders. `set_startup_logo`
-- additionally asks the firmware to adopt the boot logo (iv2sh); that call
-- writes to flash, so it is only done on suspend / manual save, not on every
-- timer refresh. Never raises, never affects the normal export result.
local function exportPocketBook(bb, set_startup_logo)
    if not M.pocketBookEnabled() then return end
    for _i, sub in ipairs({ "offlogo", "bootlogo" }) do
        local dir = PB_LOGO_ROOT .. "/" .. sub
        if ensureDir(dir) then
            if not writePocketBookBMP(bb, dir .. "/" .. PB_LOGO_FILE) then
                logger.warn("BookCard: could not write PocketBook logo:", dir)
            end
        end
    end
    if set_startup_logo then
        local bootlogo = PB_LOGO_ROOT .. "/bootlogo/" .. PB_LOGO_FILE
        if lfs.attributes(bootlogo, "mode") == "file" then
            pcall(os.execute, "iv2sh WriteStartupLogo '" .. bootlogo .. "' >/dev/null 2>&1")
        end
    end
end

-- write(ui, set_startup_logo) -> true, or nil + a human-readable message. Always writes the
-- plain (always-on) copy first; the extra folder copy is best-effort and
-- never turns a successful export into a failure.
function M.write(ui, set_startup_logo)
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

    local fmt = M.format()
    local ok = writeBB(bb, M.outputFile(), fmt)
    if not ok then
        pcall(function() bb:free() end)
        return nil, _("Could not write the image file.")
    end
    removeOtherFormats(M.outputDir(), fmt)

    local custom = M.customFile()
    if custom then
        local cdir = custom:match("^(.+)/[^/]+$")
        if cdir and ensureDir(cdir) then
            if writeBB(bb, custom, fmt) then
                removeOtherFormats(cdir, fmt)
            else
                logger.warn("BookCard: could not write the extra image export copy:", custom)
            end
        end
    end

    pcall(exportPocketBook, bb, set_startup_logo)

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
