--[[
Book Card - the card itself.

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
local OverlapGroup = require("ui/widget/overlapgroup")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
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

-- Individual statistics-column rows, in the order they are drawn (all
-- default on, except SETTING_HIGHLIGHTS above, which stays off by default).
M.SETTING_STAT_PROGRESS      = "bookcard_stat_progress"
M.SETTING_STAT_PAGES         = "bookcard_stat_pages"
M.SETTING_STAT_READING_TIME  = "bookcard_stat_reading_time"
M.SETTING_STAT_TIME_LEFT     = "bookcard_stat_time_left"
M.SETTING_STAT_DAILY_AVG     = "bookcard_stat_daily_avg"
M.SETTING_STAT_PAGES_PER_MIN = "bookcard_stat_pages_per_min"
M.SETTING_STAT_STARTED       = "bookcard_stat_started"
M.SETTING_STAT_FINISH        = "bookcard_stat_finish"

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
local function buildCover(card, max_w, max_h, pal, shadow_offset)
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
-- ---------------------------------------------------------------------------
local function statRows(card)
    local percent = card.percent
    local rows = {}

    local function dur(secs)
        return Locale.formatDuration(secs) or DASH
    end

    -- Progress goes first (top of the column), the page count right under it.
    if Prefs.readBool(M.SETTING_STAT_PROGRESS, true) then
        rows[#rows + 1] = { percent and (tostring(percent) .. "%") or DASH, _("Progress") }
    end
    if Prefs.readBool(M.SETTING_STAT_PAGES, true) and card.current_page and card.total_pages then
        rows[#rows + 1] = {
            string.format("%d / %d", card.current_page, card.total_pages),
            _("Pages"),
        }
    end
    if Prefs.readBool(M.SETTING_STAT_READING_TIME, true) then
        rows[#rows + 1] = { dur(card.total_time), _("Reading Time") }
    end
    if Prefs.readBool(M.SETTING_STAT_TIME_LEFT, true) then
        rows[#rows + 1] = { card.finished and DASH or dur(card.time_left_secs), _("Time Left") }
    end
    if Prefs.readBool(M.SETTING_STAT_DAILY_AVG, true) then
        rows[#rows + 1] = { dur(card.daily_avg_secs), _("Daily Avg") }
    end

    if Prefs.readBool(M.SETTING_STAT_PAGES_PER_MIN, true) then
        local ppm = card.pages_per_min
        local ppm_text = DASH
        if ppm then ppm_text = Locale.formatNumber(ppm, ppm >= 1 and 1 or 2) end
        rows[#rows + 1] = { ppm_text, _("Pages/Min") }
    end

    -- "Started": 1 day ago reads as "Yesterday", 2+ as "N days ago".
    if Prefs.readBool(M.SETTING_STAT_STARTED, true) then
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
        rows[#rows + 1] = {
            span_text,
            started and Locale.tpl(_("Started {date}"), { date = started }) or _("Started"),
        }
    end

    if Prefs.readBool(M.SETTING_STAT_FINISH, true) then
        if card.finished then
            rows[#rows + 1] = { Locale.shortDate(card.finished_ts) or DASH, _("Finished Date") }
        else
            rows[#rows + 1] = { Locale.shortDate(card.est_finish_ts) or DASH, _("Est. Finish") }
        end
    end

    -- Off by default: how many highlights this book has.
    if Prefs.readBool(M.SETTING_HIGHLIGHTS, false) then
        rows[#rows + 1] = { tostring(card.highlights_count or 0), _("Highlights") }
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

    local pad_x = S(28)
    local pad_top = S(22)
    local pad_bottom = S(26)
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
            place(pct_text, W - pad_x - size.w, pad_top)
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
        place(streak_row, pad_x, H - pad_bottom - bottom_h
            + math.floor((bottom_h - streak_row:getSize().h) / 2))
    end
    if reader_row then
        place(reader_row, W - pad_x - reader_w, H - pad_bottom - bottom_h
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
    local title = TextBoxWidget:new{
        text = card.title or "",
        face = title_face,
        width = left_w,
        height = 2 * title_line_h,
        height_adjust = true,
        height_overflow_show_ellipsis = true,
        alignment = "left",
        fgcolor = title_color,
        bgcolor = pal.bg,
    }
    local text_blocks = { title }
    if card.authors and card.authors ~= "" then
        text_blocks[#text_blocks + 1] = text(card.authors, author_face, author_color, left_w)
    end
    if card.series and card.series ~= "" then
        local line = card.series
        if card.series_index then
            line = Locale.tpl(_("{series} / #{index}"), { series = card.series, index = card.series_index })
        end
        text_blocks[#text_blocks + 1] = text(line, series_face, series_color, left_w)
    end
    local text_h = 0
    for i, block in ipairs(text_blocks) do
        text_h = text_h + block:getSize().h + (i > 1 and S(3) or 0)
    end

    -- The cover starts level with the first statistic (Progress), not with
    -- the battery indicator above it.
    local show_cover_shadow = Prefs.readBool(M.SETTING_COVER_SHADOW, true)
    -- Reserve space for the shadow offset so the cover doesn't overflow its column.
    local shadow_off = show_cover_shadow and S(4) or 0
    local cover_top = stats_top
    local cover_max_h = math.max(S(80), content_bottom - cover_top - text_h - S(10) - shadow_off)
    local cover, cover_w, cover_h = buildCover(card, left_w - shadow_off, cover_max_h, pal, shadow_off)

    -- Now that the cover's real height is known, spread the statistics rows
    -- so the LAST one's bottom lines up with the bottom of the cover.
    local stats_h = math.max(0, (cover_top + cover_h) - stats_top)
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
    if #cells > 1 then
        gap = math.max(0, math.floor((stats_h - cells_h) / (#cells - 1)))
    end
    local column = VerticalGroup:new{ align = "right" }
    for i, cell in ipairs(cells) do
        if i > 1 then table.insert(column, VerticalSpan:new{ width = gap }) end
        table.insert(column, cell)
    end
    place(column, W - pad_x - right_w, stats_top)

    -- Cover drop shadow (painted first so the cover sits on top).
    if show_cover_shadow then
        local radius = Prefs.readBool(M.SETTING_ROUNDED, true) and S(4) or 0
        local shadow = CoverFrame.Shadow:new{
            width  = cover_w,
            height = cover_h,
            offset = shadow_off,
            radius = radius,
            bg     = pal.bg,
        }
        place(shadow, pad_x, cover_top)
    end

    place(cover, pad_x, cover_top)

    local y = cover_top + cover_h + S(20)
    for i, block in ipairs(text_blocks) do
        if i > 1 then y = y + S(3) end
        place(block, pad_x, y)
        y = y + block:getSize().h
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

return M
