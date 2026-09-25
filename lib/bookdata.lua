--[[
Book card - gathers everything the card shows into one plain table ("card").

Every number is computed the way the Reading Insights plugin computes it
(views/book_stats_view.lua + lib/book_stats_data.lua + lib/insights_data.lua),
so the card and its popups always agree:

  avg_time      the statistics plugin's live in-memory value, read BEFORE
                insertDB() (which recomputes it) - the same value the footer
                and Reading Insights use
  time left     doc:getTotalPagesLeft(doc:getCurrentPage()) * avg_time
  pages/min     60 / avg_time
  reading time  the statistics plugin's capped per-book total
                (getPageTimeTotalStats: each page's time capped at max_sec)
  daily avg     reading time / number of days the book was read
  days          days since the first page_stat entry (Reading Insights'
                "days since started"); for a finished book: start -> finish
  est. finish   now + time left / daily average
  streaks       daily + weekly, exactly Data.calculateStreaks (week start
                follows Reading Insights' setting)
  reader type   the part of the day (night 0-6, morning 6-12, afternoon
                12-18, evening 18-24) with the most reading time, for THIS
                book (card.book_id)

Two sources feed it:

  collectLive(ui)        a book is open: live reader state
  collectFromFile(file)  no book is open and there is no usable cache:
                         rebuilt from the sidecar + statistics database,
                         with the same formulas

prepare() runs right before drawing a card that came out of the cache: it
re-reads what can change while no book is open (status / progress from the
sidecar, streaks, reader type) and finishes the derived numbers.

card fields:
  file, title, authors, series, series_index
  percent (0..100), current_page, total_pages, status ("complete" / ...), pages_left
  chapter_pages_left  pages left in the CURRENT chapter (live document only,
                       via ui.toc:getChapterPagesLeft, falling back to the
                       whole book's pages left when there's no usable
                       chapter TOC data - nil otherwise)
  avg_time (secs/page), total_time (secs), days_read, pages_read
  today_time (secs read TODAY, this book only, per-page capped like total_time)
  all_books_time (secs read TODAY across EVERY book, same per-page cap)
  started_ts, last_read_ts, finished_date
  streak_days, streak_weeks, hour_bucket, book_id
  highlights_count
  quote_text     one random highlighted quote for this book, re-picked every
                 time the card is (re)built (collectLive/collectFromFile/
                 prepare) - nil if the book has no highlights with text
  cover_file / has_cover
 derived by finalize():
  finished, time_left_secs, daily_avg_secs, daily_avg_pages, pages_per_min,
  est_finish_ts, finished_ts, span_days, chapter_time_left_secs
]]--

local deps = ...
local StatsDb = deps.StatsDb
local Cache   = deps.Cache
local Locale  = deps.Locale

local Math = require("optmath")

local M = {}

local DAY = 86400

-- Seeded once (module-level, guarded by a global flag so re-loading the
-- module - e.g. across KOReader instantiations - doesn't reseed) so
-- M.finalize's/pickRandomQuote's math.random() doesn't always return the
-- same "random" quote in a given session.
if not _G._bookcard_random_seeded then
    math.randomseed(os.time())
    _G._bookcard_random_seeded = true
end

local function num(v)
    local n = tonumber(v)
    if n and n == n then return n end
    return nil
end

local function esc(s)
    return (tostring(s):gsub("'", "''"))
end

-- "YYYY-MM-DD" -> timestamp at local noon (noon dodges DST edge cases).
local function dateToTs(str)
    if type(str) ~= "string" then return nil end
    local y, m, d = str:match("^(%d%d%d%d)%-(%d%d?)%-(%d%d?)")
    if not y then return nil end
    return os.time{ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 }
end

local function noonOf(ts)
    local t = os.date("*t", ts)
    return os.time{ year = t.year, month = t.month, day = t.day, hour = 12 }
end

local function filenameTitle(file)
    local name = tostring(file or ""):match("([^/]+)$") or ""
    return (name:gsub("%.[^.]+$", ""))
end

-- Multiple authors (newline-separated in doc_props.authors) are joined with
-- a language-appropriate "and" before the last name instead of a comma:
-- "A and B" / "A, B and C" (hu: "A és B" / "A, B és C").
local function joinAuthors(list)
    local n = #list
    if n == 0 then return nil end
    if n == 1 then return list[1] end
    local and_word = Locale and Locale._("and") or "and"
    return table.concat(list, ", ", 1, n - 1) .. " " .. and_word .. " " .. list[n]
end

-- Some sources report several authors as one comma-joined line ("Jane Doe,
-- John Smith") instead of newline-separating them - which otherwise reads
-- as a single author with a literal comma in the name. Split such a line on
-- commas, but only when EVERY resulting piece contains a space (i.e. looks
-- like a full "First Last" name) - this deliberately leaves a genuine
-- inverted single name ("Smith, John") alone, since there each piece is a
-- single word.
local function splitCommaJoinedNames(line)
    if not line:find(",") then return { line } end
    local pieces = {}
    for piece in (line .. ","):gmatch("(.-),") do
        local trimmed = piece:match("^%s*(.-)%s*$")
        if trimmed ~= "" then pieces[#pieces + 1] = trimmed end
    end
    if #pieces < 2 then return { line } end
    for _, piece in ipairs(pieces) do
        if not piece:find("%s") then return { line } end
    end
    return pieces
end

local function cleanAuthors(authors)
    if type(authors) ~= "string" or authors == "" then return nil end
    local list = {}
    for line in (authors .. "\n"):gmatch("(.-)\n") do
        local trimmed = line:match("^%s*(.-)%s*$")
        if trimmed ~= "" then
            for _, name in ipairs(splitCommaJoinedNames(trimmed)) do
                list[#list + 1] = name
            end
        end
    end
    return joinAuthors(list)
end

local function cleanSeries(props)
    if type(props) ~= "table" then return nil, nil end
    local series = props.series
    if type(series) ~= "string" or series == "" or series == "N/A" then return nil, nil end
    local idx = tonumber(props.series_index)
    if idx then
        if idx == math.floor(idx) then
            idx = string.format("%d", idx)
        else
            idx = string.format("%g", idx)
        end
    end
    return series, idx
end

-- Highlight count: works with either KOReader annotation format.
--   new format: a flat "annotations" list; each highlight entry carries a
--               "drawer" (its highlight style) - plain bookmarks don't have one
--   old format: a "highlight" table keyed by page, each page holding a list
local function countHighlights(ds)
    local count = 0
    local annotations = ds:readSetting("annotations")
    if type(annotations) == "table" then
        for _, item in ipairs(annotations) do
            if type(item) == "table" and item.drawer then
                count = count + 1
            end
        end
        return count
    end
    local highlight = ds:readSetting("highlight")
    if type(highlight) == "table" then
        for _, items in pairs(highlight) do
            if type(items) == "table" then
                count = count + #items
            end
        end
    end
    return count
end

-- Highlighted quote texts: works with either KOReader annotation format
-- (see countHighlights above), but - unlike the plain count - only counts
-- entries that actually carry highlighted text, since a random EMPTY
-- "quote" would be worse than showing none.
local function collectHighlightTexts(ds)
    local texts = {}
    local function add(raw)
        if type(raw) ~= "string" then return end
        local trimmed = raw:match("^%s*(.-)%s*$")
        if trimmed ~= "" then texts[#texts + 1] = trimmed end
    end

    local annotations = ds:readSetting("annotations")
    if type(annotations) == "table" then
        for _, item in ipairs(annotations) do
            if type(item) == "table" and item.drawer then add(item.text) end
        end
        return texts
    end
    local highlight = ds:readSetting("highlight")
    if type(highlight) == "table" then
        for _, items in pairs(highlight) do
            if type(items) == "table" then
                for _, item in ipairs(items) do
                    if type(item) == "table" then add(item.text) end
                end
            end
        end
    end
    return texts
end

-- One random highlighted quote for `ds`, or nil if the book has none.
local function pickRandomQuote(ds)
    local ok, texts = pcall(collectHighlightTexts, ds)
    if not ok or #texts == 0 then return nil end
    return texts[math.random(#texts)]
end

-- The statistics plugin's per-page cap (settings > statistics > max_sec).
local function maxSec()
    local s = G_reader_settings and G_reader_settings:readSetting("statistics")
    return (type(s) == "table" and num(s.max_sec)) or 120
end

-- ---------------------------------------------------------------------------
-- Progress of the open book (same as Reading Insights' BookProgress).
-- ---------------------------------------------------------------------------
-- Returns percent, current page, total pages - the same numbers, worked out
-- the same way (pagemap labels / hidden flows), so the "N / M pages" row
-- always agrees with the percentage shown next to it.
local function liveProgress(ui)
    local doc = ui.document
    local current = ui:getCurrentPage()
    local total = doc:getPageCount()
    if not current or not total or total == 0 then return nil end

    local pagemap = ui.pagemap and ui.pagemap:wantsPageLabels()
    local idx, count
    if pagemap then
        local _, page_idx, pages_idx = ui.pagemap:getCurrentPageLabel()
        idx, count = page_idx, pages_idx
    elseif doc:hasHiddenFlows() then
        local flow = doc:getPageFlow(current)
        current = doc:getPageNumberInFlow(current)
        total = doc:getTotalPagesInFlow(flow)
    end
    if pagemap and idx and count and count > 0 then
        return Math.round(100 * idx / count), idx, count
    end
    return Math.round(100 * current / total), current, total
end

-- ---------------------------------------------------------------------------
-- Sidecar (per-book settings) - works with or without an open book.
-- ---------------------------------------------------------------------------
function M.readSidecar(file)
    local sc = {}
    local ok, ds = pcall(function()
        return require("docsettings"):open(file)
    end)
    if not ok or not ds then return sc end
    local percent = num(ds:readSetting("percent_finished"))
    if percent then sc.percent = Math.round(percent * 100) end
    local summary = ds:readSetting("summary")
    if type(summary) == "table" then
        sc.status = summary.status
        sc.modified = summary.modified
    end
    sc.md5 = ds:readSetting("partial_md5_checksum")
    sc.props = ds:readSetting("doc_props")
    sc.highlights = countHighlights(ds)
    sc.quote = pickRandomQuote(ds)
    return sc
end

-- ---------------------------------------------------------------------------
-- Statistics database.
-- ---------------------------------------------------------------------------
local function findBookId(conn, file, sc, title, authors)
    local md5 = sc.md5
    if not md5 then
        local ok, res = pcall(function() return require("util").partialMD5(file) end)
        if ok then md5 = res end
    end
    if md5 then
        local r = StatsDb.first(conn, string.format(
            "SELECT id FROM book WHERE md5 = '%s' ORDER BY last_open DESC LIMIT 1", esc(md5)), 1)
        if r and r[1] then return r[1] end
    end
    if title then
        local r = StatsDb.first(conn, string.format(
            "SELECT id FROM book WHERE title = '%s' AND authors = '%s' ORDER BY last_open DESC LIMIT 1",
            esc(title), esc(authors or "N/A")), 1)
        if r and r[1] then return r[1] end
    end
    return nil
end

-- Per-book numbers, with the statistics plugin's own queries.
local function fillBookStats(conn, card, book_id)
    -- Capped totals: exactly what ReaderStatistics:getPageTimeTotalStats
    -- returns (each page's time capped at max_sec).
    local r = StatsDb.first(conn, string.format([[
        SELECT count(*), sum(durations)
        FROM (
            SELECT min(sum(duration), %d) AS durations
            FROM page_stat
            WHERE id_book = %d
            GROUP BY page
        )]], maxSec(), book_id), 2)
    if r then
        card.pages_read = num(r[1])
        card.total_time = num(r[2])
    end

    -- Reading Insights' BookStatsData.getBookAndTodayStats:
    -- distinct days read, first start, and whole days since the first entry.
    r = StatsDb.first(conn, string.format([[
        SELECT count(*) FROM (
            SELECT strftime('%%Y-%%m-%%d', start_time, 'unixepoch', 'localtime') AS dates
            FROM page_stat WHERE id_book = %d GROUP BY dates)]], book_id), 1)
    if r then card.days_read = num(r[1]) end

    r = StatsDb.first(conn, string.format([[
        SELECT start_time,
               CAST(julianday('now', 'localtime')
                    - julianday(date(start_time, 'unixepoch', 'localtime')) AS INTEGER)
        FROM page_stat WHERE id_book = %d ORDER BY start_time ASC LIMIT 1]], book_id), 2)
    if r then
        card.started_ts = num(r[1])
        card.days_since_start = num(r[2])
    end

    r = StatsDb.first(conn, string.format(
        "SELECT max(start_time) FROM page_stat_data WHERE id_book = %d", book_id), 1)
    if r then card.last_read_ts = num(r[1]) end

    r = StatsDb.first(conn, string.format("SELECT pages FROM book WHERE id = %d", book_id), 1)
    if r and num(r[1]) and num(r[1]) > 0 then card.stats_pages = num(r[1]) end

    -- Today only, this book: same per-page cap as the all-time total above,
    -- just restricted to today's local date.
    r = StatsDb.first(conn, string.format([[
        SELECT sum(durations)
        FROM (
            SELECT min(sum(duration), %d) AS durations
            FROM page_stat
            WHERE id_book = %d
              AND date(start_time, 'unixepoch', 'localtime') = date('now', 'localtime')
            GROUP BY page
        )]], maxSec(), book_id), 1)
    if r then card.today_time = num(r[1]) end
end

-- ---- streaks (Reading Insights' Data.calculateStreaks) ---------------------
local function parseDateYMD(str)
    local y, m, d = tostring(str or ""):match("^(%d%d%d%d)-(%d%d)-(%d%d)")
    if not y then return nil end
    return tonumber(y), tonumber(m), tonumber(d)
end

local function computeCurrentStreak(entries_desc, is_consecutive, is_current_start)
    if #entries_desc == 0 or not is_current_start(entries_desc[1]) then return 0 end
    local current = 1
    for i = 2, #entries_desc do
        if is_consecutive(entries_desc[i - 1], entries_desc[i]) then
            current = current + 1
        else
            break
        end
    end
    return current
end

local function weekStartWday()
    local v = G_reader_settings and G_reader_settings:readSetting("reading_insights_heatmap_week_start")
    return v == "sunday" and 0 or 1
end

local function weekStartDate(date_str, week_start_wd)
    local y, m, d = parseDateYMD(date_str)
    if not y then return nil end
    local t = os.time{ year = y, month = m, day = d, hour = 12 }
    local wday = tonumber(os.date("%w", t))
    local offset = (week_start_wd == 0) and wday or ((wday + 6) % 7)
    return os.date("%Y-%m-%d", t - offset * DAY)
end

local function weekStartSqlExpr(week_start_wd)
    local dow = "strftime('%w', start_time, 'unixepoch', 'localtime')"
    local offset = (week_start_wd == 0) and dow or ("((" .. dow .. " + 6) % 7)")
    return "date(start_time, 'unixepoch', 'localtime', '-' || " .. offset .. " || ' days')"
end

local function isConsecutiveDay(prev_date, curr_date)
    local y, m, d = parseDateYMD(prev_date)
    if not y then return false end
    local prev_time = os.time({ year = y, month = m, day = d })
    return curr_date == os.date("%Y-%m-%d", prev_time - DAY)
end

local function isConsecutiveWeek(prev, curr)
    local py, pm, pd = parseDateYMD(prev)
    local cy, cm, cd = parseDateYMD(curr)
    if not py or not cy then return false end
    local pt = os.time{ year = py, month = pm, day = pd, hour = 12 }
    local ct = os.time{ year = cy, month = cm, day = cd, hour = 12 }
    return math.floor((pt - ct) / DAY + 0.5) == 7
end

-- Part of the day (same four 6-hour parts as Reading Insights' time-of-day
-- chart) with the most reading time, FOR THIS BOOK (card.book_id).
local function daypart(hour)
    if hour < 6 then return "night" end
    if hour < 12 then return "morning" end
    if hour < 18 then return "afternoon" end
    return "evening"
end

-- Streaks span all books; the reader type (part of day) is scoped to this
-- book alone (card.book_id), when known.
function M.readGlobal(conn, card)
    -- Today only, across every book (same per-page cap as a single book's
    -- today_time, just not restricted to id_book).
    local total_row = StatsDb.first(conn, string.format([[
        SELECT sum(durations)
        FROM (
            SELECT min(sum(duration), %d) AS durations
            FROM page_stat
            WHERE date(start_time, 'unixepoch', 'localtime') = date('now', 'localtime')
            GROUP BY id_book, page
        )]], maxSec()), 1)
    if total_row then card.all_books_time = num(total_row[1]) end

    local rows = StatsDb.all(conn,
        "SELECT DISTINCT date(start_time, 'unixepoch', 'localtime') AS d FROM page_stat_data ORDER BY d DESC", 1)
    local dates = {}
    for _, row in ipairs(rows) do dates[#dates + 1] = row[1] end

    local today_str = os.date("%Y-%m-%d")
    local yesterday = os.date("%Y-%m-%d", os.time() - DAY)
    card.streak_days = computeCurrentStreak(dates, isConsecutiveDay, function(first)
        return first == today_str or first == yesterday
    end)

    local week_start = weekStartWday()
    local wrows = StatsDb.all(conn, "SELECT DISTINCT " .. weekStartSqlExpr(week_start)
        .. " AS w FROM page_stat_data ORDER BY w DESC", 1)
    local weeks = {}
    for _, row in ipairs(wrows) do weeks[#weeks + 1] = row[1] end
    local this_week = weekStartDate(today_str, week_start)
    local last_week = weekStartDate(os.date("%Y-%m-%d", os.time() - 7 * DAY), week_start)
    card.streak_weeks = computeCurrentStreak(weeks, isConsecutiveWeek, function(first)
        return first == this_week or first == last_week
    end)

    local hours_sql
    if card.book_id then
        hours_sql = string.format([[
            SELECT CAST(strftime('%%H', start_time, 'unixepoch', 'localtime') AS INTEGER), sum(duration)
            FROM page_stat_data WHERE id_book = %d GROUP BY 1]], card.book_id)
    else
        hours_sql = [[
            SELECT CAST(strftime('%H', start_time, 'unixepoch', 'localtime') AS INTEGER), sum(duration)
            FROM page_stat_data GROUP BY 1]]
    end
    local hours = StatsDb.all(conn, hours_sql, 2)
    local buckets, best, best_secs = {}, nil, 0
    for _, row in ipairs(hours) do
        if row[1] and row[2] then
            local b = daypart(row[1])
            buckets[b] = (buckets[b] or 0) + row[2]
            if buckets[b] > best_secs then best, best_secs = b, buckets[b] end
        end
    end
    card.hour_bucket = best
end

-- ---------------------------------------------------------------------------
-- Cover
-- ---------------------------------------------------------------------------
-- Makes sure the cached cover belongs to this card's book. Extraction only
-- happens when the book changed (or nothing was cached yet), so a normal
-- sleep never has to open the document for it.
local function ensureCover(card, ui)
    if card.cover_file == card.file and (card.has_cover == false or Cache.hasCover()) then
        return
    end
    local bb
    pcall(function()
        local bookinfo = ui and ui.bookinfo
        if not bookinfo then
            bookinfo = require("apps/filemanager/filemanagerbookinfo")
        end
        if ui and ui.document then
            bb = bookinfo:getCoverImage(ui.document)
        else
            bb = bookinfo:getCoverImage(nil, card.file)
        end
    end)
    card.cover_file = card.file
    card.has_cover = bb ~= nil and Cache.saveCover(bb) or false
end

-- ---------------------------------------------------------------------------
-- Derived numbers
-- ---------------------------------------------------------------------------
function M.finalize(card)
    local percent = card.percent or 0
    card.finished = (card.status == "complete") or percent >= 100

    card.daily_avg_secs = nil
    if card.total_time and card.total_time > 0 and card.days_read and card.days_read > 0 then
        card.daily_avg_secs = card.total_time / card.days_read
    end

    -- Pages/day, the same "total / days actively read" shape as the time
    -- average above, just counting pages instead of seconds.
    card.daily_avg_pages = nil
    if card.pages_read and card.pages_read > 0 and card.days_read and card.days_read > 0 then
        card.daily_avg_pages = card.pages_read / card.days_read
    end

    card.pages_per_min = nil
    if card.avg_time and card.avg_time > 0 then
        card.pages_per_min = 60 / card.avg_time
    end

    card.time_left_secs, card.est_finish_ts = nil, nil
    if not card.finished and card.pages_left and card.avg_time then
        card.time_left_secs = math.max(0, card.pages_left * card.avg_time)
        if card.time_left_secs > 0 and card.daily_avg_secs then
            local days = card.time_left_secs / card.daily_avg_secs
            card.est_finish_ts = os.time() + math.floor(days * DAY + 0.5)
        end
    end

    -- Time left in the current chapter: same pages-left * avg_time formula
    -- as the whole-book figure above, just fed by chapter_pages_left
    -- instead of pages_left (see collectLive).
    card.chapter_time_left_secs = nil
    if not card.finished and card.chapter_pages_left and card.avg_time then
        card.chapter_time_left_secs = math.max(0, card.chapter_pages_left * card.avg_time)
    end

    -- Day the book was finished: the "finished" date in the book's own
    -- status if it has one, otherwise the last day it was read.
    card.finished_ts = nil
    if card.finished then
        card.finished_ts = dateToTs(card.finished_date) or card.last_read_ts
    end

    -- Days: since the first page_stat entry (Reading Insights' "days since
    -- started"); a finished book counts start -> finish instead.
    card.span_days = card.days_since_start
    if card.finished and card.started_ts and card.finished_ts then
        local from = noonOf(card.started_ts)
        local to = noonOf(card.finished_ts)
        card.span_days = math.max(0, math.floor((to - from) / DAY + 0.5))
    end
    return card
end

-- ---------------------------------------------------------------------------
-- Collectors
-- ---------------------------------------------------------------------------
local function carryOverCoverInfo(card)
    local prev = Cache.load()
    if prev and prev.file == card.file then
        card.cover_file = prev.cover_file
        card.has_cover = prev.has_cover
    end
end

-- A book is open.
function M.collectLive(ui)
    local doc = ui.document
    local file = doc.file
    local card = { file = file, updated = os.time() }

    local props = ui.doc_props or {}
    card.title = props.display_title or props.title or filenameTitle(file)
    card.authors = cleanAuthors(props.authors)
    card.series, card.series_index = cleanSeries(props)

    local stats = ui.statistics

    -- Read avg_time BEFORE insertDB(): insertDB() recomputes it from the
    -- database, which can differ slightly from the live in-memory value the
    -- footer and Reading Insights use.
    local live_avg = stats and num(stats.avg_time)
    if stats and stats.insertDB then
        pcall(stats.insertDB, stats)
    end

    card.percent, card.current_page, card.total_pages = liveProgress(ui)
    local summary = ui.doc_settings and ui.doc_settings:readSetting("summary")
    if type(summary) == "table" then
        card.status = summary.status
        card.finished_date = summary.modified
    end

    -- Pages left / time left: the same call and page number Reading Insights uses.
    local pageno = (doc.getCurrentPage and doc:getCurrentPage()) or 1
    local ok_left, pages_left = pcall(doc.getTotalPagesLeft, doc, pageno)
    if ok_left then card.pages_left = num(pages_left) end
    if live_avg and live_avg > 0 then card.avg_time = live_avg end

    -- Pages left in the CURRENT chapter: the same call (with the same
    -- second argument) and fallback Reading Insights' ChapterInfo.
    -- getChapterPagesLeft uses - falls back to the whole book's pages
    -- left when the TOC has no usable chapter data. Only available with
    -- a live document (ui.toc/ui.document), so this - and the time it
    -- derives in finalize() - stays nil for a card rebuilt from the
    -- sidecar/statistics DB with no book open.
    if ui.toc and ui.toc.getChapterPagesLeft then
        local ok_ch, chapter_left = pcall(ui.toc.getChapterPagesLeft, ui.toc, pageno, true)
        if ok_ch and chapter_left ~= nil then
            card.chapter_pages_left = num(chapter_left)
        elseif ui.document then
            local ok_doc, doc_left = pcall(ui.document.getTotalPagesLeft, ui.document, pageno)
            if ok_doc then card.chapter_pages_left = num(doc_left) end
        end
    end

    -- Highlight count + a random quote: from the live, in-memory settings
    -- (most current).
    if ui.doc_settings then
        local ok_hl, hl = pcall(countHighlights, ui.doc_settings)
        if ok_hl then card.highlights_count = hl end
        card.quote_text = pickRandomQuote(ui.doc_settings)
    end

    local book_id = stats and stats.id_curr_book
    StatsDb.withDb(nil, function(conn)
        if not book_id then
            local sc = M.readSidecar(file)
            book_id = findBookId(conn, file, sc, props.title, props.authors)
        end
        card.book_id = book_id
        if book_id then fillBookStats(conn, card, book_id) end
        M.readGlobal(conn, card)
    end)

    -- Reading time: the statistics plugin's own total, when it is loaded.
    if stats and stats.id_curr_book and stats.getPageTimeTotalStats then
        local ok, _pages, time_val = pcall(stats.getPageTimeTotalStats, stats, stats.id_curr_book)
        if ok and num(time_val) and num(time_val) > 0 then card.total_time = num(time_val) end
    end

    if not card.avg_time and card.total_time and card.pages_read and card.pages_read > 0 then
        card.avg_time = card.total_time / card.pages_read
    end

    carryOverCoverInfo(card)
    ensureCover(card, ui)
    return M.finalize(card)
end

-- No book is open; rebuild from the sidecar and the statistics database.
function M.collectFromFile(file, ui)
    if not file then return nil end
    local card = { file = file, updated = os.time() }
    local sc = M.readSidecar(file)

    local props = sc.props
    if ui and ui.bookinfo then
        local ok, p = pcall(function() return ui.bookinfo:getDocProps(file, nil, true) end)
        if ok and type(p) == "table" then props = p end
    end
    props = props or {}
    card.title = props.display_title or props.title or filenameTitle(file)
    card.authors = cleanAuthors(props.authors)
    card.series, card.series_index = cleanSeries(props)
    card.percent = sc.percent
    card.status = sc.status
    card.finished_date = sc.modified
    card.highlights_count = sc.highlights
    card.quote_text = sc.quote

    StatsDb.withDb(nil, function(conn)
        local book_id = findBookId(conn, file, sc, props.title, props.authors)
        card.book_id = book_id
        if book_id then fillBookStats(conn, card, book_id) end
        M.readGlobal(conn, card)
    end)

    -- Same formula the statistics plugin uses for its avg_time.
    if card.total_time and card.pages_read and card.pages_read > 0 then
        card.avg_time = card.total_time / card.pages_read
    end
    if card.stats_pages and card.percent then
        card.pages_left = math.max(0, card.stats_pages * (1 - card.percent / 100))
        -- No document is open to ask for the exact current page, so
        -- approximate it from the saved percentage and the statistics
        -- database's page count (close enough for the file manager card).
        card.total_pages = card.stats_pages
        card.current_page = Math.round(card.stats_pages * card.percent / 100)
    end

    carryOverCoverInfo(card)
    ensureCover(card, ui)
    return M.finalize(card)
end

-- Runs right before a cached card is drawn (no book open): refreshes what
-- can change without one - the book's status (e.g. "mark as finished" in the
-- file manager), streaks and the reader type. (Progress is kept from the
-- snapshot: it may be page-map based, which the sidecar does not record.)
function M.prepare(card)
    if card.file then
        local sc = M.readSidecar(card.file)
        if not card.percent and sc.percent then card.percent = sc.percent end
        if sc.status then card.status = sc.status end
        if sc.modified then card.finished_date = sc.modified end
        if sc.highlights then card.highlights_count = sc.highlights end
        -- Re-picked every time (not "if sc.quote then"): a book that lost
        -- its last highlight since the previous snapshot should lose its
        -- quote too, and a fresh pick is exactly what "random" means here.
        card.quote_text = sc.quote
    end
    -- The snapshot is taken in onCloseDocument, which runs BEFORE the
    -- statistics plugin writes the last page (its own onCloseDocument does
    -- onPageUpdate + insertDB afterwards). So everything that comes from
    -- the statistics DB is re-read here, when the DB is already complete:
    -- reading time, pages read, days, daily average, avg_time (pace).
    StatsDb.withDb(nil, function(conn)
        local book_id = card.book_id
        if not book_id and card.file then
            local sc = M.readSidecar(card.file)
            book_id = findBookId(conn, card.file, sc, card.title, card.authors)
            card.book_id = book_id
        end
        if book_id then
            fillBookStats(conn, card, book_id)
            -- Same formula the statistics plugin uses for its avg_time.
            if card.total_time and card.pages_read and card.pages_read > 0 then
                card.avg_time = card.total_time / card.pages_read
            end
        end
        M.readGlobal(conn, card)
    end)
    return M.finalize(card)
end

M._weekStartDate = weekStartDate
return M
