--[[
Book card - integration with KOReader's sleep screen ("Wallpaper" setting).

"Book card" becomes a real entry of Settings > Screen > Sleep screen >
Wallpaper (screensaver_type == "bookcard"). Two small, self-restoring
patches make core render it - core keeps doing everything else (rotation,
"tap to exit" / delay / gesture-lock, extra flashes, the optional sleep
screen message, cleanup on wake):

  1. Screensaver:setup()  core does not know our type, so for the duration
     of that one synchronous call the setting is swapped to "disable" (core
     then applies its own fallbacks) and put straight back. Afterwards the
     type is set to "bookstatus", a full-screen-widget mode core already
     understands (no forced rotation, no image background).
  2. Screensaver:show()   core builds a "bookstatus" screen with
     BookStatusWidget:new{}. For that one call `new` is replaced by a
     function that returns OUR widget, then removed again.

Both swaps happen inside a pcall in a single call stack; nothing is left
modified across the actual sleep, so a crash cannot leave a stale state.
If the card cannot be built, the sleep screen falls back to "leave screen
as-is" instead of showing nothing half-drawn.

  Screensaver.TYPE                     "bookcard"
  Screensaver.install()                apply both patches + the menu entry
  Screensaver.buildWidget(ui)          the card widget for the current state
  Screensaver.isSelected()             is "Book card" the chosen wallpaper?

Orientation ("Advanced Settings > Orientation"): by default the card is
drawn at whatever rotation the device already happens to be in (the
existing behaviour). If the user forces "portrait" or "landscape" instead,
the screen is rotated just before the card is drawn and rotated back to
whatever it was as soon as the device wakes up again.
]]--

local deps = ...
local Locale   = deps.Locale
local Data     = deps.Data
local Cache    = deps.Cache
local CardView = deps.CardView
local Prefs    = deps.Prefs

local Device = require("device")
local Screen = Device.screen
local logger = require("logger")
local _ = Locale._

local M = {}

M.TYPE = "bookcard"

-- Canonical rotation modes (see koreader-base's ffi/framebuffer.lua):
--   0 upright (portrait), 1 clockwise (landscape),
--   2 upside-down (portrait), 3 counter-clockwise (landscape)
local PORTRAIT_MODES  = { [0] = true, [2] = true }
local LANDSCAPE_MODES = { [1] = true, [3] = true }

-- Rotation mode we changed away from, so it can be restored on wake.
-- nil means "we haven't touched it".
M._saved_rotation = nil

-- Rotates the screen to match "Advanced Settings > Orientation", if the
-- user forced one and the screen isn't already in a matching mode.
-- No-op when the setting is left at "default" (current behaviour).
local function applyForcedOrientation()
    local want = Prefs.read(CardView.SETTING_ORIENTATION, "default")
    if want ~= "portrait" and want ~= "landscape" then return end

    local ok_get, cur = pcall(function() return Screen:getRotationMode() end)
    if not ok_get or cur == nil then return end

    local already_ok = (want == "portrait" and PORTRAIT_MODES[cur])
        or (want == "landscape" and LANDSCAPE_MODES[cur])
    if already_ok then return end

    local target = (want == "portrait")
        and Screen.DEVICE_ROTATED_UPRIGHT
        or Screen.DEVICE_ROTATED_CLOCKWISE
    local ok_set = pcall(function() Screen:setRotationMode(target) end)
    if ok_set then
        M._saved_rotation = cur
    end
end

-- Puts the screen rotation back the way it was before a forced orientation,
-- if we changed it. Safe to call unconditionally (e.g. on every wake-up).
function M.restoreOrientation()
    if M._saved_rotation == nil then return end
    local saved = M._saved_rotation
    M._saved_rotation = nil
    pcall(function() Screen:setRotationMode(saved) end)
end

function M.isSelected()
    return G_reader_settings:readSetting("screensaver_type") == M.TYPE
end

-- The card for what is happening right now:
--   book open  -> read the live state, and refresh the cache with it
--   no book    -> read the cache (rebuild from sidecar + DB if it is missing
--                 or belongs to another book than the last one opened)
function M.buildCard(ui)
    if ui and ui.document then
        local card = Data.collectLive(ui)
        if card then Cache.save(card) end
        return card
    end

    local lastfile = G_reader_settings:readSetting("lastfile")
    local card = Cache.load()
    if not card or (lastfile and card.file ~= lastfile) then
        card = lastfile and Data.collectFromFile(lastfile, ui) or nil
        if card then Cache.save(card) end
    end
    if not card then return nil end
    return Data.prepare(card, { live = false })
end

function M.buildWidget(ui)
    local card = M.buildCard(ui)
    if not card then return nil end
    return CardView.build(card)
end

function M.patchCore()
    local Screensaver = require("ui/screensaver")
    if Screensaver._bookcard_patched then return end
    Screensaver._bookcard_patched = true

    local orig_setup = Screensaver.setup
    local orig_show  = Screensaver.show

    Screensaver.setup = function(self, event, event_message)
        self._bookcard_active = false

        -- Same key lookup core does: "poweroff_screensaver_type" etc. win
        -- over the plain key when they exist.
        local key = "screensaver_type"
        local prefixed = event and (event .. "_screensaver_type")
        if prefixed and G_reader_settings:has(prefixed) then key = prefixed end

        if G_reader_settings:readSetting(key) ~= M.TYPE then
            return orig_setup(self, event, event_message)
        end

        G_reader_settings:saveSetting(key, "disable")
        local ok, err = pcall(orig_setup, self, event, event_message)
        G_reader_settings:saveSetting(key, M.TYPE)
        if not ok then error(err) end

        if self.ui then
            self._bookcard_active = true
            self.screensaver_type = "bookstatus"
        end
    end

    Screensaver.show = function(self)
        if not self._bookcard_active then return orig_show(self) end
        self._bookcard_active = false

        applyForcedOrientation()

        local ok_build, widget = pcall(M.buildWidget, self.ui)
        if not ok_build or not widget then
            logger.warn("BookCard: could not build the card:", widget)
            M.restoreOrientation()
            self.screensaver_type = "disable"
            return orig_show(self)
        end

        local BookStatusWidget = require("ui/widget/bookstatuswidget")
        local own_new = rawget(BookStatusWidget, "new")
        BookStatusWidget.new = function() return widget end
        local ok, err = pcall(orig_show, self)
        BookStatusWidget.new = own_new
        if not ok then error(err) end
    end
end

-- Adds "Book card" to core's Sleep screen > Wallpaper radio group. Core
-- builds that menu with dofile() (fresh each time), so the dofile() call for
-- that one file is wrapped and our entry is inserted into its result.
function M.patchMenu()
    if _G._bookcard_dofile_patched then return end
    _G._bookcard_dofile_patched = true

    local orig_dofile = dofile
    _G.dofile = function(path, ...)
        local result = orig_dofile(path, ...)
        if type(path) == "string" and path:match("ui/elements/screensaver_menu%.lua$")
                and type(result) == "table" then
            local entry = {
                text = _("Book card"),
                keep_menu_open = true,
                radio = true,
                checked_func = M.isSelected,
                callback = function()
                    G_reader_settings:saveSetting("screensaver_type", M.TYPE)
                end,
            }

            -- Find the "Wallpaper" radio group and insert before the item
            -- carrying the group's trailing separator.
            local inserted = false
            for _idx, item in ipairs(result) do
                if type(item) == "table" and type(item.sub_item_table) == "table" then
                    local items = item.sub_item_table
                    local insert_at
                    for i, sub in ipairs(items) do
                        if type(sub) == "table" and sub.radio then
                            if sub.separator then insert_at = i; break end
                        elseif i > 1 then
                            insert_at = i
                            break
                        end
                    end
                    if insert_at then
                        table.insert(items, insert_at, entry)
                        inserted = true
                        break
                    end
                end
            end
            if not inserted then table.insert(result, entry) end
        end
        return result
    end
end

function M.install()
    M.patchCore()
    M.patchMenu()
end

return M
