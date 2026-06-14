local Blitbuffer      = require("ffi/blitbuffer")
local Font            = require("ui/font")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local InputContainer  = require("ui/widget/container/inputcontainer")
local RenderText      = require("ui/rendertext")
local Size            = require("ui/size")
local UIManager       = require("ui/uimanager")

local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local SlitherlinkBoard = lrequire("board")

local C_BG      = Blitbuffer.COLOR_WHITE
local C_DOT     = Blitbuffer.COLOR_BLACK
local C_LINE    = Blitbuffer.COLOR_BLACK
local C_CROSS   = Blitbuffer.COLOR_GRAY_4
local C_WRONG   = Blitbuffer.COLOR_GRAY_A
local C_NUM     = Blitbuffer.COLOR_BLACK
local C_NUM_SOL = Blitbuffer.COLOR_GRAY_4

-- ---------------------------------------------------------------------------
-- SlitherlinkBoardWidget
-- A custom widget: (n+1)×(n+1) dot grid, edges between dots.
-- ---------------------------------------------------------------------------

local SlitherlinkBoardWidget = InputContainer:extend{
    board      = nil,
    size_ratio = 0.82,
    onEdgeAction = nil,  -- function(kind, r, c, is_hold)
}

function SlitherlinkBoardWidget:init()
    local n   = self.board and self.board.n or 5
    self.n    = n

    local Screen = require("device").screen
    local min_dim = math.min(Screen:getWidth(), Screen:getHeight())
    self.size     = math.floor(min_dim * (self.size_ratio or 0.82))
    self.cell     = self.size / n
    self.dot_r    = math.max(2, math.floor(self.cell * 0.06))
    self.line_w   = math.max(2, math.floor(self.cell * 0.08))
    self.cross_len = math.max(3, math.floor(self.cell * 0.20))

    -- Font for clue numbers
    local fsize = math.max(10, math.floor(self.cell * 0.45))
    self.num_face = Font:getFace("cfont", fsize)

    self.dimen      = Geom:new{ w = self.size, h = self.size }
    self.paint_rect = Geom:new{ x=0, y=0, w=self.size, h=self.size }

    self.ges_events = {
        Tap = {
            GestureRange:new{
                ges   = "tap",
                range = function() return self.paint_rect end,
            }
        },
        HoldRelease = {
            GestureRange:new{
                ges   = "hold_release",
                range = function() return self.paint_rect end,
            }
        },
    }
end

-- Map pixel (px, py) relative to widget origin to nearest edge.
-- Returns: kind ("h" or "v"), row, col
function SlitherlinkBoardWidget:getEdgeFromPoint(px, py)
    local cell = self.cell
    local n    = self.n

    -- Fractional dot position
    local fx = px / cell  -- 0..n
    local fy = py / cell

    -- Nearest row-dot and col-dot
    local row = math.floor(fy + 0.5)  -- 0..n (dot row index, 0-based)
    local col = math.floor(fx + 0.5)  -- 0..n (dot col index, 0-based)

    -- Distance to nearest horizontal mid-point: row, col±0.5
    local h_r = row
    local h_c = math.floor(fx) + 1  -- cell col (1..n)
    local h_cy_frac = h_r           -- dot row y fraction
    local h_cx_frac = h_c - 0.5    -- mid of horizontal edge
    local dh = (fx - h_cx_frac)^2 + (fy - h_cy_frac)^2

    -- Distance to nearest vertical mid-point: row±0.5, col
    local v_r = math.floor(fy) + 1  -- cell row (1..n)
    local v_c = col
    local v_ry_frac = v_r - 0.5
    local v_cx_frac = v_c
    local dv = (fx - v_cx_frac)^2 + (fy - v_ry_frac)^2

    -- Convert to 1-based indices
    local hr = h_r + 1  -- 1..(n+1)
    local hc = h_c      -- 1..n
    local vr = v_r      -- 1..n
    local vc = v_c + 1  -- 1..(n+1)

    if hr < 1 then hr = 1 elseif hr > n+1 then hr = n+1 end
    if hc < 1 then hc = 1 elseif hc > n   then hc = n   end
    if vr < 1 then vr = 1 elseif vr > n   then vr = n   end
    if vc < 1 then vc = 1 elseif vc > n+1 then vc = n+1 end

    if dh <= dv then
        return "h", hr, hc
    else
        return "v", vr, vc
    end
end

function SlitherlinkBoardWidget:onTap(_, ges)
    if not (ges and ges.pos) then return false end
    local rect = self.paint_rect
    local px   = ges.pos.x - rect.x
    local py   = ges.pos.y - rect.y
    if px < 0 or py < 0 or px > rect.w or py > rect.h then return false end
    local kind, r, c = self:getEdgeFromPoint(px, py)
    if self.onEdgeAction then self.onEdgeAction(kind, r, c, false) end
    return true
end

function SlitherlinkBoardWidget:onHoldRelease(_, ges)
    if not (ges and ges.pos) then return false end
    local rect = self.paint_rect
    local px   = ges.pos.x - rect.x
    local py   = ges.pos.y - rect.y
    if px < 0 or py < 0 or px > rect.w or py > rect.h then return false end
    local kind, r, c = self:getEdgeFromPoint(px, py)
    if self.onEdgeAction then self.onEdgeAction(kind, r, c, true) end
    return true
end

function SlitherlinkBoardWidget:refresh()
    local rect = self.paint_rect
    UIManager:setDirty(self, function()
        return "ui", Geom:new{ x=rect.x, y=rect.y, w=rect.w, h=rect.h }
    end)
end

function SlitherlinkBoardWidget:paintTo(bb, x, y)
    if not self.board then return end
    self.paint_rect = Geom:new{ x=x, y=y, w=self.dimen.w, h=self.dimen.h }

    local n    = self.n
    local cell = self.cell
    local lw   = self.line_w
    local dr   = self.dot_r
    local show = self.board:isShowingSolution()

    bb:paintRect(x, y, self.dimen.w, self.dimen.h, C_BG)

    -- Helper: dot position in pixels
    local function dotX(c) return x + math.floor((c-1) * cell) end
    local function dotY(r) return y + math.floor((r-1) * cell) end

    -- Draw horizontal edges
    for r = 1, n+1 do
        for c = 1, n do
            local ex = dotX(c) + math.floor(cell * 0.1)
            local ey = dotY(r)
            local ew = math.floor(cell * 0.8)

            local state = show and (self.board.h_sol[r][c] and SlitherlinkBoard.EDGE_LINE or SlitherlinkBoard.EDGE_UNKNOWN)
                or self.board.h_user[r][c]
            local is_wrong = not show and self.board.wrong_h[r][c]

            if state == SlitherlinkBoard.EDGE_LINE then
                local color = is_wrong and C_WRONG or C_LINE
                bb:paintRect(ex, ey - math.floor(lw/2), ew, lw, color)
            elseif state == SlitherlinkBoard.EDGE_CROSS then
                local color = is_wrong and C_WRONG or C_CROSS
                local cx2 = dotX(c) + math.floor(cell / 2)
                local cy2 = dotY(r)
                local cl  = self.cross_len
                bb:paintRect(cx2 - cl, cy2 - 1, cl*2, 1, color)
                bb:paintRect(cx2 - 1, cy2 - cl, 1, cl*2, color)
            end
        end
    end

    -- Draw vertical edges
    for r = 1, n do
        for c = 1, n+1 do
            local ex = dotX(c)
            local ey = dotY(r) + math.floor(cell * 0.1)
            local eh = math.floor(cell * 0.8)

            local state = show and (self.board.v_sol[r][c] and SlitherlinkBoard.EDGE_LINE or SlitherlinkBoard.EDGE_UNKNOWN)
                or self.board.v_user[r][c]
            local is_wrong = not show and self.board.wrong_v[r][c]

            if state == SlitherlinkBoard.EDGE_LINE then
                local color = is_wrong and C_WRONG or C_LINE
                bb:paintRect(ex - math.floor(lw/2), ey, lw, eh, color)
            elseif state == SlitherlinkBoard.EDGE_CROSS then
                local color = is_wrong and C_WRONG or C_CROSS
                local cx2 = dotX(c)
                local cy2 = dotY(r) + math.floor(cell / 2)
                local cl  = self.cross_len
                bb:paintRect(cx2 - cl, cy2 - 1, cl*2, 1, color)
                bb:paintRect(cx2 - 1, cy2 - cl, 1, cl*2, color)
            end
        end
    end

    -- Draw clue numbers in cell centers
    for r = 1, n do
        for c = 1, n do
            local clue = self.board.clues[r][c]
            if clue >= 0 then
                local cx2 = x + math.floor((c - 0.5) * cell)
                local cy2 = y + math.floor((r - 0.5) * cell)
                local text  = tostring(clue)
                local color = show and C_NUM_SOL or C_NUM
                local m     = RenderText:sizeUtf8Text(0, cell, self.num_face, text, true, false)
                local tx    = cx2 - math.floor(m.x / 2)
                local ty    = cy2 + math.floor((m.y_top - m.y_bottom) / 2) - m.y_top
                RenderText:renderUtf8Text(bb, tx, ty, self.num_face, text, true, false, color)
            end
        end
    end

    -- Draw dots at intersections (on top of everything)
    for r = 1, n+1 do
        for c = 1, n+1 do
            bb:paintCircle(dotX(c), dotY(r), dr, C_DOT)
        end
    end
end

return SlitherlinkBoardWidget
