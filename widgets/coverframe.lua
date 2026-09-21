--[[
Book Card - a cover with a frame and (optionally) rounded corners.

KOReader's FrameContainer paints its child as a plain rectangle, so a cover
inside a rounded FrameContainer pokes out past the rounded border. This
widget instead:

  1. fills the whole rectangle with the frame colour,
  2. paints the cover inset by the frame thickness,
  3. for each corner, per pixel of the radius x radius corner square:
       outside the outer arc          -> background colour (cuts the corner)
       between outer and inner arc    -> frame colour (the rounded frame)
       inside the inner arc           -> left alone (the cover)

The two arcs share one centre per corner, so the ring stays clean - the same
technique Bookshelf's rounded cover card uses.

  CoverFrame:new{
      inner  = <widget of size (width - 2*border) x (height - 2*border)>,
      width  = <outer px>, height = <outer px>,
      border = <frame thickness px>,
      radius = <corner radius px, 0 = square>,
      bg     = <colour behind the card>,
      fg     = <frame colour>,
  }
]]--

local Geom = require("ui/geometry")
local Widget = require("ui/widget/widget")

local CoverFrame = Widget:extend{
    inner = nil,
    width = 0,
    height = 0,
    border = 1,
    radius = 0,
    bg = nil,
    fg = nil,
}

function CoverFrame:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

function CoverFrame:paintTo(bb, x, y)
    local w, h, b, r = self.width, self.height, self.border, self.radius
    self.dimen = Geom:new{ x = x, y = y, w = w, h = h }

    bb:paintRect(x, y, w, h, self.fg)
    if self.inner then
        self.inner:paintTo(bb, x + b, y + b)
    end
    if r <= 0 then return end

    r = math.min(r, math.floor(math.min(w, h) / 2))
    local inner_r = r - b
    for i = 0, r - 1 do
        local dx = r - (i + 0.5)
        for j = 0, r - 1 do
            local dy = r - (j + 0.5)
            local d = math.sqrt(dx * dx + dy * dy)
            local color
            if d > r then
                color = self.bg
            elseif d > inner_r then
                color = self.fg
            end
            if color then
                bb:paintRect(x + i,         y + j,         1, 1, color)
                bb:paintRect(x + w - 1 - i, y + j,         1, 1, color)
                bb:paintRect(x + i,         y + h - 1 - j, 1, 1, color)
                bb:paintRect(x + w - 1 - i, y + h - 1 - j, 1, 1, color)
            end
        end
    end
end

return CoverFrame
