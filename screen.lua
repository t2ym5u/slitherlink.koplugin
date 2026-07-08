local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end
local function lrequire_common(name)
    local key = _dir .. "common/" .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. "common/" .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local ButtonTable     = require("ui/widget/buttontable")
local Device          = require("device")
local FrameContainer  = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local Size            = require("ui/size")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local _               = require("i18n")
local T               = require("ffi/util").template

local ScreenBase            = lrequire_common("screen_base")
local MenuHelper            = lrequire_common("menu_helper")
local SlitherlinkBoard      = lrequire("board")
local SlitherlinkBoardWidget = lrequire("board_widget")

local DeviceScreen = Device.screen

local GRID_SIZES = { 5, 10, 15, 20 }

local GAME_RULES_EN = _([[
Slitherlink — Rules

Draw a single closed loop along the grid lines.

Rules:
• Each number inside a cell (0, 1, 2, or 3) shows exactly how many of its four sides are part of the loop.
• Cells without a number have no constraint.
• The loop must be a single continuous closed curve — it cannot branch or cross itself, and there can be no loose ends.

Tap a grid edge to cycle: Unknown → Line → Cross → Unknown. Hold to mark as Cross (confirmed unused).
]])

local GAME_RULES_FR = [[
Slitherlink — Règles

Tracez une boucle fermée unique le long des lignes de la grille.

Règles :
• Chaque chiffre à l'intérieur d'une case (0, 1, 2 ou 3) indique exactement combien de ses quatre côtés font partie de la boucle.
• Les cases sans chiffre n'ont aucune contrainte.
• La boucle doit être une courbe fermée continue unique — elle ne peut pas se ramifier ni se croiser, et il ne peut pas y avoir d'extrémités libres.

Appuyez sur un bord de grille pour cycler : Inconnu → Ligne → Croix → Inconnu. Restez appuyé pour marquer comme Croix (non utilisé confirmé).
]]

local SlitherlinkScreen = ScreenBase:extend{}

function SlitherlinkScreen:init()
    local state = self.plugin:loadState()
    local n     = self.plugin:getSetting("grid_n", 5)
    self.board  = SlitherlinkBoard:new{ n = n }
    if not self.board:load(state) then
        self.board:generate(self.plugin:getSetting("difficulty", "easy"))
    end
    self.last_check_result = nil
    ScreenBase.init(self)
end

function SlitherlinkScreen:serializeState()
    return self.board:serialize()
end

function SlitherlinkScreen:buildLayout()
    local sw           = DeviceScreen:getWidth()
    local is_landscape = self:isLandscape()

    self.board_widget = SlitherlinkBoardWidget:new{
        board        = self.board,
        onEdgeAction = function(kind, r, c, is_hold)
            self:onEdgeAction(kind, r, c, is_hold)
        end,
    }

    local board_frame = FrameContainer:new{
        padding = Size.padding.large,
        margin  = Size.margin.default,
        self.board_widget,
    }

    local board_frame_size  = self.board_widget.size + (Size.padding.large + Size.margin.default) * 2
    local right_panel_width = sw - board_frame_size - Size.span.horizontal_default
    local button_width = is_landscape
        and math.max(right_panel_width - Size.span.horizontal_default, 100)
        or  math.floor(sw * 0.9)

    local top_buttons = ButtonTable:new{
        shrink_unneeded_width = true,
        width   = button_width,
        buttons = {
            {
                { text = _("New game"), callback = function() self:onNewGame() end },
                { id = "grid_button",  text = self:getGridButtonText(),
                  callback = function() self:openGridMenu() end },
                { id = "diff_button",  text = self:getDiffButtonText(),
                  callback = function() self:openDifficultyMenu() end },
                { id = "reveal_button", text = self:getRevealButtonText(),
                  callback = function() self:toggleSolution() end },
                self:makeRulesButtonConfig(GAME_RULES_EN, GAME_RULES_FR),
                self:makeCloseButtonConfig(),
            },
        },
    }
    self.grid_button   = top_buttons:getButtonById("grid_button")
    self.diff_button   = top_buttons:getButtonById("diff_button")
    self.reveal_button = top_buttons:getButtonById("reveal_button")

    local bottom_buttons = ButtonTable:new{
        shrink_unneeded_width = true,
        width   = button_width,
        buttons = {
            {
                { text = _("Check"), callback = function() self:onCheck() end },
                { id = "undo_button", text = _("Undo"),
                  callback = function() self:onUndo() end },
            },
        },
    }
    self.undo_button = bottom_buttons:getButtonById("undo_button")
    self:_updateUndoButton()

    if is_landscape then
        local right_panel = VerticalGroup:new{
            align = "center",
            top_buttons,
            VerticalSpan:new{ width = Size.span.vertical_large },
            self.status_text,
            VerticalSpan:new{ width = Size.span.vertical_large },
            bottom_buttons,
        }
        self.layout = HorizontalGroup:new{
            align = "center",
            board_frame,
            HorizontalSpan:new{ width = Size.span.horizontal_default },
            right_panel,
        }
    else
        local content = VerticalGroup:new{
            align = "center",
            board_frame,
            VerticalSpan:new{ width = Size.span.vertical_large },
            self.status_text,
        }
        self:buildPortraitLayout(top_buttons, content, bottom_buttons)
    end
    self[1] = self.layout
    self:updateStatus()
end

function SlitherlinkScreen:onEdgeAction(kind, r, c, is_hold)
    if self.board:isShowingSolution() then return end
    if is_hold then
        if kind == "h" then
            self.board:setHEdge(r, c, SlitherlinkBoard.EDGE_CROSS)
        else
            self.board:setVEdge(r, c, SlitherlinkBoard.EDGE_CROSS)
        end
    else
        if kind == "h" then
            self.board:cycleHEdge(r, c)
        else
            self.board:cycleVEdge(r, c)
        end
    end
    self.last_check_result = nil
    self.plugin:saveState(self.board:serialize())
    self:_updateUndoButton()
    self.board_widget:refresh()
    if self.board:isSolved() then
        self:updateStatus(_("Congratulations! Loop complete!"))
    else
        self:updateStatus()
    end
end

function SlitherlinkScreen:onNewGame()
    local diff = self.plugin:getSetting("difficulty", "easy")
    local n    = self.plugin:getSetting("grid_n", 5)
    self.board = SlitherlinkBoard:new{ n = n }
    self.board:generate(diff)
    self.last_check_result = nil
    self.plugin:saveState(self.board:serialize())
    self:buildLayout()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

function SlitherlinkScreen:onUndo()
    local ok, msg = self.board:undo()
    if ok then
        self.last_check_result = nil
        self.plugin:saveState(self.board:serialize())
        self:_updateUndoButton()
        self.board_widget:refresh()
        self:updateStatus()
    else
        self:updateStatus(msg)
    end
end

function SlitherlinkScreen:onCheck()
    self.board:checkProgress()
    local ok, violations = self.board:validateClues()
    self.last_check_result = ok
    self.board_widget:refresh()
    if self.board:isSolved() then
        self:updateStatus(_("Congratulations! Loop complete!"))
    elseif ok then
        self:updateStatus(_("No clue violations so far."))
    else
        self:updateStatus(T(_("Check: %1 clue(s) exceeded."), violations))
    end
end

function SlitherlinkScreen:toggleSolution()
    self.board:toggleSolution()
    self.board_widget:refresh()
    if self.reveal_button then
        self.reveal_button:setText(self:getRevealButtonText(), self.reveal_button.width)
    end
    self:updateStatus()
end

function SlitherlinkScreen:openGridMenu()
    local sizes = {}
    for _, sz in ipairs(GRID_SIZES) do
        sizes[#sizes+1] = { id = sz, text = sz .. "\xC3\x97" .. sz }
    end
    MenuHelper.openSizeMenu{
        title     = _("Select grid size"),
        sizes     = sizes,
        current   = self.plugin:getSetting("grid_n", 5),
        parent    = self,
        on_select = function(sz)
            if sz ~= self.board.n then
                self.plugin:saveSetting("grid_n", sz)
                self:onNewGame()
            end
        end,
    }
end

function SlitherlinkScreen:openDifficultyMenu()
    MenuHelper.openDifficultyMenu{
        current   = self.plugin:getSetting("difficulty", "easy"),
        parent    = self,
        on_select = function(id)
            self.plugin:saveSetting("difficulty", id)
            if self.diff_button then
                self.diff_button:setText(self:getDiffButtonText(), self.diff_button.width)
            end
            self:onNewGame()
        end,
    }
end

function SlitherlinkScreen:updateStatus(msg)
    local status
    if msg then
        status = msg
    elseif self.board:isShowingSolution() then
        status = _("Solution is shown; editing is disabled.")
    elseif self.board:isSolved() then
        status = _("Congratulations! Loop complete!")
    else
        local remaining = self.board:getRemainingEdges()
        local diff      = self.plugin:getSetting("difficulty", "easy")
        local label     = MenuHelper.DIFFICULTY_LABELS[diff] or diff
        status = T(_("%1\xC3\x97%2 \xC2\xB7 %3 \xC2\xB7 Edges left: %4"),
            self.board.n, self.board.n, label, remaining)
    end
    ScreenBase.updateStatus(self, status)
end

function SlitherlinkScreen:getGridButtonText()
    return T(_("Grid: %1"), self.board.n .. "\xC3\x97" .. self.board.n)
end

function SlitherlinkScreen:getDiffButtonText()
    local diff  = self.plugin:getSetting("difficulty", "easy")
    local label = MenuHelper.DIFFICULTY_LABELS[diff] or diff
    return T(_("Diff: %1"), label)
end

function SlitherlinkScreen:getRevealButtonText()
    return self.board:isShowingSolution() and _("Hide") or _("Show")
end

function SlitherlinkScreen:_updateUndoButton()
    if not self.undo_button then return end
    self.undo_button:enableDisable(self.board:canUndo())
end

return SlitherlinkScreen
