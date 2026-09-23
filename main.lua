--[[
Book Card (plugin entry point)

A sleep screen ("lock screen") that summarises the book you are reading:
cover, title, author, reading time, time left, progress, daily average,
pages per minute, start / finish date, reading streak, reader type and
(optionally) highlight count.

It works both when you lock the device from inside a book (live data) and
from the file manager (data cached the last time a book was open - the file
manager has no reading state of its own).

Files:
  lib/screensaver.lua   hooks KOReader's sleep screen, builds the card
  lib/bookdata.lua      collects the numbers (live / from cache)
  lib/cache.lua         persistent cache of the last book's card + cover
  lib/statsdb.lua       read-only statistics.sqlite3 access
  lib/updater.lua       in-app update from GitHub
  views/about.lua       "About" dialog (title, version, description, link)
  lib/locale.lua        translations (locale/*.po) and formatting
  lib/prefs.lua         settings access
  lib/colors.lua        user-configurable text/battery colors ("Colors" menu)
  lib/fonts.lua         user-configurable fonts ("Fonts" menu)
  views/card_view.lua   the card layout + preview popup
  widgets/              statistic cell, framed cover, svg icon,
                        color wheel (used by the Colors menu)
  icons/                svg icons for the bottom row
  locale/               en.po, hu.po

Modules are loaded with loadfile() (see pluginutil.lua) because this
plugin's directory is not on package.path; dependencies are passed in as one
named table.
]]--

local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")

local PluginUtil
do
    local src = debug.getinfo(1, "S").source
    local dir = src:match("^@(.*/)") or "./"
    local chunk, err = loadfile(dir .. "pluginutil.lua")
    if not chunk then
        error(("Book Card: failed to load pluginutil.lua: %s"):format(tostring(err)))
    end
    PluginUtil = chunk()
end
local loadModule = PluginUtil.load

local Prefs   = loadModule("lib/prefs.lua")
local StatsDb = loadModule("lib/statsdb.lua")
local Cache   = loadModule("lib/cache.lua")
local Locale  = loadModule("lib/locale.lua", { PluginUtil = PluginUtil })
local Data    = loadModule("lib/bookdata.lua", { StatsDb = StatsDb, Cache = Cache, Locale = Locale })
local Colors  = loadModule("lib/colors.lua", { PluginUtil = PluginUtil, Locale = Locale, Prefs = Prefs })
local Fonts   = loadModule("lib/fonts.lua",  { PluginUtil = PluginUtil, Locale = Locale, Prefs = Prefs })
local Wallpaper = loadModule("lib/wallpaper.lua", { PluginUtil = PluginUtil, Locale = Locale, Prefs = Prefs })
local CardView = loadModule("views/card_view.lua", {
    PluginUtil = PluginUtil, Locale = Locale, Prefs = Prefs, Cache = Cache, Colors = Colors, Fonts = Fonts,
    Wallpaper = Wallpaper,
})
local Updater = loadModule("lib/updater.lua", { Locale = Locale, PluginUtil = PluginUtil })
local About   = loadModule("views/about.lua", { Locale = Locale, Updater = Updater })
local Sleep = loadModule("lib/screensaver.lua", {
    Locale = Locale, Data = Data, Cache = Cache, CardView = CardView, Prefs = Prefs,
})
local PngExport = loadModule("lib/pngexport.lua", { Locale = Locale, Prefs = Prefs, Sleep = Sleep })

local _ = Locale._

local PREV_TYPE_SETTING = "bookcard_previous_screensaver_type"

-- Update settings (same keys layout as the Reading Insights updater).
local DEV_BRANCH_SETTING          = "bookcard_dev_branch"
local LAST_INSTALL_SOURCE_SETTING = "bookcard_last_install_source"
local CHECK_UPDATES_SETTING       = "bookcard_check_updates"

local function readDevBranch() return Prefs.read(DEV_BRANCH_SETTING, "") end
local function saveDevBranch(branch) Prefs.save(DEV_BRANCH_SETTING, branch) end
local function readLastInstallSource() return Prefs.read(LAST_INSTALL_SOURCE_SETTING, "release") end
local function saveLastInstallSource(source) Prefs.save(LAST_INSTALL_SOURCE_SETTING, source) end
local function readCheckUpdates() return Prefs.readBool(CHECK_UPDATES_SETTING, false) end

local BookCard = WidgetContainer:extend{
    name = "bookcard",
    is_doc_only = false,
}

function BookCard:init()
    -- Both instantiations (reader + file manager) call these; each is a
    -- no-op after the first.
    Sleep.install()
    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()
    -- Silent update check at start-up (opt-in, at most once an hour).
    self:backgroundUpdateCheck()
    -- Image export (see lib/pngexport.lua): resume the periodic refresh if
    -- it was left on from a previous session. Guarded by a global flag so
    -- only one of the reader/file-manager instantiations runs the timer.
    self:_startImageExportTimer()
    -- Force this plugin's entry to the 2nd slot of the Tools menu (both in
    -- Reader view and in the File manager), same technique as Reading
    -- Insights (which uses slot 1). Wrapped in scheduleIn(1, ...) so it
    -- runs after every plugin has had a chance to register its own
    -- menu_order entry.
    UIManager:scheduleIn(1, function()
        local TOOLS_SLOT = 2
        local function forceSlot(module_path_new, module_path_old)
            local ok_new, order_module = pcall(require, module_path_new)
            if not ok_new then
                local ok_old, res_old = pcall(require, module_path_old)
                if ok_old then order_module = res_old end
            end
            if order_module then
                if order_module.insertSorted then
                    order_module.insertSorted("tools", "bookcard", TOOLS_SLOT)
                elseif order_module.tools then
                    for i, v in ipairs(order_module.tools) do
                        if v == "bookcard" then
                            table.remove(order_module.tools, i)
                            break
                        end
                    end
                    table.insert(order_module.tools, TOOLS_SLOT, "bookcard")
                end
            end
        end

        forceSlot("ui/elements/reader_menu_order", "apps/reader/modules/readermenuorder")
        forceSlot("ui/elements/filemanager_menu_order", "apps/filemanager/modules/filemanagermenuorder")
    end)
end

function BookCard:onResume()
    -- Undo any orientation forced for the sleep screen before anything
    -- else redraws, then check for updates as before.
    Sleep.restoreOrientation()
    self:backgroundUpdateCheck()
end

function BookCard:onSuspend()
    -- Refresh the exported image right before sleeping, same moment Ink
    -- Stain Wallpaper refreshes its own - the freshest possible picture for
    -- whatever ends up showing (KOReader's own sleep screen elsewhere, or
    -- just this file waiting to be picked up as an Android wallpaper).
    if not PngExport.isEnabled() then return end
    local ok, err = PngExport.write(self.ui)
    if not ok then logger.warn("BookCard: image export on suspend failed:", err) end
end

-- ---------------------------------------------------------------------------
-- Image export (lib/pngexport.lua): a PNG of the card, refreshed on a
-- timer and on the events below, for use outside KOReader's own sleep
-- screen (chiefly: setting it as the Android system/lock-screen wallpaper).
-- ---------------------------------------------------------------------------
function BookCard:refreshExportedImage(quiet)
    local ok, err = PngExport.write(self.ui)
    if not quiet then
        if ok then
            UIManager:show(InfoMessage:new{ text = _("Image updated."), timeout = 2 })
        else
            UIManager:show(InfoMessage:new{
                text = err or _("Could not update the image."),
                timeout = 3,
            })
        end
    elseif not ok then
        logger.warn("BookCard: image export failed:", err)
    end
    return ok
end

-- The timer always renders from the cache (ui = nil), same source the
-- sleep screen itself falls back to outside a book - so it never holds on
-- to a ReaderUI/FileManager instance across the interval.
function BookCard:_scheduleImageExportTimer()
    if not PngExport.isEnabled() then
        _G._bookcard_export_timer_active = false
        return
    end
    UIManager:scheduleIn(PngExport.interval(), function()
        if not PngExport.isEnabled() then
            _G._bookcard_export_timer_active = false
            return
        end
        local ok, err = PngExport.write(nil)
        if not ok then logger.warn("BookCard: periodic image export failed:", err) end
        self:_scheduleImageExportTimer()
    end)
end

function BookCard:_startImageExportTimer()
    if _G._bookcard_export_timer_active then return end
    if not PngExport.isEnabled() then return end
    _G._bookcard_export_timer_active = true
    self:_scheduleImageExportTimer()
end

function BookCard:onDispatcherRegisterActions()
    Dispatcher:registerAction("bookcard_preview", {
        category = "none",
        event = "ShowBookCard",
        title = _("Book Card: preview"),
        general = true,
    })
end

-- Snapshot the card whenever a book is closed, so the file manager (which
-- has no reading state) can show it from the cache afterwards. Needed both
-- for the native sleep screen and for image export - the two are
-- independent, since image export is the one that matters on Android,
-- where the native sleep screen never appears at all (see lib/pngexport.lua).
function BookCard:onCloseDocument()
    if not (Sleep.isSelected() or PngExport.isEnabled()) then return end
    local ok, err = pcall(function()
        local card = Data.collectLive(self.ui)
        if card then Cache.save(card) end
    end)
    if not ok then logger.warn("BookCard: cache refresh on close failed:", err) end
    if PngExport.isEnabled() then
        self:refreshExportedImage(true)
    end
end

function BookCard:onShowBookCard()
    local ok, widget_or_err = pcall(function()
        local card = Sleep.buildCard(self.ui)
        if not card then return nil end
        return CardView.Popup:new{ card = card }
    end)
    if ok and widget_or_err then
        UIManager:show(widget_or_err, "full")
    else
        if not ok then logger.warn("BookCard: preview failed:", widget_or_err) end
        UIManager:show(InfoMessage:new{
            text = _("No book data yet. Open a book and read a few pages first."),
        })
    end
    return true
end

local function toggleSetting(key, default)
    return {
        checked_func = function() return Prefs.readBool(key, default) end,
        callback = function() Prefs.save(key, not Prefs.readBool(key, default)) end,
        keep_menu_open = true,
    }
end

-- ---------------------------------------------------------------------------
-- Updates (mirrors Reading Insights' Updates menu)
-- ---------------------------------------------------------------------------
function BookCard:checkForUpdates()
    local branch = readDevBranch()
    if branch ~= "" then
        Updater.installBranch(branch, function()
            saveLastInstallSource("branch:" .. branch)
        end)
    else
        Updater.check(function()
            saveLastInstallSource("release")
        end)
    end
end

function BookCard:editDevBranch(touchmenu_instance)
    local InputDialog = require("ui/widget/inputdialog")
    local dlg
    dlg = InputDialog:new{
        title       = _("Development branch"),
        input       = readDevBranch(),
        input_hint  = _("Branch name (leave empty for stable)"),
        buttons = {{
            {
                text     = _("Cancel"),
                id       = "close",
                callback = function() UIManager:close(dlg) end,
            },
            {
                text             = _("Save"),
                is_enter_default = true,
                callback         = function()
                    local raw = dlg:getInputText() or ""
                    local trimmed = raw:gsub("^%s+", ""):gsub("%s+$", "")
                    saveDevBranch(trimmed)
                    UIManager:close(dlg)
                    if touchmenu_instance and touchmenu_instance.updateItems then
                        touchmenu_instance:updateItems()
                    end
                end,
            },
        }},
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

function BookCard:resetToStableRelease()
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = _("This will clear the development branch setting and install the latest stable release of Book Card, then restart KOReader. Continue?"),
        ok_text = _("Reset"),
        ok_callback = function()
            saveDevBranch("")
            Updater.installLatestStable(function()
                saveLastInstallSource("release")
            end)
        end,
    })
end

-- Silent poll: at most once an hour, only when the user opted in.
function BookCard:backgroundUpdateCheck()
    if not readCheckUpdates() then return end
    Updater.checkBackground(function(ver)
        local Notification = require("ui/widget/notification")
        Notification:notify(_("Book Card update available: v") .. ver,
            Notification.SOURCE_ALWAYS_SHOW)
    end)
end

function BookCard:_updateSubItems()
    local outer = self
    return {
        {
            text         = _("Notify on wake when update available"),
            checked_func = function() return readCheckUpdates() end,
            callback     = function() Prefs.save(CHECK_UPDATES_SETTING, not readCheckUpdates()) end,
            keep_menu_open = true,
        },
        {
            text_func = function()
                local current   = Updater.getInstalledVersion()
                local available = Updater.getAvailableUpdate()
                local source    = readLastInstallSource()
                local source_suffix = ""
                if source ~= "release" then
                    local branch = source:match("^branch:(.+)$") or source
                    source_suffix = " (branch: " .. branch .. ")"
                end
                if available then
                    return _("Update available") .. ": v" .. current .. source_suffix
                        .. " \xE2\x86\x92 v" .. available
                end
                return _("Installed version") .. ": v" .. current .. source_suffix
            end,
            keep_menu_open = true,
            callback = function() outer:checkForUpdates() end,
        },
        {
            text = _("Developer updates"),
            sub_item_table = {
                {
                    text_func = function()
                        local b = readDevBranch()
                        if b == "" then return _("Development branch") end
                        return _("Development branch") .. ": " .. b
                    end,
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        outer:editDevBranch(touchmenu_instance)
                    end,
                },
                {
                    text_func = function()
                        local b = readDevBranch()
                        if b == "" then return _("Check for updates") end
                        return _("Install branch") .. ": " .. b
                    end,
                    keep_menu_open = true,
                    callback = function() outer:checkForUpdates() end,
                },
                {
                    text           = _("Reset to latest stable release"),
                    keep_menu_open = true,
                    callback       = function() outer:resetToStableRelease() end,
                },
                {
                    text_func = function()
                        local current = Updater.getInstalledVersion()
                        local source  = readLastInstallSource()
                        if source == "release" then
                            return _("Installed: v") .. current .. " (release)"
                        end
                        local branch = source:match("^branch:(.+)$") or source
                        return _("Installed: v") .. current .. " (branch: " .. branch .. ")"
                    end,
                    enabled_func   = function() return false end,
                    keep_menu_open = true,
                },
            },
        },
    }
end

-- ---------------------------------------------------------------------------
-- Image export submenu (see lib/pngexport.lua)
-- ---------------------------------------------------------------------------
function BookCard:_imageExportSubItems()
    local outer = self
    return {
        {
            text = _("Save as image, kept up to date"),
            checked_func = PngExport.isEnabled,
            keep_menu_open = true,
            callback = function()
                local turning_on = not PngExport.isEnabled()
                PngExport.setEnabled(turning_on)
                if turning_on then
                    outer:_startImageExportTimer()
                    outer:refreshExportedImage(true)
                end
            end,
            separator = true,
        },
        {
            text = _("On Android, KOReader's own sleep screen (above) never shows, "
                .. "because locking the screen hands over to Android's own lock "
                .. "screen instead. Turn this on and Book Card keeps a picture of "
                .. "the card on disk, refreshed automatically; set that picture as "
                .. "your Android wallpaper the normal way (from the Photos/Gallery "
                .. "app, or a wallpaper-changer app pointed at the folder below)."),
            enabled = false,
            separator = true,
        },
        {
            text_func = function()
                return _("Refresh interval") .. ": " .. PngExport.intervalLabel()
            end,
            enabled_func = PngExport.isEnabled,
            sub_item_table_func = function() return PngExport.buildIntervalMenu() end,
        },
        {
            text_func = function()
                local custom = Prefs.read(PngExport.SETTING_SAVE_PATH, "")
                if type(custom) == "string" and custom ~= "" then
                    return _("Also copy to folder") .. ": " .. custom
                end
                return _("Also copy to a shared folder\xE2\x80\xA6")
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                UIManager:show(PngExport.buildPathChooser(function(path)
                    outer:refreshExportedImage(false)
                    UIManager:show(InfoMessage:new{
                        text = Locale.tpl(
                            _("Image will also be copied to:\n{path}\n\nOn Android, point your system wallpaper picker (or a wallpaper-changer app) at this folder."),
                            { path = path }),
                        timeout = 6,
                    })
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end))
            end,
        },
        {
            text = _("Stop copying to that extra folder"),
            enabled_func = function() return PngExport.customFile() ~= nil end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                PngExport.clearCustomPath()
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
            separator = true,
        },
        {
            text = _("Save image now"),
            keep_menu_open = true,
            callback = function() outer:refreshExportedImage(false) end,
        },
        {
            text_func = function()
                return Locale.tpl(_("Image saved to: {path}"), { path = PngExport.outputFile() })
            end,
            enabled = false,
        },
    }
end

-- ---------------------------------------------------------------------------
-- Menu: Tools > Book Card
-- ---------------------------------------------------------------------------
local function themeItem(label, value)
    return {
        text = label,
        radio = true,
        checked_func = function() return Prefs.read(CardView.SETTING_THEME, "auto") == value end,
        callback = function() Prefs.save(CardView.SETTING_THEME, value) end,
        keep_menu_open = true,
    }
end

local function gapItem(label, value)
    return {
        text = label,
        radio = true,
        checked_func = function() return Prefs.read(CardView.SETTING_GAP, "small") == value end,
        callback = function() Prefs.save(CardView.SETTING_GAP, value) end,
        keep_menu_open = true,
    }
end

local function orientationItem(label, value)
    return {
        text = label,
        radio = true,
        checked_func = function() return Prefs.read(CardView.SETTING_ORIENTATION, "default") == value end,
        callback = function() Prefs.save(CardView.SETTING_ORIENTATION, value) end,
        keep_menu_open = true,
    }
end

local function backdropGroupingItem(label, value)
    return {
        text = label,
        radio = true,
        checked_func = function()
            return Prefs.read(CardView.SETTING_BACKDROP_GROUPING, "individual") == value
        end,
        callback = function() Prefs.save(CardView.SETTING_BACKDROP_GROUPING, value) end,
        keep_menu_open = true,
    }
end

function BookCard:addToMainMenu(menu_items)
    local battery = toggleSetting(CardView.SETTING_BATTERY, true)
    battery.text = _("Show battery")
    local streak = toggleSetting(CardView.SETTING_STREAK, true)
    streak.text = _("Show reading streak")
    local rtype = toggleSetting(CardView.SETTING_READER_TYPE, true)
    rtype.text = _("Show reader type")
    local rounded = toggleSetting(CardView.SETTING_ROUNDED, true)
    rounded.text = _("Rounded cover corners")

    -- Statistics-column rows, in the order they are drawn on the card.
    local stat_progress = toggleSetting(CardView.SETTING_STAT_PROGRESS, true)
    stat_progress.text = _("Progress")
    local stat_pages = toggleSetting(CardView.SETTING_STAT_PAGES, true)
    stat_pages.text = _("Pages")
    local stat_reading_time = toggleSetting(CardView.SETTING_STAT_READING_TIME, true)
    stat_reading_time.text = _("Reading Time")
    local stat_time_left = toggleSetting(CardView.SETTING_STAT_TIME_LEFT, true)
    stat_time_left.text = _("Time Left")
    local stat_daily_avg = toggleSetting(CardView.SETTING_STAT_DAILY_AVG, true)
    stat_daily_avg.text = _("Daily Avg")
    local stat_daily_avg_pages = toggleSetting(CardView.SETTING_STAT_DAILY_AVG_PAGES, false)
    stat_daily_avg_pages.text = _("Daily Avg (pages)")
    local stat_pages_per_min = toggleSetting(CardView.SETTING_STAT_PAGES_PER_MIN, true)
    stat_pages_per_min.text = _("Pages/Min")
    local stat_started = toggleSetting(CardView.SETTING_STAT_STARTED, true)
    stat_started.text = _("Started")
    local stat_finish = toggleSetting(CardView.SETTING_STAT_FINISH, true)
    stat_finish.text = _("Est. Finish")
    local highlights = toggleSetting(CardView.SETTING_HIGHLIGHTS, false)
    highlights.text = _("Highlights")

    menu_items.bookcard = {
        text = _("Book Card"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Use as sleep screen"),
                checked_func = Sleep.isSelected,
                keep_menu_open = true,
                callback = function()
                    if Sleep.isSelected() then
                        -- Switch back to whatever was used before.
                        G_reader_settings:saveSetting("screensaver_type",
                            Prefs.read(PREV_TYPE_SETTING, "cover"))
                    else
                        Prefs.save(PREV_TYPE_SETTING,
                            G_reader_settings:readSetting("screensaver_type") or "cover")
                        G_reader_settings:saveSetting("screensaver_type", Sleep.TYPE)
                    end
                end,
                separator = true,
            },
            {
                text = _("Updates"),
                sub_item_table_func = function() return self:_updateSubItems() end,
            },
            {
                text = _("About"),
                keep_menu_open = true,
                callback = function() About.show() end,
                separator = true,
            },
            {
                text = _("Preview"),
                callback = function() self:onShowBookCard() end,
                keep_menu_open = true,
                separator = true,
            },
            {
                text = _("Background"),
                sub_item_table = (function()
                    local dark_item = themeItem(_("Always dark"), "dark")
                    dark_item.separator = true
                    return {
                        themeItem(_("Follow night mode"), "auto"),
                        themeItem(_("Always light"), "light"),
                        dark_item,
                        {
                            text_func = function()
                                return _("Wallpaper") .. ": " .. Wallpaper.currentLabel()
                            end,
                            sub_item_table_func = function() return Wallpaper.buildPickerMenu() end,
                        },
                        {
                            text_func = function()
                                return _("Text background opacity") .. ": " .. Wallpaper.opacityLabel()
                            end,
                            sub_item_table_func = function() return Wallpaper.buildOpacityMenu() end,
                        },
                        {
                            text = _("Text background grouping"),
                            sub_item_table = {
                                backdropGroupingItem(_("Individually (default)"), "individual"),
                                backdropGroupingItem(_("Grouped (battery / stats / title+author+series / streak / reader)"), "grouped"),
                            },
                        },
                    }
                end)(),
            },
            {
                text = _("Cover"),
                sub_item_table = {
                    rounded,
                    {
                        text = _("Cover shadow"),
                        checked_func = function()
                            return Prefs.readBool(CardView.SETTING_COVER_SHADOW, true)
                        end,
                        callback = function()
                            Prefs.save(CardView.SETTING_COVER_SHADOW,
                                not Prefs.readBool(CardView.SETTING_COVER_SHADOW, true))
                        end,
                        keep_menu_open = true,
                    },
                    {
                        text = _("Cover / statistics spacing"),
                        sub_item_table = {
                            gapItem(_("Small (default)"), "small"),
                            gapItem(_("Large"), "large"),
                        },
                    },
                },
            },
            {
                text = _("Colors"),
                sub_item_table_func = function() return Colors.buildMenu() end,
            },
            {
                text = _("Fonts"),
                sub_item_table_func = function() return Fonts.buildMenu() end,
                separator = true,
            },
            {
                text = _("Card elements"),
                sub_item_table = {
                    battery,
                    streak,
                    rtype,
                    {
                        text = _("Statistics"),
                        sub_item_table = {
                            stat_progress,
                            stat_pages,
                            stat_reading_time,
                            stat_time_left,
                            stat_daily_avg,
                            stat_daily_avg_pages,
                            stat_pages_per_min,
                            stat_started,
                            stat_finish,
                            highlights,
                        },
                    },
                },
                separator = true,
            },
            {
                text = _("Advanced Settings"),
                sub_item_table = {
                    {
                        text = _("Orientation"),
                        sub_item_table = {
                            orientationItem(_("Default"), "default"),
                            orientationItem(_("Force portrait"), "portrait"),
                            orientationItem(_("Force landscape"), "landscape"),
                        },
                    },
                    {
                        text = _("Margins"),
                        sub_item_table_func = function() return CardView.buildMarginsMenu() end,
                    },
                    {
                        text = _("Image export (for Android wallpaper)"),
                        sub_item_table_func = function() return self:_imageExportSubItems() end,
                    },
                    {
                        text = _("Clear cached data"),
                        callback = function()
                            Cache.clear()
                            UIManager:show(InfoMessage:new{ text = _("Cached data cleared."), timeout = 2 })
                        end,
                    },
                },
            },
        },
    }
end

return BookCard
