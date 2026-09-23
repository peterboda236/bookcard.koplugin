--[[
Book card - a small SVG icon that follows the card's colour scheme.

KOReader renders black SVGs. On a light card that is what we want; when the
card is painted "flipped" (white on black, see card_view's palette) the icon
is drawn on a scratch buffer and blitted inverted, so it comes out white.

  SvgIcon:new{ file = <path>, size = <px>, inverted = false }

`is_icon` tells ImageWidget not to pre-invert the image in night mode (which
would make a black icon vanish into a black night-mode background).
]]--

local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local ImageWidget = require("ui/widget/imagewidget")
local Widget = require("ui/widget/widget")

local SvgIcon = Widget:extend{
    file = nil,
    size = 24,
    inverted = false,
}

function SvgIcon:init()
    self.image = ImageWidget:new{
        file = self.file,
        width = self.size,
        height = self.size,
        scale_factor = 0,
        file_do_cache = false,
        alpha = true,
        is_icon = true,
    }
    self.image:getSize()  -- render now, so a bad file fails here, not while painting
end

function SvgIcon:getSize()
    return Geom:new{ w = self.size, h = self.size }
end

function SvgIcon:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.size, h = self.size }
    if not self.inverted then
        self.image:paintTo(bb, x, y)
        return
    end
    -- Night/dark mode: paint the icon in white instead of its native black.
    --
    -- The previous approach filled a scratch buffer with white, painted the
    -- icon onto it, then blitted the whole thing inverted. invertblitFrom
    -- is a solid blit - it has no idea which pixels were "icon" and which
    -- were just the white filler - so it painted the ENTIRE size x size
    -- square (as black, after inversion) instead of just the icon. That
    -- solid square is the black box that showed up behind these icons in
    -- night mode.
    --
    -- Fix: build a coverage mask instead (same trick Wallpaper.mask() uses
    -- for text). Render the icon (black on white) onto an 8bpp scratch,
    -- invert it so the icon's own pixels become the bright values, then
    -- paint using that as an ALPHA channel: colorblitFrom only paints
    -- where the icon actually drew something, leaving the background -
    -- and whatever is behind it - alone.
    local scratch = Blitbuffer.new(self.size, self.size, Blitbuffer.TYPE_BB8)
    scratch:fill(Blitbuffer.COLOR_WHITE)
    self.image:paintTo(scratch, 0, 0)
    scratch:invertRect(0, 0, self.size, self.size)
    bb:colorblitFrom(scratch, x, y, 0, 0, self.size, self.size, Blitbuffer.COLOR_WHITE)
    scratch:free()
end

function SvgIcon:free()
    if self.image then self.image:free() end
end

return SvgIcon
