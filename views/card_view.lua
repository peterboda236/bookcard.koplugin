--[[
Book card - the card itself.

  CardView.build(card, opts)   full-screen widget showing `card`
  CardView.Popup               tap-to-close wrapper, used by "Preview"

Layout (portrait; landscape uses the same scheme):

    +---------------------------------------+
    |                              [bat] 87%|   battery (optional), above
    | +-------------+                   ...%|   both the cover and the
    | |             |             12h 51 min |   statistics column
    | |    cover    |            Reading Time|   Progress, top of the
    | |  (framed,   |                  ...   |   statistics column,
    | |   rounded)  |             Sep 13     |   right-aligned; both the
    | +-------------+          Finished Date |   cover and the last stat
    | Title                                  |   row start/end level with
    | Author                                 |   each other
    | Series / #1                            |
    | flame 9 day streak . 3 week streak  moon Night Reader
    +---------------------------------------+

Everything is sized from the actual screen. The cover takes all the height
the text below it leaves, and the width up to the statistics column.

Colours: the card follows KOReader's night mode (black background, white
text) unless the "Background" setting forces light or dark. KOReader's night
mode inverts the whole panel, so a card painted "normally" already comes out
dark there; `flip` below is true only when the painted colours have to be
reversed to get the requested look.
]]--

local deps = ...
local Locale    = deps.Locale
local Prefs     = deps.Prefs
local PluginDir = deps.PluginUtil.dir
local Cache     = deps.Cache
local Colors    = deps.Colors
local Fonts     = deps.Fonts
local Wallpaper = deps.Wallpaper

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local FrameContainer = require("ui/widget/container/framecontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local SortWidget = require("ui/widget/sortwidget")
local SpinWidget = require("ui/widget/spinwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local logger = require("logger")
local Screen = Device.screen

local StatCell      = deps.PluginUtil.load("widgets/statcell.lua")
local CoverFrame    = deps.PluginUtil.load("widgets/coverframe.lua")
local SvgIcon       = deps.PluginUtil.load("widgets/svgicon.lua")

local _  = Locale._
local N_ = Locale.N_

local M = {}

-- Settings.
M.SETTING_BATTERY     = "bookcard_show_battery"          -- default on
M.SETTING_STREAK      = "bookcard_show_streak"           -- default on
M.SETTING_READER_TYPE = "bookcard_show_reader_type"      -- default on
M.SETTING_ROUNDED     = "bookcard_rounded_corners"       -- default on
M.SETTING_THEME       = "bookcard_theme"                 -- "auto" (default) | "light" | "dark"
M.SETTING_GAP         = "bookcard_cover_stats_gap"       -- "small" (default) | "large"
M.SETTING_COVER_SHADOW = "bookcard_cover_shadow"          -- default on
M.SETTING_HIGHLIGHTS   = "bookcard_show_highlights"      -- default OFF
M.SETTING_QUOTE        = "bookcard_show_quote"           -- default OFF - a
                                                          -- random highlighted
                                                          -- quote under
                                                          -- title/author/series
M.SETTING_ORIENTATION  = "bookcard_orientation"          -- "default" (current behaviour) | "portrait" | "landscape"
M.SETTING_LAYOUT       = "bookcard_layout"               -- "side" (default: cover beside the
                                                          -- statistics column) | "centered" (cover
                                                          -- centered on its own, title/author/series/
                                                          -- quote below it, statistics in a 2-column
                                                          -- grid underneath that)
M.SETTING_BACKDROP_GROUPING = "bookcard_backdrop_grouping" -- "individual" | "grouped" (default) - only
                                                          -- matters with a wallpaper + text background
                                                          -- opacity > 0; see placeText()/flushGroup() below

-- Top/bottom/side padding (unscaled units, same convention as S() below -
-- see pad_top/pad_bottom/pad_x in M.build). User-configurable so content
-- can be pulled in from curved/notched screen edges where the corners
-- aren't fully visible; the defaults reproduce the previous fixed layout
-- (side padding, and top padding, were already 28/22 - only the bottom
-- default changes here, from 26 to 22, to match).
M.SETTING_MARGIN_TOP    = "bookcard_margin_top"
M.SETTING_MARGIN_BOTTOM = "bookcard_margin_bottom"
M.SETTING_MARGIN_SIDE   = "bookcard_margin_side"
M.DEFAULT_MARGIN_TOP    = 22
M.DEFAULT_MARGIN_BOTTOM = 22
M.DEFAULT_MARGIN_SIDE   = 28
M.MARGIN_MIN = 0
M.MARGIN_MAX = 160

-- Individual statistics-column rows, in the order they are drawn (all
-- default on, except SETTING_HIGHLIGHTS above, which stays off by default).
M.SETTING_STAT_PROGRESS      = "bookcard_stat_progress"
M.SETTING_STAT_PAGES         = "bookcard_stat_pages"
M.SETTING_STAT_READING_TIME  = "bookcard_stat_reading_time"
M.SETTING_STAT_TIME_LEFT     = "bookcard_stat_time_left"
M.SETTING_STAT_DAILY_AVG     = "bookcard_stat_daily_avg"
M.SETTING_STAT_DAILY_AVG_PAGES = "bookcard_stat_daily_avg_pages"  -- default OFF
M.SETTING_STAT_PAGES_PER_MIN = "bookcard_stat_pages_per_min"
M.SETTING_STAT_STARTED       = "bookcard_stat_started"
M.SETTING_STAT_FINISH        = "bookcard_stat_finish"
M.SETTING_STAT_TODAY_TIME    = "bookcard_stat_today_time"       -- default OFF
M.SETTING_STAT_ALL_BOOKS_TIME = "bookcard_stat_all_books_time"  -- default OFF
M.SETTING_STAT_CHAPTER_PAGES_LEFT = "bookcard_stat_chapter_pages_left"  -- default OFF
M.SETTING_STAT_CHAPTER_TIME_LEFT  = "bookcard_stat_chapter_time_left"  -- default OFF

-- The reader's chosen order for the statistics rows above (a list of the
-- `id`s used in STAT_DEFS below). Unset until the reader opens "Reorder"
-- for the first time; see M.getStatOrder().
M.SETTING_STAT_ORDER = "bookcard_stat_order"

local DASH = "\u{2013}"  -- en dash: "no value"

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------
local function S(n)
    return Screen:scaleBySize(n)
end

-- Font sizes are given in KOReader's unscaled units (Font:getFace scales).
local function face(name, size)
    return Font:getFace(name, math.max(6, math.floor(size)))
end

-- Painted colours for the requested look (see the header comment).
local function palette()
    local mode = Prefs.read(M.SETTING_THEME, "auto")
    local night = Screen.night_mode == true
    local dark = (mode == "dark") or (mode == "auto" and night)
    local flip = dark ~= night
    return {
        flip = flip,
        bg = flip and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE,
        fg = flip and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK,
    }
end

local function icon(name, size, pal)
    local path = PluginDir .. "icons/" .. name .. ".svg"
    local ok, widget = pcall(function()
        return SvgIcon:new{ file = path, size = size, inverted = pal.flip }
    end)
    if ok then return widget end
    logger.warn("BookCard: icon failed:", name, widget)
    return nil
end

local READER_TYPES = {
    night     = { icon = "moon",    label = "Night Reader" },
    morning   = { icon = "sunrise", label = "Morning Reader" },
    afternoon = { icon = "sun",     label = "Afternoon Reader" },
    evening   = { icon = "sunset",  label = "Evening Reader" },
}

local function text(txt, text_face, color, max_width)
    return TextWidget:new{ text = txt, face = text_face, fgcolor = color, max_width = max_width }
end

-- Icon + text side by side, vertically centred on each other. The icon
-- itself always follows the theme (pal, for its night-mode inversion) -
-- only the text takes a custom `color` from the Colors menu.
local function iconLabel(icon_name, txt, text_face, icon_size, pal, color)
    local group = HorizontalGroup:new{ align = "center" }
    local ic = icon_name and icon(icon_name, icon_size, pal)
    if ic then
        table.insert(group, ic)
        table.insert(group, HorizontalSpan:new{ width = math.floor(icon_size * 0.35) })
    end
    table.insert(group, text(txt, text_face, color))
    return group
end

-- ---------------------------------------------------------------------------
-- Cover (framed, optionally rounded)
-- ---------------------------------------------------------------------------
-- `max_w` x `max_h` is the box for the OUTER size (frame included).
-- Returns the widget and its outer width and height.
local function buildCover(card, max_w, max_h, pal, shadow_offset, restore)
    local border = math.max(2, S(1))
    local radius = Prefs.readBool(M.SETTING_ROUNDED, true) and S(4) or 0
    local box_w, box_h = max_w - 2 * border, max_h - 2 * border
    local soff = shadow_offset or 0

    local function framed(inner, inner_w, inner_h)
        local outer_w, outer_h = inner_w + 2 * border, inner_h + 2 * border
        return CoverFrame:new{
            inner  = inner,
            width  = outer_w, height = outer_h,
            border = border,  radius = radius,
            bg     = pal.bg,  fg     = pal.fg,
            -- shadow awareness: BR corner restores shadow grey instead of bg
            shadow_color  = soff > 0 and CoverFrame.SHADOW_GRAY or nil,
            shadow_offset = soff,
            -- over a wallpaper, cut corners reveal the picture instead of a
            -- flat bg square (see Wallpaper.restore)
            restore = restore,
        }, outer_w, outer_h
    end

    if card.has_cover ~= false and Cache.hasCover() then
        local ok, widget, w, h = pcall(function()
            local RenderImage = require("ui/renderimage")
            local bb = RenderImage:renderImageFile(Cache.coverPath(), false, nil, nil)
            if not bb then error("cover could not be decoded") end
            local scale = math.min(box_w / bb:getWidth(), box_h / bb:getHeight())
            local iw = math.max(1, math.floor(bb:getWidth() * scale))
            local ih = math.max(1, math.floor(bb:getHeight() * scale))
            local img = ImageWidget:new{
                image = bb,
                image_disposable = true,
                width = iw,
                height = ih,
                scale_factor = 0,
            }
            img:getSize()
            return framed(img, iw, ih)
        end)
        if ok then return widget, w, h end
        logger.warn("BookCard: cover failed:", widget)
    end

    -- No cover: a plain 2:3 placeholder carrying the title.
    local ih = box_h
    local iw = math.floor(ih * 2 / 3)
    if iw > box_w then
        iw = box_w
        ih = math.floor(iw * 3 / 2)
    end
    local inner = FrameContainer:new{
        bordersize = 0, padding = 0, margin = 0,
        background = pal.bg,
        width = iw, height = ih,
        CenterContainer:new{
            dimen = Geom:new{ w = iw, h = ih },
            TextBoxWidget:new{
                text = card.title or "",
                face = face("NotoSans-Bold.ttf", 18),
                width = math.max(10, iw - S(24)),
                alignment = "center",
                fgcolor = pal.fg,
                bgcolor = pal.bg,
            },
        },
    }
    return framed(inner, iw, ih)
end

-- ---------------------------------------------------------------------------
-- The statistics column
--
-- Each entry is one possible row: `setting`/`default` is its on/off toggle
-- (Card elements > Statistics), `label()` names it in that menu, and
-- `build(card, ctx)` returns the {value, label} row to draw, or nil to skip
-- it (e.g. "Pages" needs current_page/total_pages to be known). The table's
-- own order is only the *default* order (and where a future row gets
-- appended); the order actually drawn is M.getStatOrder(), which the reader
-- can change from the "Reorder" entry at the top of that same menu.
-- ---------------------------------------------------------------------------
local STAT_DEFS = {
    {
        id = "progress", setting = M.SETTING_STAT_PROGRESS, default = true,
        label = function() return _("Progress") end,
        build = function(card, ctx)
            return { ctx.percent and (tostring(ctx.percent) .. "%") or DASH, _("Progress") }
        end,
    },
    {
        id = "pages", setting = M.SETTING_STAT_PAGES, default = true,
        label = function() return _("Pages") end,
        build = function(card, ctx)
            if not (card.current_page and card.total_pages) then return nil end
            return { string.format("%d / %d", card.current_page, card.total_pages), _("Pages") }
        end,
    },
    {
        id = "reading_time", setting = M.SETTING_STAT_READING_TIME, default = true,
        label = function() return _("Reading Time") end,
        build = function(card, ctx)
            return { ctx.dur(card.total_time), _("Reading Time") }
        end,
    },
    {
        id = "time_left", setting = M.SETTING_STAT_TIME_LEFT, default = true,
        label = function() return _("Time Left") end,
        build = function(card, ctx)
            return { card.finished and DASH or ctx.dur(card.time_left_secs), _("Time Left") }
        end,
    },
    {
        -- Off by default: pages left in the CURRENT chapter (not the whole
        -- book - see "pages"/"time_left" above for that). Needs a live
        -- document (ui.toc:getChapterPagesLeft) - see bookdata.lua's
        -- collectLive; nil (shown as DASH) when the card was rebuilt from
        -- the sidecar/statistics DB with no book open.
        id = "chapter_pages_left", setting = M.SETTING_STAT_CHAPTER_PAGES_LEFT, default = false,
        label = function() return _("Ch. Pages Left") end,
        build = function(card, ctx)
            local left = card.chapter_pages_left
            local left_txt = left and tostring(math.floor(left + 0.5)) or DASH
            return { left_txt, _("Ch. Pages Left") }
        end,
    },
    {
        -- Off by default: time left in the CURRENT chapter, same
        -- pages-left * avg_time formula as the whole-book "time_left" row.
        -- Same live-document caveat as chapter_pages_left above.
        id = "chapter_time_left", setting = M.SETTING_STAT_CHAPTER_TIME_LEFT, default = false,
        label = function() return _("Ch. Time Left") end,
        build = function(card, ctx)
            return { ctx.dur(card.chapter_time_left_secs), _("Ch. Time Left") }
        end,
    },
    {
        id = "daily_avg", setting = M.SETTING_STAT_DAILY_AVG, default = true,
        label = function() return _("Daily Avg") end,
        build = function(card, ctx)
            return { ctx.dur(card.daily_avg_secs), _("Daily Avg") }
        end,
    },
    {
        -- Same "Daily Avg" row, but in pages instead of time - off by
        -- default (same reasoning as Highlights: a second row for the same
        -- idea should be something the reader opts into, not something
        -- added for them).
        id = "daily_avg_pages", setting = M.SETTING_STAT_DAILY_AVG_PAGES, default = false,
        label = function() return _("Daily Avg (pages)") end,
        build = function(card, ctx)
            local pages_txt = DASH
            if card.daily_avg_pages then
                local n = math.floor(card.daily_avg_pages + 0.5)
                pages_txt = string.format(N_("%d page", "%d pages", n), n)
            end
            return { pages_txt, _("Daily Avg") }
        end,
    },
    {
        id = "pages_per_min", setting = M.SETTING_STAT_PAGES_PER_MIN, default = true,
        label = function() return _("Pages/Min") end,
        build = function(card, ctx)
            local ppm = card.pages_per_min
            local ppm_text = DASH
            if ppm then ppm_text = Locale.formatNumber(ppm, ppm >= 1 and 1 or 2) end
            return { ppm_text, _("Pages/Min") }
        end,
    },
    {
        -- "Started": 1 day ago reads as "Yesterday", 2+ as "N days ago".
        id = "started", setting = M.SETTING_STAT_STARTED, default = true,
        label = function() return _("Started") end,
        build = function(card, ctx)
            local span = card.span_days
            local started = Locale.shortDate(card.started_ts)
            local span_text = DASH
            if span then
                if span == 0 then
                    span_text = _("Today")
                elseif span == 1 then
                    span_text = _("Yesterday")
                else
                    span_text = string.format(N_("%d day ago", "%d days ago", span), span)
                end
            end
            return {
                span_text,
                started and Locale.tpl(_("Started {date}"), { date = started }) or _("Started"),
            }
        end,
    },
    {
        id = "finish", setting = M.SETTING_STAT_FINISH, default = true,
        label = function() return _("Est. Finish") end,
        build = function(card, ctx)
            if card.finished then
                return { Locale.shortDate(card.finished_ts) or DASH, _("Finished Date") }
            end
            return { Locale.shortDate(card.est_finish_ts) or DASH, _("Est. Finish") }
        end,
    },
    {
        -- Off by default: how many highlights this book has.
        id = "highlights", setting = M.SETTING_HIGHLIGHTS, default = false,
        label = function() return _("Highlights") end,
        build = function(card, ctx)
            return { tostring(card.highlights_count or 0), _("Highlights") }
        end,
    },
    {
        -- Off by default: how much of THIS book was read today. The card
        -- caption is just "Read Today" (see all_books_time below); the
        -- longer "(This Book)" form is only used to tell the two rows
        -- apart in the Statistics settings menu.
        id = "today_time", setting = M.SETTING_STAT_TODAY_TIME, default = false,
        menu_label = function() return _("Read Today (This Book)") end,
        label = function() return _("Read Today") end,
        build = function(card, ctx)
            return { ctx.dur(card.today_time), _("Read Today") }
        end,
    },
    {
        -- Off by default: how much was read today across every book, not
        -- just this one. Displayed on the card as "Read Today" too (see
        -- today_time above); "(All Books)" only distinguishes it in the
        -- Statistics settings menu.
        id = "all_books_time", setting = M.SETTING_STAT_ALL_BOOKS_TIME, default = false,
        menu_label = function() return _("Read Today (All Books)") end,
        label = function() return _("Read Today") end,
        build = function(card, ctx)
            return { ctx.dur(card.all_books_time), _("Read Today") }
        end,
    },
}

local STAT_DEFS_BY_ID, DEFAULT_STAT_ORDER = {}, {}
for i = 1, #STAT_DEFS do
    STAT_DEFS_BY_ID[STAT_DEFS[i].id] = STAT_DEFS[i]
    DEFAULT_STAT_ORDER[i] = STAT_DEFS[i].id
end

--- The reader's chosen row order: a list of the `id`s above. Falls back to
--- DEFAULT_STAT_ORDER, and any id missing from a saved order (a new row
--- added by a later version of the plugin, or a stale/corrupt setting) is
--- appended at the end in its default position, so it isn't silently lost
--- and every id is always present exactly once.
function M.getStatOrder()
    local saved = Prefs.read(M.SETTING_STAT_ORDER, nil)
    local order, seen = {}, {}
    if type(saved) == "table" then
        for i = 1, #saved do
            local id = saved[i]
            if STAT_DEFS_BY_ID[id] and not seen[id] then
                order[#order + 1] = id
                seen[id] = true
            end
        end
    end
    for i = 1, #DEFAULT_STAT_ORDER do
        local id = DEFAULT_STAT_ORDER[i]
        if not seen[id] then
            order[#order + 1] = id
            seen[id] = true
        end
    end
    return order
end

--- Persists a new row order (see M.getStatOrder). Unknown ids and repeats
--- are dropped, matching the guards in the getter above.
function M.setStatOrder(order)
    local clean, seen = {}, {}
    for i = 1, #order do
        local id = order[i]
        if STAT_DEFS_BY_ID[id] and not seen[id] then
            clean[#clean + 1] = id
            seen[id] = true
        end
    end
    Prefs.save(M.SETTING_STAT_ORDER, clean)
end

local function statRows(card)
    local ctx = {
        percent = card.percent,
        dur = function(secs) return Locale.formatDuration(secs) or DASH end,
    }
    local rows = {}
    local order = M.getStatOrder()
    for i = 1, #order do
        local def = STAT_DEFS_BY_ID[order[i]]
        if Prefs.readBool(def.setting, def.default) then
            local row = def.build(card, ctx)
            if row then rows[#rows + 1] = row end
        end
    end
    return rows
end

-- ---------------------------------------------------------------------------
-- Build
-- ---------------------------------------------------------------------------
function M.build(card, opts)
    opts = opts or {}
    local W, H = Screen:getWidth(), Screen:getHeight()
    local dp = Screen:scaleBySize(100) / 100          -- px per KOReader unit
    local pal = palette()

    -- Wallpaper (optional): a picture behind the whole card, with a
    -- translucent backdrop panel behind each piece of text so it stays
    -- legible over it. Neither exists unless a picture is actually chosen -
    -- with none set, the card looks exactly as it did before this feature.
    Wallpaper.reroll()   -- "Random" mode: pick a fresh picture for this card
    local wallpaper_bg = Wallpaper.isActive()
        and Wallpaper.bg(W, H, Screen.night_mode and true or false)
        or nil
    local text_bg_opacity = Wallpaper.opacity()
    -- "individual": every line/row gets its own backdrop panel, exactly as
    -- before. "grouped" (default): five logical groups - battery, the
    -- statistics column, title+author+series, the streak, and the morning
    -- reader label - each get ONE panel sized to their own combined
    -- bounding box instead. Battery/streak/reader are already a single
    -- widget each, so this only actually changes the stats column and the
    -- title block (see the newGroup()/groupAdd()/flushGroup() helpers and
    -- their two call sites below).
    local backdrop_grouped = Prefs.read(M.SETTING_BACKDROP_GROUPING, "grouped") == "grouped"

    -- User-configurable (see M.SETTING_MARGIN_TOP/BOTTOM/SIDE): raising any
    -- of these pulls the content in from that edge, e.g. to shift it toward
    -- the middle of the screen on devices whose curved glass hides the very
    -- edge of the display.
    local pad_x = S(Prefs.read(M.SETTING_MARGIN_SIDE, M.DEFAULT_MARGIN_SIDE))
    local pad_top = S(Prefs.read(M.SETTING_MARGIN_TOP, M.DEFAULT_MARGIN_TOP))
    local pad_bottom = S(Prefs.read(M.SETTING_MARGIN_BOTTOM, M.DEFAULT_MARGIN_BOTTOM))
    -- Cover <-> statistics gap: user-configurable ("small" is the default).
    local col_gap = Prefs.read(M.SETTING_GAP, "small") == "large" and S(42) or S(22)

    local show_battery = Prefs.readBool(M.SETTING_BATTERY, true) and Device:hasBattery()
    local days = card.streak_days or 0
    local weeks = card.streak_weeks or 0
    local show_streak = Prefs.readBool(M.SETTING_STREAK, true) and (days > 0 or weeks > 0)
    local reader_type = Prefs.readBool(M.SETTING_READER_TYPE, true)
                        and card.hour_bucket and READER_TYPES[card.hour_bucket]

    local items = {}                                  -- OverlapGroup children
    local function place(widget, x, y)
        widget.overlap_offset = { x, y }
        items[#items + 1] = widget
        return widget
    end

    -- The picture, if any, goes in first so it sits behind everything else.
    if wallpaper_bg then place(wallpaper_bg, 0, 0) end

    -- placeText(widget, x, y): like place(), but first drops a translucent
    -- panel (pal.bg tinted at text_bg_opacity) just behind the widget, sized
    -- to its own footprint plus a small margin - only when a wallpaper is
    -- actually showing and the opacity isn't "Off". Over a plain background
    -- this behaves exactly like place().
    local TEXT_BACKDROP_PAD_H, TEXT_BACKDROP_PAD_V = S(6), S(2)
    -- True only when a translucent backdrop panel is actually being drawn
    -- behind text (wallpaper up, opacity above "Off"). When it is, the
    -- panels behind the title block and the statistics column stick out
    -- past the text they wrap by this padding - so the cover, to look
    -- aligned with them, has to start where the PANELS start, not where
    -- the bare text would have. See cover_left/cover_top below.
    local backdrop_active = wallpaper_bg and text_bg_opacity > 0
    local function placeText(widget, x, y)
        if wallpaper_bg and text_bg_opacity > 0 then
            local size = widget:getSize()
            -- widget:getSize().w is the widget's full box width, which for
            -- a plain TextWidget is already its real text width - but for
            -- the (Mask-wrapped) title it is the whole column width
            -- regardless of how short the title is. When the widget can
            -- tell us its real content width (title only), use that
            -- instead, so its panel hugs the text just like every other
            -- row's does.
            local panel_w = (widget.contentWidth and widget:contentWidth()) or size.w
            local panel = Wallpaper.panel(panel_w + 2 * TEXT_BACKDROP_PAD_H, size.h + 2 * TEXT_BACKDROP_PAD_V,
                                          pal.bg, text_bg_opacity, S(3))
            if panel then place(panel, x - TEXT_BACKDROP_PAD_H, y - TEXT_BACKDROP_PAD_V) end
        end
        return place(widget, x, y)
    end

    -- Grouped-mode helpers: newGroup() collects members without placing
    -- them yet (their combined bounding box isn't known until the last one
    -- is added); flushGroup() then drops a single panel behind that box
    -- (same padding/opacity/radius as placeText()'s per-widget one) and
    -- only then places every member on top of it, in the order they were
    -- added. With no wallpaper, or opacity "Off", this is a no-op wrapper
    -- around plain place() - same as placeText() in that case. The panel's
    -- left/right edges normally come from the members' own bounding box
    -- (group.min_x/max_x); flushGroup's optional x_left/x_right let a
    -- caller override just those two - used by the centered layout below
    -- so every panel there (grouped OR one-per-row/line) always spans the
    -- cover's own width, not just however wide the text happens to be.
    local function newGroup()
        return { members = {} }
    end

    local function groupAdd(group, widget, x, y)
        local size = widget:getSize()
        local w = (widget.contentWidth and widget:contentWidth()) or size.w
        group.members[#group.members + 1] = { widget = widget, x = x, y = y }
        local x2, y2 = x + w, y + size.h
        group.min_x = group.min_x and math.min(group.min_x, x) or x
        group.min_y = group.min_y and math.min(group.min_y, y) or y
        group.max_x = group.max_x and math.max(group.max_x, x2) or x2
        group.max_y = group.max_y and math.max(group.max_y, y2) or y2
    end

    local function flushGroup(group, pad_h, pad_v, x_left, x_right)
        if #group.members == 0 then return end
        -- x_left/x_right (the centered layout's calls) override the panel's
        -- min_x/max_x, but pad_h is still added around them same as always -
        -- callers that want the finished panel to land on a specific outer
        -- edge (e.g. the cover's own edge) pass that edge already shrunk
        -- inward by pad_h, so this adds it back and lands exactly there.
        local min_x = x_left or group.min_x
        local max_x = x_right or group.max_x
        if wallpaper_bg and text_bg_opacity > 0 then
            local panel = Wallpaper.panel(max_x - min_x + 2 * pad_h,
                                           group.max_y - group.min_y + 2 * pad_v,
                                           pal.bg, text_bg_opacity, S(3))
            if panel then place(panel, min_x - pad_h, group.min_y - pad_v) end
        end
        for _i, m in ipairs(group.members) do place(m.widget, m.x, m.y) end
    end

    -- Battery, top right: KOReader's own battery glyph + percentage, same
    -- symbol the stock footer/screensaver use (Device:getPowerDevice():
    -- getBatterySymbol), so it matches the device's native battery icon.
    local battery_h = 0
    if show_battery then
        local powerd = Device:getPowerDevice()
        local ok, capacity = pcall(function() return powerd:getCapacity() end)
        if ok and capacity then
            local battery_color = Colors.getColor("battery", pal.fg)
            local pct_face = Fonts.getFace("battery", 14)
            local batt_symbol = powerd:getBatterySymbol(
                powerd:isCharged(), powerd:isCharging(), capacity)
            local pct_text = text(batt_symbol .. capacity .. "%", pct_face, battery_color)
            local size = pct_text:getSize()
            battery_h = size.h
            placeText(pct_text, W - pad_x - size.w, pad_top)
        end
    end

    -- Bottom row: streaks (left) and reader type (right) ----------------------
    local bottom_color = Colors.getColor("bottom", pal.fg)
    local bottom_face = Fonts.getFace("bottom", 14)
    local icon_size = S(22)
    local bottom_text_h = TextWidget:new{ text = "Ag", face = bottom_face }:getSize().h
    local line_h = math.max(icon_size, bottom_text_h)

    local reader_row
    if reader_type then
        reader_row = iconLabel(reader_type.icon, _(reader_type.label), bottom_face, icon_size, pal, bottom_color)
    end
    local reader_w = reader_row and reader_row:getSize().w or 0

    local streak_row, bottom_h = nil, 0
    if show_streak then
        local day_txt = days > 0
            and string.format(N_("%d day streak", "%d days streak", days), days) or nil
        local week_txt = weeks > 0
            and string.format(N_("%d week streak", "%d weeks streak", weeks), weeks) or nil
        local room = W - 2 * pad_x - reader_w - (reader_w > 0 and S(20) or 0)
        local joined = day_txt and week_txt and (day_txt .. "  \u{B7}  " .. week_txt) or day_txt or week_txt
        local one_line = iconLabel("flame", joined, bottom_face, icon_size, pal, bottom_color)
        if one_line:getSize().w <= room or not (day_txt and week_txt) then
            streak_row = one_line
            bottom_h = line_h
        else
            -- Too wide for one line: days on the first, weeks below.
            streak_row = VerticalGroup:new{
                align = "left",
                iconLabel("flame", day_txt, bottom_face, icon_size, pal, bottom_color),
                text(week_txt, bottom_face, bottom_color),
            }
            bottom_h = streak_row:getSize().h
        end
    end
    if reader_row then bottom_h = math.max(bottom_h, line_h) end
    local content_bottom = H - pad_bottom - bottom_h - (bottom_h > 0 and S(18) or 0)

    if streak_row then
        placeText(streak_row, pad_x, H - pad_bottom - bottom_h
            + math.floor((bottom_h - streak_row:getSize().h) / 2))
    end
    if reader_row then
        placeText(reader_row, W - pad_x - reader_w, H - pad_bottom - bottom_h
            + math.floor((bottom_h - reader_row:getSize().h) / 2))
    end

    -- Statistics column (right): fonts are sized from the space down to the
    -- bottom row, same as before; the vertical GAP between rows is decided
    -- later, once the cover's real height is known (see below), so the last
    -- row's bottom lines up with the bottom of the cover.
    local stats_top = pad_top + (battery_h > 0 and (battery_h + S(10)) or 0)
    local stats_h_for_fonts = content_bottom - stats_top
    local rows = statRows(card)
    local budget = stats_h_for_fonts / math.max(1, #rows) / dp     -- units per row
    local value_size = math.min(22, budget * 0.42)
    local label_size = math.min(13, budget * 0.24)
    local value_face = Fonts.getFace("stat_value", value_size)
    local label_face = Fonts.getFace("stat_label", label_size)
    local stat_value_color = Colors.getColor("stat_value", pal.fg)
    local stat_label_color = Colors.getColor("stat_label", pal.fg)

    local right_w = 0
    for _idx, row in ipairs(rows) do
        right_w = math.max(right_w,
            TextWidget:new{ text = row[1], face = value_face }:getSize().w,
            TextWidget:new{ text = row[2], face = label_face }:getSize().w)
    end
    right_w = math.min(right_w + S(2), math.floor((W - 2 * pad_x) * 0.6))

    -- Left column: cover, then title / author / series --------------------------
    local left_w = W - 2 * pad_x - right_w - col_gap

    -- Title: bold, same size as the big stat values (e.g. the reading time).
    -- Author: regular weight, italic, same size as the stat labels (e.g.
    -- "Reading Time"). Series: same size as the stat labels, but bold.
    local title_face = Fonts.getFace("title", value_size)
    local author_face = Fonts.getFace("author", label_size)
    local series_face = Fonts.getFace("series", label_size)
    local title_color = Colors.getColor("title", pal.fg)
    local author_color = Colors.getColor("author", pal.fg)
    local series_color = Colors.getColor("series", pal.fg)

    local title_line_h = math.floor((1 + 0.3) * title_face.size + 0.5)

    -- Quote characters (several common opening/closing pairs) that might
    -- already wrap a highlighted passage straight from the book - dialogue
    -- most often. Stripped before we add our own curly quotes below, so a
    -- highlight like `"Hello," she said.` doesn't come out double-quoted
    -- as `""Hello," she said.""`.
    local QUOTE_PAIRS = {
        { open = "\"",       close = "\"" },
        { open = "\u{201C}", close = "\u{201D}" }, -- “ ”
        { open = "\u{2018}", close = "\u{2019}" }, -- ‘ ’
        { open = "\u{201E}", close = "\u{201C}" }, -- „ “
        { open = "\u{201E}", close = "\"" },       -- „ "
        { open = "\u{00AB}", close = "\u{00BB}" }, -- « »
        { open = "\u{2039}", close = "\u{203A}" }, -- ‹ ›
    }
    local function stripOuterQuotes(s)
        for _, pair in ipairs(QUOTE_PAIRS) do
            local ol, cl = #pair.open, #pair.close
            if #s > ol + cl and s:sub(1, ol) == pair.open and s:sub(-cl) == pair.close then
                return s:sub(ol + 1, -cl - 1)
            end
        end
        return s
    end

    -- Whether one shared "grouped" backdrop panel sits behind the whole
    -- title/author/series/quote block (as opposed to: no backdrop at all,
    -- a transparent one, or separate "individual" per-line panels).
    local grouped_backdrop_showing = backdrop_active and backdrop_grouped

    -- Full width the quote is allowed to use when it's free to run past
    -- the cover: unlike title/author/series (kept aligned to the cover's
    -- own width via max_w below), the quote sits on its own row
    -- underneath the cover+stats band, so nothing stops it from reaching
    -- all the way out to the side margin - EXCEPT when one shared grouped
    -- backdrop panel is showing behind the whole text block, where the
    -- quote has to stay the same width as title/author/series so the
    -- panel's right edge doesn't jog outward just for the quote's line.
    -- No backdrop-padding subtraction here: the BARE text should reach
    -- exactly to W - pad_x, same as the statistics/reader-type rows do -
    -- if a per-line backdrop panel is showing, it's then free to overshoot
    -- the margin by TEXT_BACKDROP_PAD_H on its own, exactly like the
    -- statistics/reader panels already do (see placeText above).
    local quote_full_w = W - 2 * pad_x

    -- Builds the title/author/series/quote stack at a given width. Called
    -- twice below: once at left_w, purely to measure how tall the stack is
    -- (those heights don't actually depend on width - title/quote are
    -- height-capped with an ellipsis, author/series are always a single
    -- line - so this is safe to do before the cover's real on-screen width
    -- is known), and again once that width IS known, to rebuild the stack
    -- narrow enough that it never reaches further right than the cover
    -- does (see cover_reach_w below). The quote block uses quote_full_w
    -- (full margin-to-margin width) instead of max_w, unless a grouped
    -- backdrop is showing, or `clamp_quote` is passed true, in which case
    -- it matches max_w like the rest - the centered layout below always
    -- passes true, since there everything (cover, title, stats grid) shares
    -- the same left/right edges, and the quote running out to the full
    -- screen width would break that alignment.
    --
    -- Returns the block list and the index of the quote block within it
    -- (nil if there is no quote), so callers can single out the (larger)
    -- gap above the quote from the gaps between title/author/series.
    local function buildTextBlocks(max_w, clamp_quote)
        local quote_max_w = (grouped_backdrop_showing or clamp_quote) and max_w or quote_full_w
        -- TextBoxWidget (needed here for wrapping across up to 2 lines,
        -- unlike the single-line TextWidget the rest of the card's text
        -- uses) always fills itself with bgcolor and blits the result as a
        -- SOLID block - it has no transparent mode. Over a plain background
        -- that solid fill in pal.bg is exactly right; over a wallpaper it
        -- would paint an opaque box that hides both the picture and the
        -- translucent panel placeText() puts behind it. So with a wallpaper
        -- up, build it in throwaway black-on-white "mask space" instead and
        -- let Wallpaper.mask() recolour just the glyphs, leaving the panel
        -- visible around them.
        local title_w = TextBoxWidget:new{
            text = card.title or "",
            face = title_face,
            width = max_w,
            height = 2 * title_line_h,
            height_adjust = true,
            height_overflow_show_ellipsis = true,
            alignment = "left",
            fgcolor = wallpaper_bg and Blitbuffer.COLOR_BLACK or title_color,
            bgcolor = wallpaper_bg and Blitbuffer.COLOR_WHITE or pal.bg,
        }
        title_w = Wallpaper.mask(wallpaper_bg ~= nil, title_w, title_color)
        local blocks = { title_w }
        if card.authors and card.authors ~= "" then
            blocks[#blocks + 1] = text(card.authors, author_face, author_color, max_w)
        end
        if card.series and card.series ~= "" then
            local line = card.series
            if card.series_index then
                line = Locale.tpl(_("{series} / #{index}"), { series = card.series, index = card.series_index })
            end
            blocks[#blocks + 1] = text(line, series_face, series_color, max_w)
        end

        -- Random highlighted quote (opt-in: "Card elements > Highlighted
        -- quote", default off). Appended to `blocks` below, so from that
        -- point on title, author, series and the quote are one and the same
        -- block: the same shared backdrop panel in "grouped" mode, the same
        -- left edge - never a separate box. Nothing is added (and the cover
        -- stays its normal size) unless the setting is on AND this
        -- particular book actually has a quote to show.
        local quote_idx = nil
        if Prefs.readBool(M.SETTING_QUOTE, false) then
            local quote_text = card.quote_text
            if type(quote_text) == "string" and quote_text:match("%S") then
                local quote_face = Fonts.getFace("quote", label_size)
                local quote_color = Colors.getColor("quote", author_color)
                local quote_line_h = math.floor((1 + 0.3) * quote_face.size + 0.5)
                local quote_bar_w = S(2)
                local quote_gap_w = S(6)
                local quote_clean = stripOuterQuotes(quote_text:gsub("%s+", " "))
                local quote_widget = TextBoxWidget:new{
                    text = "\u{201C}" .. quote_clean .. "\u{201D}",
                    face = quote_face,
                    width = quote_max_w - quote_bar_w - quote_gap_w,
                    height = 2 * quote_line_h,
                    height_adjust = true,
                    height_overflow_show_ellipsis = true,
                    alignment = "left",
                    fgcolor = wallpaper_bg and Blitbuffer.COLOR_BLACK or quote_color,
                    bgcolor = wallpaper_bg and Blitbuffer.COLOR_WHITE or pal.bg,
                }
                quote_widget = Wallpaper.mask(wallpaper_bg ~= nil, quote_widget, quote_color)
                -- Bar spans exactly the quote's own (measured) height, so it
                -- runs the full length of however many lines the quote wraps
                -- to - no more, no less. Always quote_color (never forced
                -- black): unlike the text above, this bar is painted
                -- directly, not through Wallpaper.mask, so a hardcoded
                -- black here would ignore the night/dark theme whenever a
                -- wallpaper is active.
                local quote_bar = LineWidget:new{
                    background = quote_color,
                    dimen = Geom:new{ w = quote_bar_w, h = quote_widget:getSize().h },
                }
                blocks[#blocks + 1] = HorizontalGroup:new{
                    align = "top",
                    quote_bar,
                    HorizontalSpan:new{ width = quote_gap_w },
                    quote_widget,
                }
                quote_idx = #blocks
            end
        end
        return blocks, quote_idx
    end

    -- Which arrangement to draw: "side" (default, above) puts the cover
    -- next to a single statistics column. "centered" puts the cover on its
    -- own, centered, with title/author/series/quote directly below it and
    -- the statistics spread beneath that in a 2-column grid instead - see
    -- M.SETTING_LAYOUT ("Advanced Settings" > "Layout").
    local layout_centered = Prefs.read(M.SETTING_LAYOUT, "side") == "centered"

    if layout_centered then
        -- -------------------------------------------------------------------
        -- Centered layout
        -- -------------------------------------------------------------------
        local available_w = W - 2 * pad_x
        local available_h = math.max(S(80), content_bottom - stats_top)

        -- Same three-case gap logic as the side layout above, kept local to
        -- this branch since it needs its own `individual_backdrop_showing`
        -- (the name is scoped to this `if`, so it doesn't clash with the
        -- side layout's copy in the `else` below).
        local individual_backdrop_showing = backdrop_active and not backdrop_grouped
        local header_gap_c, text_block_gap_c
        if individual_backdrop_showing then
            header_gap_c = S(8)
            text_block_gap_c = S(8)
        else
            local header_gap_base = math.floor(S(4) / 2)
            text_block_gap_c = math.max(3 * header_gap_base, 3 * TEXT_BACKDROP_PAD_V + S(4))
            header_gap_c = S(1)
        end
        local function gapBeforeC(i, quote_idx)
            if i <= 1 then return 0 end
            return (quote_idx and i == quote_idx) and text_block_gap_c or header_gap_c
        end

        -- Text block height doesn't depend on width (see buildTextBlocks),
        -- so measure it once, at the full available width, before the
        -- cover's own final width is known.
        local text_blocks_c, quote_index_c = buildTextBlocks(available_w, true)
        local text_h_c = 0
        for i, block in ipairs(text_blocks_c) do
            text_h_c = text_h_c + block:getSize().h + gapBeforeC(i, quote_index_c)
        end

        -- Statistics grid: 2 columns, as many rows as needed. Each cell is
        -- just "value line + label line" stacked, left-aligned - same
        -- metrics as the single-column layout's rows, without StatCell's
        -- right-alignment.
        local cell_h = TextWidget:new{ text = "Ag", face = value_face }:getSize().h
                     + TextWidget:new{ text = "Ag", face = label_face }:getSize().h
        local grid_row_gap = math.max(S(8), math.floor(col_gap / 2))
        local grid_rows_n = math.ceil(#rows / 2)
        local grid_h = grid_rows_n > 0 and (grid_rows_n * cell_h + (grid_rows_n - 1) * grid_row_gap) or 0
        local gap1 = col_gap                              -- cover -> text
        local gap2 = grid_rows_n > 0 and col_gap or 0      -- text -> grid

        -- The cover gets whatever height is left once the text and the
        -- statistics grid have taken their share - same "leftover space"
        -- philosophy as the side layout's cover_max_h above.
        local show_cover_shadow_c = Prefs.readBool(M.SETTING_COVER_SHADOW, true)
        local shadow_off_c = show_cover_shadow_c and S(4) or 0
        local cover_max_h_c = math.max(S(120), available_h - text_h_c - grid_h - gap1 - gap2 - shadow_off_c)
        local cover_restore_c = wallpaper_bg and Wallpaper.restore or nil
        local cover_c, cover_w_c, cover_h_c = buildCover(
            card, available_w - shadow_off_c, cover_max_h_c, pal, shadow_off_c, cover_restore_c)

        -- Rebuild the text stack (and, further down, the grid) to the
        -- cover's own real on-screen width - its drop shadow included, when
        -- shown - so everything shares the same left/right edges and the
        -- whole assembly reads as one centered block, even when the cover
        -- itself ends up narrower than the full available width.
        local reach_w = cover_w_c + (show_cover_shadow_c and shadow_off_c or 0)
        local text_max_w_c = reach_w - (backdrop_active and 2 * TEXT_BACKDROP_PAD_H or 0)
        text_blocks_c, quote_index_c = buildTextBlocks(text_max_w_c, true)

        local cover_left_c = pad_x + math.floor((available_w - reach_w) / 2)
        local cover_top_c = stats_top
        -- The text (and stat cells) sit inset from the cover's edge by
        -- TEXT_BACKDROP_PAD_H - the same gap the side layout leaves between
        -- the text and its panel's edge - while the panel itself lands
        -- exactly on the cover's own edge, with no extra padding added on
        -- top of that. So it's the content that shifts inward here, not
        -- the panel that shifts outward (contrast the side layout below,
        -- where cover_left is pulled outward instead; there the panel
        -- already wraps the unmoved text with this same padding, so
        -- shifting the cover out is what lines the two up).
        local text_inset_c = backdrop_active and TEXT_BACKDROP_PAD_H or 0
        local text_left_c = cover_left_c + text_inset_c

        if show_cover_shadow_c then
            local radius = Prefs.readBool(M.SETTING_ROUNDED, true) and S(4) or 0
            local shadow = CoverFrame.Shadow:new{
                width = cover_w_c, height = cover_h_c,
                offset = shadow_off_c, radius = radius,
                bg = pal.bg, restore = cover_restore_c,
            }
            place(shadow, cover_left_c, cover_top_c)
        end
        place(cover_c, cover_left_c, cover_top_c)

        local y = cover_top_c + cover_h_c + (show_cover_shadow_c and shadow_off_c or 0) + gap1
        -- Backdrop panels in this layout always span the cover's own width
        -- (cover_left_c .. cover_left_c + reach_w), never just however wide
        -- the text/cells happen to be. flushGroup adds TEXT_BACKDROP_PAD_H
        -- back around whatever min_x/max_x it's given (see flushGroup
        -- above), so passing the cover's edges shrunk inward by that same
        -- padding here means the finished, padded panel lands exactly on
        -- the cover's real edges - not the cover's edges plus a further
        -- margin, and not flush against the text either. That holds
        -- whether the reader has "grouped" backdrops on (one panel for the
        -- whole title block, one for the whole grid) or off (one panel per
        -- line / per stat row instead of per member).
        local panel_left = cover_left_c + TEXT_BACKDROP_PAD_H
        local panel_right = cover_left_c + reach_w - TEXT_BACKDROP_PAD_H
        if backdrop_grouped then
            local title_group_c = newGroup()
            for i, block in ipairs(text_blocks_c) do
                if i > 1 then y = y + gapBeforeC(i, quote_index_c) end
                groupAdd(title_group_c, block, text_left_c, y)
                y = y + block:getSize().h
            end
            flushGroup(title_group_c, TEXT_BACKDROP_PAD_H, TEXT_BACKDROP_PAD_V, panel_left, panel_right)
        else
            for i, block in ipairs(text_blocks_c) do
                if i > 1 then y = y + gapBeforeC(i, quote_index_c) end
                local line_group = newGroup()
                groupAdd(line_group, block, text_left_c, y)
                flushGroup(line_group, TEXT_BACKDROP_PAD_H, TEXT_BACKDROP_PAD_V, panel_left, panel_right)
                y = y + block:getSize().h
            end
        end

        if #rows > 0 then
            local grid_top = y + gap2
            local grid_col_gap = S(24)
            -- Same inset width as the text above (text_max_w_c), so the
            -- grid's two columns line up with the text's own left/right
            -- edges instead of reaching all the way to the cover's edge.
            local col_w = math.floor((text_max_w_c - grid_col_gap) / 2)
            local function statCellWidget(row)
                return VerticalGroup:new{
                    align = "left",
                    TextWidget:new{ text = row[1], face = value_face, fgcolor = stat_value_color, max_width = col_w },
                    TextWidget:new{ text = row[2], face = label_face, fgcolor = stat_label_color, max_width = col_w },
                }
            end
            if backdrop_grouped then
                -- One panel behind the whole grid (all rows, both columns).
                local grid_group_c = newGroup()
                for idx, row in ipairs(rows) do
                    local r = math.floor((idx - 1) / 2)
                    local c = (idx - 1) % 2
                    local cx = text_left_c + c * (col_w + grid_col_gap)
                    local cy = grid_top + r * (cell_h + grid_row_gap)
                    groupAdd(grid_group_c, statCellWidget(row), cx, cy)
                end
                flushGroup(grid_group_c, TEXT_BACKDROP_PAD_H, TEXT_BACKDROP_PAD_V, panel_left, panel_right)
            else
                -- One panel per ROW (both columns together, cover-width
                -- wide) - a per-CELL panel would only be half that width,
                -- and two of them side by side would either overlap (if
                -- stretched) or leave a gap in the middle (if not).
                local idx = 1
                for r = 0, grid_rows_n - 1 do
                    local row_group = newGroup()
                    for c = 0, 1 do
                        if idx > #rows then break end
                        local cx = text_left_c + c * (col_w + grid_col_gap)
                        local cy = grid_top + r * (cell_h + grid_row_gap)
                        groupAdd(row_group, statCellWidget(rows[idx]), cx, cy)
                        idx = idx + 1
                    end
                    flushGroup(row_group, TEXT_BACKDROP_PAD_H, TEXT_BACKDROP_PAD_V, panel_left, panel_right)
                end
            end
        end
    else
    -- First pass, at the full left-column width, just to measure the
    -- stack's height for the cover-sizing math below.
    local text_blocks, quote_index = buildTextBlocks(left_w)

    -- Gap between title/author/series, and the (separate, larger) gap
    -- above the quote. The tiered spacing below - tight lines, quote held
    -- further apart - only makes sense when one shared backdrop panel sits
    -- behind the whole block ("grouped" mode): that's the only case where
    -- the panel's own edges don't already mark a boundary between lines,
    -- so the gaps are what has to carry the visual grouping. Without a
    -- backdrop at all, or with a separate panel behind each line
    -- ("individual" mode - each line already reads as its own boundary via
    -- its own panel), every gap is just S(4), flat.
    -- Three cases:
    --  1) individual per-line backdrop panels, non-transparent (backdrop
    --     active, NOT grouped): each line already has its own visible
    --     panel, so a flat, slightly larger fixed gap (S(8)) is used
    --     between every line, quote included.
    --  2) grouped backdrop (one shared panel behind the whole block): the
    --     panel's own edges don't mark a boundary between lines, so tiered
    --     spacing (tight header lines, quote held further apart) carries
    --     the visual grouping instead.
    --  3) no backdrop at all / transparent: same tiered spacing as (2), so
    --     a boxless/transparent card matches the grouped-backdrop card.
    local individual_backdrop_showing = backdrop_active and not backdrop_grouped
    local header_gap, text_block_gap
    if individual_backdrop_showing then
        header_gap = S(8)
        text_block_gap = S(8)
    else
        local header_gap_base = math.floor(S(4) / 2)
        -- Gap above the quote first (unchanged from before): 3 * header_gap_base,
        -- or - with 3 * TEXT_BACKDROP_PAD_V eaten by the panel reaching toward
        -- itself around the quote - whichever of the two is larger, so the
        -- panel never overlaps itself.
        text_block_gap = math.max(3 * header_gap_base, 3 * TEXT_BACKDROP_PAD_V + S(4))
        -- Gap between title/author/series - set directly in (unscaled)
        -- pixels here, rather than as a fraction of text_block_gap: that
        -- value is only ~6-15px to begin with, so dividing it by anything
        -- much above ~10 always floors to 0 - there's no finer step below
        -- that, a screen can't draw half a pixel. Change GROUPED_HEADER_GAP
        -- directly to whatever small value you want (0 = lines touch).
        local GROUPED_HEADER_GAP = 1
        header_gap = S(GROUPED_HEADER_GAP)
    end
    local function gapBefore(i)
        if i <= 1 then return 0 end
        return (quote_index and i == quote_index) and text_block_gap or header_gap
    end

    local text_h = 0
    for i, block in ipairs(text_blocks) do
        text_h = text_h + block:getSize().h + gapBefore(i)
    end

    -- The cover starts level with the first statistic (Progress), not with
    -- the battery indicator above it - or, with a backdrop panel showing,
    -- level with the TOP of that first statistic's panel, which sits
    -- TEXT_BACKDROP_PAD_V above the text itself.
    local show_cover_shadow = Prefs.readBool(M.SETTING_COVER_SHADOW, true)
    -- Reserve space for the shadow offset so the cover doesn't overflow its column.
    local shadow_off = show_cover_shadow and S(4) or 0
    local cover_top = stats_top - (backdrop_active and TEXT_BACKDROP_PAD_V or 0)
    -- The reserved gap below the text stack is text_block_gap - the same
    -- gap used above the quote - so the cover simply gets whatever's left
    -- below the whole title/author/series/quote block. It shrinks on its
    -- own by however much text_h grows, whether that's from the quote
    -- being on or from a long-enough title/author wrapping onto extra
    -- lines.
    local cover_max_h = math.max(S(80), content_bottom - cover_top - text_h - text_block_gap - shadow_off)
    local cover_restore = wallpaper_bg and Wallpaper.restore or nil
    local cover, cover_w, cover_h = buildCover(card, left_w - shadow_off, cover_max_h, pal, shadow_off, cover_restore)

    -- Now that the cover's real on-screen width is known, rebuild the
    -- title/author/series/quote stack narrow enough that it never reaches
    -- further right than the cover itself does - its drop shadow included,
    -- when the shadow is shown, since that's how far right the cover
    -- actually, visibly extends. (This doesn't change text_h/cover_max_h
    -- above: see buildTextBlocks - block heights don't depend on width.)
    --
    -- With no backdrop panel behind the text (plain background, or a
    -- transparent/"Off" wallpaper panel), the text itself IS the box, so it
    -- can run all the way out to cover_reach_w. But when a backdrop panel
    -- IS showing (individual per-line panels, or one shared "grouped"
    -- panel), that panel adds TEXT_BACKDROP_PAD_H of its own padding on
    -- both sides on top of the text - so if the text were allowed to reach
    -- all the way to cover_reach_w, the PANEL's right edge would stick out
    -- past the cover (+ shadow) by that padding. Shave that padding off the
    -- available width here so the panel's edges - not just the bare text -
    -- line up with where the cover visibly starts/ends.
    local cover_reach_w = cover_w + (show_cover_shadow and shadow_off or 0)
    local text_max_w = cover_reach_w - (backdrop_active and 2 * TEXT_BACKDROP_PAD_H or 0)
    text_blocks, quote_index = buildTextBlocks(text_max_w)

    -- Now that the cover's real height is known, spread the statistics rows
    -- so the LAST one's bottom lines up with the bottom of the cover - or,
    -- with a backdrop panel showing, so the BOTTOM of that last row's panel
    -- (TEXT_BACKDROP_PAD_V below its text) lines up with the cover's
    -- bottom. That bottom includes the drop shadow's own downward reach
    -- (shadow_off further down than the cover art) whenever it's shown, so
    -- the statistics line up with how far the cover visibly extends.
    local cover_bottom = cover_top + cover_h + (show_cover_shadow and shadow_off or 0)
    local stats_bottom_target = cover_bottom - (backdrop_active and TEXT_BACKDROP_PAD_V or 0)
    local stats_h = math.max(0, stats_bottom_target - stats_top)
    local cells, cells_h = {}, 0
    for _idx, row in ipairs(rows) do
        local cell = StatCell:new{
            value = row[1], label = row[2], width = right_w,
            value_face = value_face, label_face = label_face,
            value_color = stat_value_color, label_color = stat_label_color,
        }
        cells[#cells + 1] = cell
        cells_h = cells_h + cell:getSize().h
    end
    local gap = 0
    local stat_y = stats_top
    if #cells > 1 then
        gap = math.max(0, math.floor((stats_h - cells_h) / (#cells - 1)))
    elseif #cells == 1 then
        -- Nothing to distribute a gap between, so center the single row in
        -- the space instead of leaving it stuck to the top with the rest
        -- of the column (down to the cover's bottom) sitting empty.
        stat_y = stats_top + math.max(0, math.floor((stats_h - cells_h) / 2))
    end
    -- Placed one at a time (rather than as a single VerticalGroup) so a
    -- wallpaper backdrop panel can sit behind each row individually instead
    -- of one solid strip behind the whole column.
    local stats_group = backdrop_grouped and newGroup() or nil
    for i, cell in ipairs(cells) do
        if i > 1 then stat_y = stat_y + gap end
        if stats_group then
            groupAdd(stats_group, cell, W - pad_x - right_w, stat_y)
        else
            placeText(cell, W - pad_x - right_w, stat_y)
        end
        stat_y = stat_y + cell:getSize().h
    end
    if stats_group then flushGroup(stats_group, TEXT_BACKDROP_PAD_H, TEXT_BACKDROP_PAD_V) end

    -- Cover's left edge: level with pad_x normally, or with the title
    -- block's backdrop panel (which sticks out TEXT_BACKDROP_PAD_H further
    -- left than the text) when that panel is showing.
    local cover_left = pad_x - (backdrop_active and TEXT_BACKDROP_PAD_H or 0)

    -- Cover drop shadow (painted first so the cover sits on top).
    if show_cover_shadow then
        local radius = Prefs.readBool(M.SETTING_ROUNDED, true) and S(4) or 0
        local shadow = CoverFrame.Shadow:new{
            width  = cover_w,
            height = cover_h,
            offset = shadow_off,
            radius = radius,
            bg     = pal.bg,
            restore = cover_restore,
        }
        place(shadow, cover_left, cover_top)
    end

    place(cover, cover_left, cover_top)

    -- (text_block_gap/gapBefore are computed earlier, alongside the quote,
    -- since the cover-sizing math above needs them too.) Title, author,
    -- series and the quote (if any) are all placed here from the same
    -- text_blocks list - one flowing block, sharing one backdrop panel in
    -- "grouped" mode.
    local y = cover_top + cover_h + S(20)
    local title_group = backdrop_grouped and newGroup() or nil
    for i, block in ipairs(text_blocks) do
        if i > 1 then y = y + gapBefore(i) end
        if title_group then
            groupAdd(title_group, block, pad_x, y)
        else
            placeText(block, pad_x, y)
        end
        y = y + block:getSize().h
    end
    if title_group then flushGroup(title_group, TEXT_BACKDROP_PAD_H, TEXT_BACKDROP_PAD_V) end
    end

    local canvas = OverlapGroup:new{
        dimen = Geom:new{ w = W, h = H },
        allow_mirroring = false,
    }
    for _idx, w in ipairs(items) do table.insert(canvas, w) end

    return FrameContainer:new{
        background = pal.bg,
        bordersize = 0,
        padding = 0,
        margin = 0,
        width = W,
        height = H,
        canvas,
    }
end

-- ---------------------------------------------------------------------------
-- Tap-to-close popup (for "Preview")
-- ---------------------------------------------------------------------------
local Popup = InputContainer:extend{
    name = "BookCardPreview",
    card = nil,
    covers_fullscreen = true,
}

function Popup:init()
    local W, H = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = W, h = H }
    if Device:hasKeys() then
        self.key_events.AnyKeyPressed = { { Device.input.group.Any } }
    end
    if Device:isTouchDevice() then
        self.ges_events.Tap = {
            GestureRange:new{ ges = "tap", range = self.dimen },
        }
    end
    self[1] = M.build(self.card)
end

function Popup:onShow()
    UIManager:setDirty(self, function() return "full", self.dimen end)
end

function Popup:onTap()
    UIManager:close(self)
    return true
end
Popup.onAnyKeyPressed = Popup.onTap

function Popup:onCloseWidget()
    UIManager:setDirty(nil, "full")
end

M.Popup = Popup

-- ---------------------------------------------------------------------------
-- "Margins" submenu (top/bottom padding)
-- ---------------------------------------------------------------------------
local function marginSpinner(setting, default, title_text, touchmenu_instance)
    UIManager:show(SpinWidget:new{
        title_text    = title_text,
        value         = Prefs.read(setting, default),
        value_min     = M.MARGIN_MIN,
        value_max     = M.MARGIN_MAX,
        value_step    = 1,
        value_hold_step = 10,
        default_value = default,
        ok_text       = _("Set"),
        callback      = function(spin)
            Prefs.save(setting, spin.value)
            if touchmenu_instance then touchmenu_instance:updateItems() end
        end,
    })
end

-- Returns the sub_item_table for the "Margins" menu entry. All three
-- values default to the previous fixed layout; raising any of them pulls
-- the content in from that edge (handy on curved-glass screens whose
-- edges aren't fully visible - raising top and bottom together shifts the
-- card toward the middle of the screen).
function M.buildMarginsMenu()
    return {
        {
            text_func = function()
                return _("Side padding") .. ": " .. Prefs.read(M.SETTING_MARGIN_SIDE, M.DEFAULT_MARGIN_SIDE)
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                marginSpinner(M.SETTING_MARGIN_SIDE, M.DEFAULT_MARGIN_SIDE, _("Side padding"), touchmenu_instance)
            end,
        },
        {
            text_func = function()
                return _("Top padding") .. ": " .. Prefs.read(M.SETTING_MARGIN_TOP, M.DEFAULT_MARGIN_TOP)
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                marginSpinner(M.SETTING_MARGIN_TOP, M.DEFAULT_MARGIN_TOP, _("Top padding"), touchmenu_instance)
            end,
        },
        {
            text_func = function()
                return _("Bottom padding") .. ": " .. Prefs.read(M.SETTING_MARGIN_BOTTOM, M.DEFAULT_MARGIN_BOTTOM)
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                marginSpinner(M.SETTING_MARGIN_BOTTOM, M.DEFAULT_MARGIN_BOTTOM, _("Bottom padding"), touchmenu_instance)
            end,
        },
    }
end

-- ---------------------------------------------------------------------------
-- "Statistics" submenu (Card elements > Statistics): a "Reorder" entry,
-- then one on/off toggle per row, listed in the reader's current order.
-- ---------------------------------------------------------------------------
local function openStatOrderWidget(touchmenu_instance)
    local order = M.getStatOrder()
    local item_table = {}
    for i = 1, #order do
        local def = STAT_DEFS_BY_ID[order[i]]
        local menu_text = def.menu_label and def.menu_label() or def.label()
        item_table[#item_table + 1] = { text = menu_text, id = def.id }
    end
    local sort_widget
    sort_widget = SortWidget:new{
        title = _("Reorder statistics"),
        item_table = item_table,
        callback = function()
            local new_order = {}
            for i = 1, #sort_widget.item_table do
                new_order[#new_order + 1] = sort_widget.item_table[i].id
            end
            M.setStatOrder(new_order)
            if touchmenu_instance then touchmenu_instance:updateItems() end
        end,
    }
    UIManager:show(sort_widget)
end

--- Returns the sub_item_table for the "Statistics" menu entry: drag-to-sort
--- for the row order, plus the existing per-row on/off toggles, now listed
--- in that same order so the menu always matches what's drawn on the card.
function M.buildStatisticsMenu()
    local order = M.getStatOrder()
    local items = {
        {
            text = _("Reorder"),
            keep_menu_open = true,
            callback = function(touchmenu_instance) openStatOrderWidget(touchmenu_instance) end,
            separator = true,
        },
    }
    for i = 1, #order do
        local def = STAT_DEFS_BY_ID[order[i]]
        items[#items + 1] = {
            text = def.menu_label and def.menu_label() or def.label(),
            checked_func = function() return Prefs.readBool(def.setting, def.default) end,
            callback = function() Prefs.save(def.setting, not Prefs.readBool(def.setting, def.default)) end,
            keep_menu_open = true,
        }
    end
    return items
end

return M
