--[[
Book card - one right-aligned "big value over small label" cell, as used in
the statistics column of the card.

  StatCell:new{
      value = "12h 51 min", label = "Reading Time",
      width = <px>,
      value_face = <face>, label_face = <face>,
      color = <text colour>,                     -- shared fallback for both
      value_color = <text colour>,                -- overrides `color` for the value
      label_color = <text colour>,                -- overrides `color` for the label
  }
]]--

local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local RightContainer = require("ui/widget/container/rightcontainer")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")

local StatCell = RightContainer:extend{
    value = "",
    label = "",
    width = 100,
    value_face = nil,
    label_face = nil,
    color = nil,        -- shared text colour fallback, defaults to black
    value_color = nil,
    label_color = nil,
}

function StatCell:init()
    local group = VerticalGroup:new{
        align = "right",
        TextWidget:new{
            text = self.value,
            face = self.value_face,
            max_width = self.width,
            fgcolor = self.value_color or self.color or Blitbuffer.COLOR_BLACK,
        },
        TextWidget:new{
            text = self.label,
            face = self.label_face,
            max_width = self.width,
            fgcolor = self.label_color or self.color or Blitbuffer.COLOR_BLACK,
        },
    }
    self.dimen = Geom:new{ w = self.width, h = group:getSize().h }
    self[1] = group
end

return StatCell
