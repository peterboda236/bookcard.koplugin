--[[
Book card - Bookshelf-echoing cover styles: "spine" (the book edge-on) and
"faceout" (the book turned face-out, cover showing) - see that plugin's
lib/bookshelf_spine_layout.lua and lib/bookshelf_spine_shelf.lua.

  SpineCover.build(card, max_w, max_h)        -> widget, outer_w, outer_h  (edge-on)
  SpineCover.buildFaceOut(card, max_w, max_h) -> widget, outer_w, outer_h  (face-out)

This is a simplified, self-contained port for a SINGLE book (bookcard only
ever shows one at a time - no shelf, no row to pack, no lift/tilt/selection
animation, no wallpaper-aware corner cutting). Both styles share:

  - a colour sampled from the book's own cover image for the boards/page
    block (same idea as Bookshelf's SpineShelf.bookLook), a stable hashed
    tone from the title when there's no cover to sample;
  - a "page block" sliver, boards rising past it on both sides, standing
    for the pages you'd see looking at a book on a real shelf - above the
    spine in the edge-on style, above the cover in the face-out style;
  - the page block's size follows the book's own numbers where we have
    them: the edge-on spine's WIDTH from the page count (thicker book,
    wider spine - SpineLayout.spineWidthDp) and its page-block HEIGHT from
    the cover's own aspect ratio (SpineLayout.topEdgeHeight); the face-out
    cover keeps its true aspect ratio and its page block's height instead
    comes from that same page-count thickness, foreshortened
    (SpineLayout.faceOutWidth / the depth maths in bookshelf_spine_shelf.lua).

`max_w` x `max_h` bounds the box each has to fit in (frame included, same
convention as buildCover() in views/card_view.lua).
]]--

local deps  = ...
local Cache = deps and deps.Cache

local Blitbuffer      = require("ffi/blitbuffer")
local Device           = require("device")
local Font             = require("ui/font")
local Geom             = require("ui/geometry")
local CenterContainer  = require("ui/widget/container/centercontainer")
local FrameContainer   = require("ui/widget/container/framecontainer")
local ImageWidget      = require("ui/widget/imagewidget")
local TextBoxWidget    = require("ui/widget/textboxwidget")
local Widget           = require("ui/widget/widget")
local Screen           = Device.screen

local function S(n)
    return Screen:scaleBySize(n)
end

-- ---------------------------------------------------------------------------
-- Geometry (ported from Bookshelf's lib/bookshelf_spine_layout.lua)
-- ---------------------------------------------------------------------------
local DEFAULT_PAGES = 300  -- assumed when the page count is unknown
local MIN_PAGES      = 60   -- everything thinner renders at MIN_W_DP
local MAX_PAGES      = 1600 -- everything thicker renders at MAX_W_DP
local MIN_W_DP       = 32
local MAX_W_DP       = 96

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

-- The cover width when a book faces outwards at a given displayed cover
-- height, i.e. the cover kept aspect-true: SpineLayout.faceOutWidth.
local function faceOutWidth(face_h, aspect)
    if not aspect or aspect <= 0 then aspect = DEFAULT_ASPECT end
    local w = math.floor(face_h / aspect + 0.5)
    if w < 1 then w = 1 end
    return w
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

-- ---------------------------------------------------------------------------
-- Face-out: the book turned to show its cover, a page block (boards +
-- pages, seen from above) sitting on top of it instead of a drop shadow -
-- SpineShelf's FaceOutTopBlock, ported.
-- ---------------------------------------------------------------------------
local function paintFaceOutTopBlock(bb, x, y, w, h, r, g, b)
    if w < 6 or h < 3 then return end
    local board = math.max(2, math.min(S(3), math.floor(h * 0.3)))
    local rb = math.max(1, math.floor(board / 2))
    local sx0, sy0 = x + board, y + board
    local sw, sh = w - board - rb, h - board
    if sw > 2 and sh > 1 then
        bb:paintRect(sx0, sy0, sw, sh, PAGE_TONE)
        -- Page lines running the width of the block, like the edges of
        -- stacked pages seen from above.
        local step = math.max(2, math.floor(S(1.4)) + 1)
        local cy = sy0 + 1
        while cy < sy0 + sh do
            bb:paintRect(sx0, cy, sw, 1, STRIPE_TONE)
            cy = cy + step
        end
    end
    local fill = tint(r, g, b, BOARD_SHADE)
    local ch = math.max(2, S(1))
    bb:paintRect(x, y + ch, board, h - ch, fill)           -- left board
    bb:paintRect(x + ch, y, w - ch, board, fill)            -- top board
    bb:paintRect(x + w - rb, y + board, rb, h - board, fill) -- right sliver
end

local SpineFaceOut = Widget:extend{
    width = 0, height = 0,
    depth = 0,      -- page-block height, px (0 = too small to show)
    hairline = 1,
    r = 0, g = 0, b = 0,
    cover = nil,    -- the cover widget (real image, or the fallback plate)
}

function SpineFaceOut:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

function SpineFaceOut:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    local w, depth, hl = self.width, self.depth, self.hairline
    if depth > 0 then
        paintFaceOutTopBlock(bb, x, y, w, depth, self.r, self.g, self.b)
    end
    if self.cover then
        self.cover:paintTo(bb, x, y + depth)
    end
    -- A thin board-coloured frame around the cover, tying it visually to
    -- the page block sitting on it.
    local board = tint(self.r, self.g, self.b, BOARD_SHADE)
    local cover_h = self.height - depth
    bb:paintRect(x, y + depth, w, hl, board)
    bb:paintRect(x, y + self.height - hl, w, hl, board)
    bb:paintRect(x, y + depth, hl, cover_h, board)
    bb:paintRect(x + w - hl, y + depth, hl, cover_h, board)
end

-- SpineCover.buildFaceOut(card, max_w, max_h) -> widget, outer_w, outer_h
function SpineCover.buildFaceOut(card, max_w, max_h)
    max_h = max_h or S(120)

    -- The real cover, decoded once - sampled for the boards' colour AND
    -- (further down) handed to the ImageWidget that paints it, so the
    -- decode is never done twice.
    local cover_bb, r, g, b, aspect
    local has_cover = Cache and Cache.hasCover and Cache.hasCover()
        and (not card or card.has_cover ~= false)
    if has_cover then
        local ok = pcall(function()
            local RenderImage = require("ui/renderimage")
            local bb = RenderImage:renderImageFile(Cache.coverPath(), false, nil, nil)
            if not bb then return end
            local iw, ih = bb:getWidth(), bb:getHeight()
            if iw and ih and iw > 0 then aspect = ih / iw end
            local sr, sg, sb = sampleAverage(bb)
            if sr then r, g, b = contrastClamp(sr, sg, sb) end
            cover_bb = bb
        end)
        if not ok then cover_bb = nil end
    end
    if not r then
        r, g, b = fallbackLook(card and card.title)
    end
    aspect = aspect or DEFAULT_ASPECT

    -- Depth: the page block above the cover, from this book's thickness -
    -- the same page-count-to-width mapping the edge-on spine uses,
    -- foreshortened by the same camera pitch (SpineLayout.faceOutWidth's
    -- sibling maths in bookshelf_spine_shelf.lua).
    local pages = card and (card.total_pages or card.stats_pages)
    local depth_dp = spineWidthDp(pages) * autoThickness(max_h)
    local depth = math.floor(S(depth_dp) * VIEW_SIN)
    local d_max = math.floor(max_h * 0.15)
    if depth > d_max then depth = d_max end
    if depth < S(3) then depth = S(3) end

    -- The cover's own displayed height, kept aspect-true - a real book's
    -- front face, not squeezed to fit.
    local face_h = max_h - depth
    if face_h < S(24) then face_h = S(24) end
    local w = faceOutWidth(face_h, aspect)
    if max_w and w > max_w then
        local scale = max_w / w
        w = max_w
        face_h = math.max(S(24), math.floor(face_h * scale))
        depth = math.max(1, math.floor(depth * scale))
    end

    -- The cover itself: the real image, scaled to the box just computed -
    -- or, with no cover to show, a flat plate in the sampled/fallback
    -- colour carrying the title, so the face-out still reads as a book.
    local cover_widget
    if cover_bb then
        local ok = pcall(function()
            local img = ImageWidget:new{
                image = cover_bb, image_disposable = true,
                width = w, height = face_h, scale_factor = 0,
            }
            img:getSize()
            cover_widget = img
        end)
        if not ok then cover_widget = nil end
    end
    if not cover_widget then
        local luma = 0.299 * r + 0.587 * g + 0.114 * b
        local fg = (luma < 140) and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
        local plate_bg = tint(r, g, b, 1)
        cover_widget = FrameContainer:new{
            bordersize = 0, padding = 0, margin = 0,
            background = plate_bg,
            width = w, height = face_h,
            CenterContainer:new{
                dimen = Geom:new{ w = w, h = face_h },
                TextBoxWidget:new{
                    text = (card and card.title) or "",
                    face = Font:getFace("NotoSans-Bold.ttf", 16),
                    width = math.max(10, w - S(16)),
                    alignment = "center",
                    fgcolor = fg,
                    bgcolor = plate_bg,
                },
            },
        }
    end

    local widget = SpineFaceOut:new{
        width = w, height = face_h + depth, depth = depth,
        hairline = math.max(1, S(1)),
        r = r, g = g, b = b,
        cover = cover_widget,
    }
    return widget, w, face_h + depth
end

return SpineCover

