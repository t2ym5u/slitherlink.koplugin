local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire_common(name)
    local key = _dir .. "common/" .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. "common/" .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local UndoStack  = lrequire_common("undo_stack")
local grid_utils = lrequire_common("grid_utils")

local emptyGrid  = grid_utils.emptyGrid
local shuffle    = grid_utils.shuffle

-- Edge states
local EDGE_UNKNOWN = 0
local EDGE_LINE    = 1
local EDGE_CROSS   = 2

local DEFAULT_N          = 5
local DEFAULT_DIFFICULTY = "easy"

-- Fraction of clue cells to keep per difficulty
local CLUE_KEEP = { easy = 0.85, medium = 0.70, hard = 0.55 }

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- Check that all dots have degree 0 or 2, and the loop is a single cycle.
local function isSingleLoop(h, v, n)
    local total = 0
    for r = 1, n+1 do for c = 1, n do   if h[r][c] then total = total + 1 end end end
    for r = 1, n do   for c = 1, n+1 do if v[r][c] then total = total + 1 end end end
    if total == 0 then return false end

    for r = 1, n+1 do
        for c = 1, n+1 do
            local deg = 0
            if c <= n   and h[r][c]   then deg = deg + 1 end
            if c > 1    and h[r][c-1] then deg = deg + 1 end
            if r <= n   and v[r][c]   then deg = deg + 1 end
            if r > 1    and v[r-1][c] then deg = deg + 1 end
            if deg ~= 0 and deg ~= 2  then return false end
        end
    end

    -- Traverse from first line edge
    local start_r, start_c
    for r = 1, n+1 do
        for c = 1, n do
            if h[r][c] then start_r, start_c = r, c; goto found end
        end
    end
    ::found::
    if not start_r then return false end

    local cur_r, cur_c = start_r, start_c
    local prv_r, prv_c = start_r, start_c + 1

    local steps = 0
    repeat
        local nx, ny
        if cur_c <= n and h[cur_r][cur_c] then
            local nr, nc = cur_r, cur_c+1
            if nr ~= prv_r or nc ~= prv_c then nx, ny = nr, nc end
        end
        if not nx and cur_c > 1 and h[cur_r][cur_c-1] then
            local nr, nc = cur_r, cur_c-1
            if nr ~= prv_r or nc ~= prv_c then nx, ny = nr, nc end
        end
        if not nx and cur_r <= n and v[cur_r][cur_c] then
            local nr, nc = cur_r+1, cur_c
            if nr ~= prv_r or nc ~= prv_c then nx, ny = nr, nc end
        end
        if not nx and cur_r > 1 and v[cur_r-1][cur_c] then
            local nr, nc = cur_r-1, cur_c
            if nr ~= prv_r or nc ~= prv_c then nx, ny = nr, nc end
        end
        if not nx then return false end
        prv_r, prv_c = cur_r, cur_c
        cur_r, cur_c = nx, ny
        steps = steps + 1
    until (cur_r == start_r and cur_c == start_c)

    return steps == total
end

-- ---------------------------------------------------------------------------
-- Generator
-- ---------------------------------------------------------------------------

local function tryGenerate(n)
    -- Random inside/outside coloring via flood-fill from a random seed
    local inside = emptyGrid(n, n, false)
    local seed_r = math.random(math.max(1, math.floor(n/4)), math.min(n, math.ceil(3*n/4)))
    local seed_c = math.random(math.max(1, math.floor(n/4)), math.min(n, math.ceil(3*n/4)))
    inside[seed_r][seed_c] = true

    local target   = math.random(math.floor(n*n*0.20), math.floor(n*n*0.60))
    local frontier = {{seed_r, seed_c}}
    local count    = 1

    local DIRS = {{-1,0},{1,0},{0,-1},{0,1}}
    while count < target and #frontier > 0 do
        local idx  = math.random(#frontier)
        local cell = frontier[idx]
        local r, c = cell[1], cell[2]

        local expanded = false
        local ds = {{-1,0},{1,0},{0,-1},{0,1}}
        shuffle(ds)
        for _, d in ipairs(ds) do
            local nr, nc = r+d[1], c+d[2]
            if nr >= 1 and nr <= n and nc >= 1 and nc <= n and not inside[nr][nc] then
                inside[nr][nc] = true
                count = count + 1
                frontier[#frontier+1] = {nr, nc}
                expanded = true
                break
            end
        end
        if not expanded then table.remove(frontier, idx) end
    end

    -- Build solution edges from inside/outside boundary
    local h_sol = {}
    for r = 1, n+1 do
        h_sol[r] = {}
        for c = 1, n do
            local above = r > 1   and inside[r-1][c] or false
            local below = r <= n  and inside[r][c]   or false
            h_sol[r][c] = (above ~= below)
        end
    end
    local v_sol = {}
    for r = 1, n do
        v_sol[r] = {}
        for c = 1, n+1 do
            local left  = c > 1  and inside[r][c-1] or false
            local right = c <= n and inside[r][c]   or false
            v_sol[r][c] = (left ~= right)
        end
    end

    if not isSingleLoop(h_sol, v_sol, n) then return nil end

    -- Compute clue values
    local clues = emptyGrid(n, n, -1)
    for r = 1, n do
        for c = 1, n do
            local cnt = 0
            if h_sol[r][c]   then cnt = cnt + 1 end
            if h_sol[r+1][c] then cnt = cnt + 1 end
            if v_sol[r][c]   then cnt = cnt + 1 end
            if v_sol[r][c+1] then cnt = cnt + 1 end
            clues[r][c] = cnt
        end
    end

    return h_sol, v_sol, clues
end

-- ---------------------------------------------------------------------------
-- SlitherlinkBoard
-- ---------------------------------------------------------------------------

local SlitherlinkBoard = {}
SlitherlinkBoard.__index = SlitherlinkBoard

local function makeHGrid(n, val)
    local g = {}
    for r = 1, n+1 do
        g[r] = {}
        for c = 1, n do g[r][c] = val end
    end
    return g
end

local function makeVGrid(n, val)
    local g = {}
    for r = 1, n do
        g[r] = {}
        for c = 1, n+1 do g[r][c] = val end
    end
    return g
end

function SlitherlinkBoard:new(opts)
    opts = opts or {}
    local n = opts.n or DEFAULT_N
    return setmetatable({
        n          = n,
        difficulty = opts.difficulty or DEFAULT_DIFFICULTY,
        clues      = emptyGrid(n, n, -1),
        h_sol      = makeHGrid(n, false),
        v_sol      = makeVGrid(n, false),
        h_user     = makeHGrid(n, EDGE_UNKNOWN),
        v_user     = makeVGrid(n, EDGE_UNKNOWN),
        wrong_h    = makeHGrid(n, false),
        wrong_v    = makeVGrid(n, false),
        reveal     = false,
        undo       = UndoStack:new{ max_size = 500 },
    }, self)
end

function SlitherlinkBoard:generate(difficulty)
    self.difficulty = difficulty or self.difficulty
    self.reveal     = false
    self.undo:clear()

    local n = self.n
    local h_sol, v_sol, clues

    for _ = 1, 100 do
        h_sol, v_sol, clues = tryGenerate(n)
        if h_sol then break end
    end

    if not h_sol then
        -- Fallback: simple border loop
        h_sol = makeHGrid(n, false)
        v_sol = makeVGrid(n, false)
        for c = 1, n do h_sol[1][c] = true; h_sol[n+1][c] = true end
        for r = 1, n do v_sol[r][1] = true; v_sol[r][n+1] = true end
        clues = emptyGrid(n, n, -1)
        for r = 1, n do
            for c = 1, n do
                local cnt = 0
                if h_sol[r][c]   then cnt = cnt + 1 end
                if h_sol[r+1][c] then cnt = cnt + 1 end
                if v_sol[r][c]   then cnt = cnt + 1 end
                if v_sol[r][c+1] then cnt = cnt + 1 end
                clues[r][c] = cnt
            end
        end
    end

    -- Remove some clues based on difficulty
    local keep = CLUE_KEEP[self.difficulty] or CLUE_KEEP.easy
    for r = 1, n do
        for c = 1, n do
            if math.random() > keep then clues[r][c] = -1 end
        end
    end

    self.h_sol  = h_sol
    self.v_sol  = v_sol
    self.clues  = clues
    self.h_user = makeHGrid(n, EDGE_UNKNOWN)
    self.v_user = makeVGrid(n, EDGE_UNKNOWN)
    self.wrong_h = makeHGrid(n, false)
    self.wrong_v = makeVGrid(n, false)
end

-- Set a horizontal edge (r in 1..n+1, c in 1..n)
function SlitherlinkBoard:setHEdge(r, c, state)
    if r < 1 or r > self.n+1 or c < 1 or c > self.n then return false end
    local prev = self.h_user[r][c]
    self.undo:push{ kind="h", r=r, c=c, prev=prev }
    self.h_user[r][c]  = state
    self.wrong_h[r][c] = false
    return true
end

-- Set a vertical edge (r in 1..n, c in 1..n+1)
function SlitherlinkBoard:setVEdge(r, c, state)
    if r < 1 or r > self.n or c < 1 or c > self.n+1 then return false end
    local prev = self.v_user[r][c]
    self.undo:push{ kind="v", r=r, c=c, prev=prev }
    self.v_user[r][c]  = state
    self.wrong_v[r][c] = false
    return true
end

function SlitherlinkBoard:cycleHEdge(r, c)
    local cur = self.h_user[r][c]
    return self:setHEdge(r, c, (cur + 1) % 3)
end

function SlitherlinkBoard:cycleVEdge(r, c)
    local cur = self.v_user[r][c]
    return self:setVEdge(r, c, (cur + 1) % 3)
end

function SlitherlinkBoard:canUndo()
    return self.undo:canUndo()
end

function SlitherlinkBoard:undo()
    local entry = self.undo:pop()
    if not entry then return false, UndoStack.NOTHING_TO_UNDO end
    if entry.kind == "h" then
        self.h_user[entry.r][entry.c]  = entry.prev
        self.wrong_h[entry.r][entry.c] = false
    else
        self.v_user[entry.r][entry.c]  = entry.prev
        self.wrong_v[entry.r][entry.c] = false
    end
    return true
end

function SlitherlinkBoard:checkProgress()
    local n = self.n
    for r = 1, n+1 do
        for c = 1, n do
            local u = self.h_user[r][c]
            local s = self.h_sol[r][c]
            self.wrong_h[r][c] = (u == EDGE_LINE and not s) or (u == EDGE_CROSS and s)
        end
    end
    for r = 1, n do
        for c = 1, n+1 do
            local u = self.v_user[r][c]
            local s = self.v_sol[r][c]
            self.wrong_v[r][c] = (u == EDGE_LINE and not s) or (u == EDGE_CROSS and s)
        end
    end
end

function SlitherlinkBoard:isSolved()
    local n = self.n
    for r = 1, n+1 do
        for c = 1, n do
            local u = self.h_user[r][c]
            local s = self.h_sol[r][c]
            if s  and u ~= EDGE_LINE  then return false end
            if not s and u == EDGE_LINE then return false end
        end
    end
    for r = 1, n do
        for c = 1, n+1 do
            local u = self.v_user[r][c]
            local s = self.v_sol[r][c]
            if s  and u ~= EDGE_LINE  then return false end
            if not s and u == EDGE_LINE then return false end
        end
    end
    return true
end

function SlitherlinkBoard:validateClues()
    local n          = self.n
    local violations = 0
    for r = 1, n do
        for c = 1, n do
            local clue = self.clues[r][c]
            if clue >= 0 then
                local cnt = 0
                if self.h_user[r][c]   == EDGE_LINE then cnt = cnt + 1 end
                if self.h_user[r+1][c] == EDGE_LINE then cnt = cnt + 1 end
                if self.v_user[r][c]   == EDGE_LINE then cnt = cnt + 1 end
                if self.v_user[r][c+1] == EDGE_LINE then cnt = cnt + 1 end
                -- Check for over-limit (already committed too many lines)
                local cnt_committed = cnt
                local cnt_max = clue
                if cnt_committed > cnt_max then violations = violations + 1 end
            end
        end
    end
    return violations == 0, violations
end

function SlitherlinkBoard:getRemainingEdges()
    local n, count = self.n, 0
    for r = 1, n+1 do
        for c = 1, n do
            if self.h_user[r][c] == EDGE_UNKNOWN then count = count + 1 end
        end
    end
    for r = 1, n do
        for c = 1, n+1 do
            if self.v_user[r][c] == EDGE_UNKNOWN then count = count + 1 end
        end
    end
    return count
end

function SlitherlinkBoard:toggleSolution()
    self.reveal = not self.reveal
end

function SlitherlinkBoard:isShowingSolution()
    return self.reveal
end

-- ---------------------------------------------------------------------------
-- Serialize / Load
-- ---------------------------------------------------------------------------

local function copyHGrid(src, n)
    local g = {}
    for r = 1, n+1 do
        g[r] = {}
        for c = 1, n do g[r][c] = src[r] and src[r][c] or 0 end
    end
    return g
end

local function copyVGrid(src, n)
    local g = {}
    for r = 1, n do
        g[r] = {}
        for c = 1, n+1 do g[r][c] = src[r] and src[r][c] or 0 end
    end
    return g
end

local function copyHBool(src, n)
    local g = {}
    for r = 1, n+1 do
        g[r] = {}
        for c = 1, n do g[r][c] = src[r] and src[r][c] and true or false end
    end
    return g
end

local function copyVBool(src, n)
    local g = {}
    for r = 1, n do
        g[r] = {}
        for c = 1, n+1 do g[r][c] = src[r] and src[r][c] and true or false end
    end
    return g
end

function SlitherlinkBoard:serialize()
    local n = self.n
    local clues_out = {}
    for r = 1, n do
        clues_out[r] = {}
        for c = 1, n do clues_out[r][c] = self.clues[r][c] end
    end
    return {
        n          = n,
        difficulty = self.difficulty,
        clues      = clues_out,
        h_sol      = copyHBool(self.h_sol,  n),
        v_sol      = copyVBool(self.v_sol,  n),
        h_user     = copyHGrid(self.h_user, n),
        v_user     = copyVGrid(self.v_user, n),
        wrong_h    = copyHBool(self.wrong_h, n),
        wrong_v    = copyVBool(self.wrong_v, n),
        reveal     = self.reveal,
        undo       = self.undo:serialize(),
    }
end

function SlitherlinkBoard:load(data)
    if type(data) ~= "table" or not data.clues or not data.h_sol then return false end
    local n = data.n or DEFAULT_N
    self.n          = n
    self.difficulty = data.difficulty or DEFAULT_DIFFICULTY

    local clues = emptyGrid(n, n, -1)
    for r = 1, n do
        for c = 1, n do
            if data.clues[r] and data.clues[r][c] ~= nil then
                clues[r][c] = data.clues[r][c]
            end
        end
    end
    self.clues = clues

    self.h_sol   = makeHGrid(n, false)
    self.v_sol   = makeVGrid(n, false)
    self.h_user  = makeHGrid(n, EDGE_UNKNOWN)
    self.v_user  = makeVGrid(n, EDGE_UNKNOWN)
    self.wrong_h = makeHGrid(n, false)
    self.wrong_v = makeVGrid(n, false)

    if data.h_sol then
        for r = 1, n+1 do
            for c = 1, n do
                local v = data.h_sol[r] and data.h_sol[r][c]
                self.h_sol[r][c] = (v == true or v == 1)
            end
        end
    end
    if data.v_sol then
        for r = 1, n do
            for c = 1, n+1 do
                local v = data.v_sol[r] and data.v_sol[r][c]
                self.v_sol[r][c] = (v == true or v == 1)
            end
        end
    end
    if data.h_user then
        for r = 1, n+1 do
            for c = 1, n do
                self.h_user[r][c] = data.h_user[r] and tonumber(data.h_user[r][c]) or EDGE_UNKNOWN
            end
        end
    end
    if data.v_user then
        for r = 1, n do
            for c = 1, n+1 do
                self.v_user[r][c] = data.v_user[r] and tonumber(data.v_user[r][c]) or EDGE_UNKNOWN
            end
        end
    end
    if data.wrong_h then
        for r = 1, n+1 do
            for c = 1, n do
                local v = data.wrong_h[r] and data.wrong_h[r][c]
                self.wrong_h[r][c] = (v == true or v == 1)
            end
        end
    end
    if data.wrong_v then
        for r = 1, n do
            for c = 1, n+1 do
                local v = data.wrong_v[r] and data.wrong_v[r][c]
                self.wrong_v[r][c] = (v == true or v == 1)
            end
        end
    end

    self.reveal = data.reveal or false
    self.undo   = UndoStack:new{ max_size = 500 }
    if data.undo then self.undo:load(data.undo) end
    return true
end

SlitherlinkBoard.EDGE_UNKNOWN = EDGE_UNKNOWN
SlitherlinkBoard.EDGE_LINE    = EDGE_LINE
SlitherlinkBoard.EDGE_CROSS   = EDGE_CROSS

return SlitherlinkBoard
