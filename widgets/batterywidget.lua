--[[
Book Card - a tiny battery glyph drawn with plain rectangles (no icon font
needed): outline, terminal nub, and a fill proportional to the charge.

Drawn upright (portrait), like KOReader's own battery icon: a small nub
centred on top, the body below it, filled from the bottom up.

  BatteryWidget:new{ percent = 87, width = <px>, height = <px>, color = <colour> }
]]--

local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local Widget = require("ui/widget/widget")

local BatteryWidget = Widget:extend{
    percent = 100,
    width = 14,
    height = 22,
    charging = false,
    color = nil,   -- defaults to black
}

function BatteryWidget:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

-- Blitbuffer.colorFromString("#RRGGBB") always returns a 32bit RGB color
-- object, even for plain black/white/gray. bb:paintRect only handles the
-- handful of native 8bit grayscale colors (Blitbuffer.COLOR_BLACK/GRAY/
-- WHITE/...) correctly - on an actual (typically 8bit/grayscale) e-ink
-- framebuffer, feeding it an arbitrary RGB32 color silently misrenders
-- (usually as black). Route every rectangle through this instead, so a
-- custom battery color from the Colors menu renders correctly too.
local function paintRect(bb, x, y, w, h, color)
    if Blitbuffer.isColor8(color) then
        bb:paintRect(x, y, w, h, color)
    else
        bb:paintRectRGB32(x, y, w, h, color)
    end
end

function BatteryWidget:paintTo(bb, x, y)
    local w, h = self.width, self.height
    local nub_h = math.max(1, math.floor(h / 10))
    local nub_w = math.max(2, math.floor(w * 0.5))
    local body_h = h - nub_h
    local body_y = y + nub_h
    local t = math.max(1, math.floor(w / 8))            -- outline thickness
    local black = self.color or Blitbuffer.COLOR_BLACK

    -- terminal nub, centred on top of the body
    local nub_x = x + math.floor((w - nub_w) / 2)
    paintRect(bb, nub_x, y, nub_w, nub_h, black)

    -- body outline
    paintRect(bb, x, body_y, w, t, black)                       -- top
    paintRect(bb, x, body_y + body_h - t, w, t, black)          -- bottom
    paintRect(bb, x, body_y, t, body_h, black)                  -- left
    paintRect(bb, x + w - t, body_y, t, body_h, black)          -- right

    -- fill, growing upward from the bottom
    local pad = t + 1
    local inner_w = w - 2 * pad
    local inner_h = body_h - 2 * pad
    local fill_h = math.floor(inner_h * math.max(0, math.min(100, self.percent)) / 100 + 0.5)
    if fill_h > 0 and inner_w > 0 then
        paintRect(bb, x + pad, body_y + body_h - pad - fill_h, inner_w, fill_h, black)
    end
end

return BatteryWidget
