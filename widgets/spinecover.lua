--[[
Book card - a "book spine" cover style, echoing Bookshelf's spine-out shelf
view (see that plugin's lib/bookshelf_spine_layout.lua and
lib/bookshelf_spine_shelf.lua): instead of the flat front cover, draw the
book edge-on - a coloured spine (width ~ page count: a thicker book gets a
wider spine) with a lighter "page block" sliver above it (the pages you'd
see looking down on a book standing on a real shelf), and boards a shade
darker than the spine colour framing both.

This is a simplified, self-contained port for a SINGLE book (bookcard only
ever shows one at a time - no shelf, no row to pack, no lift/tilt/selection
animation, no wallpaper-aware corner cutting). The two things worth keeping
faithful to Bookshelf are:

  - the spine's colour: the AVERAGE colour sampled from the book's own
    cover image (same idea Bookshelf's SpineShelf.bookLook uses), so it
    still looks like *that* book and not a random swatch; a stable
    hashed tone from the title when there's no cover to sample.
  - the geometry: spine width from the page count (SpineLayout.spineWidthDp
    there), spine height filling the box, and the page-block sliver's
    height from the book's own cover aspect ratio
    (SpineLayout.topEdgeHeight there) - so, per the aspect ratio question:
    yes, a real cover's proportions (when known) size that sliver; an
    unknown aspect falls back to a typical paperback's.

  SpineCover.build(card, max_w, max_h) -> widget, outer_w, outer_h

`max_w` x `max_h` bounds the box the spine has to fit in (frame included,
same convention as buildCover() in views/card_view.lua). The spine FILLS
max_h (a book stands to the top of its shelf slot) and is only as WIDE as
its "thickness" calls for - capped to max_w - so, unlike the normal cover,
the returned outer_w is very likely narrower than max_w.
]]--

local deps  = ...
local Cache = deps and deps.Cache

local Blitbuffer = require("ffi/blitbuffer")
local Device      = require("device")
local Geom        = require("ui/geometry")
local Widget      = require("ui/widget/widget")
local Screen      = Device.screen

local function S(n)
    return Screen:scaleBySize(n)
end

-- ---------------------------------------------------------------------------
-- Geometry (ported from Bookshelf's lib/bookshelf_spine_layout.lua)
-- ---------------------------------------------------------------------------
local DEFAULT_PAGES = 300  -- assumed when the page count is unknown
local MIN_PAGES      = 60   -- everything thinner renders at MIN_W_DP
local MAX_PAGES      = 1200 -- everything thicker renders at MAX_W_DP
local MIN_W_DP       = 14
local MAX_W_DP       = 52

local DEFAULT_ASPECT = 1.5  -- assumed when the cover's own aspect is unknown

-- Auto thickness: the spine's width also scales with the box's own height,
-- so a tall card doesn't stand a needle-thin book (same maths as
-- SpineLayout.autoThickness, just fed already-scaled px instead of dp -
-- the ratio to the reference height comes out the same either way).
local THICKNESS_REF_H = 240
local THICKNESS_EXP   = 0.6
local THICKNESS_MIN   = 0.7
local THICKNESS_MAX   = 2.2

local VIEW_SIN         = 0.208 -- camera pitch: SpineLayout.VIEW_SIN
local TOP_EDGE_MAX_FRAC = 0.2   -- the page block never eats more than this

local function spineWidthDp(pages)
    pages = tonumber(pages)
    if not pages or pages <= 0 then pages = DEFAULT_PAGES end
    if pages < MIN_PAGES then pages = MIN_PAGES end
    if pages > MAX_PAGES then pages = MAX_PAGES end
    local t = (pages - MIN_PAGES) / (MAX_PAGES - MIN_PAGES)
    return MIN_W_DP + t * (MAX_W_DP - MIN_W_DP)
end

local function autoThickness(row_h_px)
    if not row_h_px or row_h_px <= 0 then return 1 end
    local ref = S(THICKNESS_REF_H)
    if ref <= 0 then return 1 end
    local scale = (row_h_px / ref) ^ THICKNESS_EXP
    if scale < THICKNESS_MIN then scale = THICKNESS_MIN end
    if scale > THICKNESS_MAX then scale = THICKNESS_MAX end
    return scale
end

-- The page-block sliver you see above a spine-out book: its depth into the
-- shelf is the cover's own WIDTH (book_h / aspect), foreshortened by the
-- camera's pitch. See SpineLayout.topEdgeHeight for the long version.
local function topEdgeHeight(book_h, aspect, min_px)
    if not book_h or book_h <= 0 then return 0 end
    if not aspect or aspect <= 0 then aspect = DEFAULT_ASPECT end
    local edge = math.floor((book_h / aspect) * VIEW_SIN)
    local e_max = math.floor(book_h * TOP_EDGE_MAX_FRAC)
    min_px = min_px or 0
    if edge < min_px then edge = min_px end
    if edge > e_max then edge = e_max end
    if edge < 0 then edge = 0 end
    return edge
end

-- ---------------------------------------------------------------------------
-- Colour (ported from Bookshelf's lib/bookshelf_spine_shelf.lua)
-- ---------------------------------------------------------------------------
local SAMPLE_STEPS  = 8    -- sample an 8x8 grid across the cover
local MAX_FILL_LUMA = 130  -- keep the spine dark enough to read on e-ink
local GRAD_D         = 0.13 -- spine body gradient half-range (a hint of roundness)
local BOARD_SHADE    = 0.45 -- boards/border: this fraction of the spine colour

local function sampleAverage(bb)
    local n, r, g, b = 0, 0, 0, 0
    local w, h = bb:getWidth(), bb:getHeight()
    if not (w and h and w > 1 and h > 1) then return nil end
    for sy = 0, SAMPLE_STEPS - 1 do
        for sx = 0, SAMPLE_STEPS - 1 do
            local px = math.floor((sx + 0.5) * w / SAMPLE_STEPS)
            local py = math.floor((sy + 0.5) * h / SAMPLE_STEPS)
            local p = bb:getPixel(px, py)
            local c = p and p.getColorRGB32 and p:getColorRGB32() or nil
            if c then
                n = n + 1
                r = r + c.r; g = g + c.g; b = b + c.b
            end
        end
    end
    if n == 0 then return nil end
    return r / n, g / n, b / n
end

local function contrastClamp(r, g, b)
    local luma = 0.299 * r + 0.587 * g + 0.114 * b
    if luma > MAX_FILL_LUMA and luma > 0 then
        local f = MAX_FILL_LUMA / luma
        r, g, b = r * f, g * f, b * f
    end
    return math.floor(r + 0.5), math.floor(g + 0.5), math.floor(b + 0.5)
end

-- A coverless book still gets a stable, slightly varied cloth-binding tone
-- (hash of its title) rather than one flat grey square.
local function fallbackLook(label)
    if not label or label == "" then label = "?" end
    local h = 5381
    for i = 1, #label do h = (h * 33 + label:byte(i)) % 16777213 end
    local base = 58 + (h % 40)
    local r = base + (h % 23)
    local g = base + (math.floor(h / 23) % 23)
    local b = base + (math.floor(h / 529) % 23)
    return r, g, b
end

-- The spine body's left-to-right gradient: darker at the left edge to
-- lighter at the right, for a very slight rounded-cylinder impression.
local function rampF(col, w)
    local t = (w and w > 1) and (col / (w - 1)) or 0.5
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    return (1 - GRAD_D) + 2 * GRAD_D * t
end

local function tint(r, g, b, f)
    return Blitbuffer.ColorRGB32(
        math.floor(math.min(255, r * f) + 0.5),
        math.floor(math.min(255, g * f) + 0.5),
        math.floor(math.min(255, b * f) + 0.5), 0xFF)
end

local PAGE_TONE = Blitbuffer.ColorRGB32(0xF0, 0xEC, 0xE0, 0xFF)
local STRIPE_TONE = Blitbuffer.ColorRGB32(0xC8, 0xC0, 0xB0, 0xFF)

-- bookLook(card) -> r, g, b, aspect
-- Colour sampled from the actual cached cover when there is one; a stable
-- fallback tone (and a typical-paperback aspect) otherwise.
local function bookLook(card)
    local title = card and card.title
    if Cache and Cache.hasCover and Cache.hasCover()
        and (not card or card.has_cover ~= false) then
        local r, g, b, aspect
        local ok = pcall(function()
            local RenderImage = require("ui/renderimage")
            local bb = RenderImage:renderImageFile(Cache.coverPath(), false, nil, nil)
            if not bb then return end
            local w, h = bb:getWidth(), bb:getHeight()
            if w and h and w > 0 then aspect = h / w end
            local sr, sg, sb = sampleAverage(bb)
            if bb.free then bb:free() end
            if sr then r, g, b = contrastClamp(sr, sg, sb) end
        end)
        if ok and r then return r, g, b, aspect or DEFAULT_ASPECT end
    end
    local r, g, b = fallbackLook(title)
    return r, g, b, DEFAULT_ASPECT
end

-- ---------------------------------------------------------------------------
-- The widget
-- ---------------------------------------------------------------------------
local SpineCover = Widget:extend{
    width = 0, height = 0,
    edge_h = 0,     -- page-block sliver height, px (0 = too small to show)
    board_w = 0,    -- board end-cap width inside the page block, px
    hairline = 1,
    r = 0, g = 0, b = 0, -- spine colour
}

function SpineCover:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

function SpineCover:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    local w, h, edge_h, hl = self.width, self.height, self.edge_h, self.hairline
    local board = tint(self.r, self.g, self.b, BOARD_SHADE)
    local body_top, body_h = y + edge_h, h - edge_h

    -- The spine body: a left-to-right gradient, boarded on all four sides.
    for i = 0, w - 1 do
        bb:paintRect(x + i, body_top, 1, body_h, tint(self.r, self.g, self.b, rampF(i, w)))
    end
    bb:paintRect(x, body_top, w, hl, board)               -- top
    bb:paintRect(x, y + h - hl, w, hl, board)              -- bottom
    bb:paintRect(x, body_top, hl, body_h, board)           -- left
    bb:paintRect(x + w - hl, body_top, hl, body_h, board)  -- right

    -- The page block: the sliver of pages you'd see above a spine-out
    -- book, with the boards rising past it on both sides - this is the
    -- "line above the spine" the reader asked for.
    if edge_h > 0 then
        local bw = math.min(self.board_w, math.floor(w / 2))
        bb:paintRect(x, y, bw, edge_h, board)
        bb:paintRect(x + w - bw, y, bw, edge_h, board)
        if w - 2 * bw > 0 then
            bb:paintRect(x + bw, y, w - 2 * bw, edge_h, PAGE_TONE)
            -- A couple of faint page lines, for a little texture.
            local step = math.max(2, math.floor((w - 2 * bw) / 4))
            local cx = x + bw + step
            while cx < x + w - bw do
                bb:paintRect(cx, y + hl, 1, math.max(0, edge_h - hl), STRIPE_TONE)
                cx = cx + step
            end
        end
        bb:paintRect(x, y, w, hl, board) -- top cap
    end
end

-- SpineCover.build(card, max_w, max_h) -> widget, outer_w, outer_h
function SpineCover.build(card, max_w, max_h)
    local r, g, b, aspect = bookLook(card)

    local hairline = math.max(1, S(1))
    local pages = card and (card.total_pages or card.stats_pages)
    local spine_w = math.floor(S(spineWidthDp(pages)) * autoThickness(max_h) + 0.5)
    if spine_w < S(10) then spine_w = S(10) end
    if max_w and spine_w > max_w then spine_w = max_w end
    if spine_w < 2 * hairline + 1 then spine_w = 2 * hairline + 1 end
    local spine_h = math.max(S(10), max_h or S(10))

    local edge_h = 0
    if spine_h >= S(60) then
        edge_h = topEdgeHeight(spine_h, aspect, S(5))
    end
    local board_w = math.max(2, math.min(S(3), math.floor(spine_w * 0.1)))

    local widget = SpineCover:new{
        width = spine_w, height = spine_h,
        edge_h = edge_h, board_w = board_w, hairline = hairline,
        r = r, g = g, b = b,
    }
    return widget, spine_w, spine_h
end

return SpineCover
