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
-- Uniqueness counter. Win-check is a literal comparison to the stored
-- solution (not rule-based). Uniqueness means: given the revealed clue
-- numbers, is there only one edge assignment forming a single simple loop
-- (every dot has degree 0 or 2, no separate sub-loops) consistent with
-- them? Backtracking over edges (line/not-line) with two propagation
-- rules: clue forcing (a cell's decided-line-count hitting its clue value
-- forces the rest) and vertex degree forcing (a dot's final degree must
-- be 0 or 2, so its last undecided incident edge is forced once that's
-- the only way to avoid ending at degree 1). Full validation (incl. no
-- separate sub-loops) is only checked once every edge is decided -- an
-- earlier attempt at incremental "no premature sub-loop" pruning via
-- union-find was unsound (compared against the count of ALL decided
-- edges, line or not, which is essentially never reached until long
-- after the real loop closes, since unrelated not-line edges elsewhere
-- are usually still undecided -- it rejected the true solution's own
-- closing edge nearly always, caught via the standard sanity check).
-- Dropped in favor of this simpler, definitely-sound version; the clue
-- and vertex propagation alone turned out to be strong enough to stay
-- fast (sub-100ms even at n=20) without it.
-- ---------------------------------------------------------------------------

local function countSolutions(clues, n, limit, node_budget)
    local h = {}
    local v = {}
    for r = 1, n+1 do h[r] = {} end
    for r = 1, n do v[r] = {} end

    local edge_list = {}
    for r = 1, n+1 do for c = 1, n do edge_list[#edge_list+1] = { kind="h", r=r, c=c } end end
    for r = 1, n do for c = 1, n+1 do edge_list[#edge_list+1] = { kind="v", r=r, c=c } end end
    local num_edges = #edge_list

    local function getE(e)
        if e.kind == "h" then return h[e.r][e.c] else return v[e.r][e.c] end
    end
    local function setE(e, val)
        if e.kind == "h" then h[e.r][e.c] = val else v[e.r][e.c] = val end
    end

    local function cellEdges(r, c)
        return {
            { kind="h", r=r,   c=c },
            { kind="h", r=r+1, c=c },
            { kind="v", r=r,   c=c },
            { kind="v", r=r,   c=c+1 },
        }
    end

    local function vertexEdges(r, c)
        local es = {}
        if c <= n   then es[#es+1] = { kind="h", r=r,   c=c   } end
        if c > 1    then es[#es+1] = { kind="h", r=r,   c=c-1 } end
        if r <= n   then es[#es+1] = { kind="v", r=r,   c=c   } end
        if r > 1    then es[#es+1] = { kind="v", r=r-1, c=c   } end
        return es
    end

    local decided_count = 0
    local solutions, nodes, exhausted = 0, 0, false

    local function isSingleLoopFinal()
        local total = 0
        for r = 1, n+1 do for c = 1, n do if h[r][c] then total = total + 1 end end end
        for r = 1, n do for c = 1, n+1 do if v[r][c] then total = total + 1 end end end
        if total == 0 then return false end
        for r = 1, n+1 do
            for c = 1, n+1 do
                local deg = 0
                if c <= n and h[r][c] then deg = deg + 1 end
                if c > 1 and h[r][c-1] then deg = deg + 1 end
                if r <= n and v[r][c] then deg = deg + 1 end
                if r > 1 and v[r-1][c] then deg = deg + 1 end
                if deg ~= 0 and deg ~= 2 then return false end
            end
        end
        local start_r, start_c
        for r = 1, n+1 do for c = 1, n do if h[r][c] then start_r, start_c = r, c; goto found end end end
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

    local function setDecided(e, val, changes)
        if getE(e) ~= nil then return getE(e) == val end
        setE(e, val)
        decided_count = decided_count + 1
        changes[#changes+1] = e
        return true
    end

    local function undo(changes)
        for _, e in ipairs(changes) do
            setE(e, nil)
            decided_count = decided_count - 1
        end
    end

    local function propagate(changes)
        local progressed = true
        while progressed do
            progressed = false
            for r = 1, n do
                for c = 1, n do
                    local clue = clues[r][c]
                    if clue and clue >= 0 then
                        local es = cellEdges(r, c)
                        local have, undecided = 0, {}
                        for _, e in ipairs(es) do
                            local val = getE(e)
                            if val == true then have = have + 1
                            elseif val == nil then undecided[#undecided+1] = e end
                        end
                        if have > clue or have + #undecided < clue then return false end
                        if #undecided > 0 then
                            if have == clue then
                                for _, e in ipairs(undecided) do
                                    if not setDecided(e, false, changes) then return false end
                                end
                                progressed = true
                            elseif have + #undecided == clue then
                                for _, e in ipairs(undecided) do
                                    if not setDecided(e, true, changes) then return false end
                                end
                                progressed = true
                            end
                        end
                    end
                end
            end
            for r = 1, n+1 do
                for c = 1, n+1 do
                    local es = vertexEdges(r, c)
                    local have, undecided = 0, {}
                    for _, e in ipairs(es) do
                        local val = getE(e)
                        if val == true then have = have + 1
                        elseif val == nil then undecided[#undecided+1] = e end
                    end
                    if have > 2 then return false end
                    if #undecided == 0 and have ~= 0 and have ~= 2 then return false end
                    if #undecided == 1 then
                        if have == 0 then
                            if not setDecided(undecided[1], false, changes) then return false end
                            progressed = true
                        elseif have == 1 then
                            if not setDecided(undecided[1], true, changes) then return false end
                            progressed = true
                        end
                    end
                end
            end
        end
        return true
    end

    local function search()
        if solutions >= limit or exhausted then return end
        nodes = nodes + 1
        if nodes > node_budget then exhausted = true; return end

        local changes = {}
        if not propagate(changes) then
            undo(changes)
            return
        end

        if decided_count == num_edges then
            if isSingleLoopFinal() then solutions = solutions + 1 end
            undo(changes)
            return
        end

        local pick
        for _, e in ipairs(edge_list) do
            if getE(e) == nil then pick = e; break end
        end
        if not pick then
            undo(changes)
            return
        end

        for _, val in ipairs({ false, true }) do
            local branch_changes = {}
            if setDecided(pick, val, branch_changes) then
                search()
            end
            undo(branch_changes)
            if solutions >= limit or exhausted then break end
        end
        undo(changes)
    end

    search()
    return solutions, exhausted
end

local function uniquenessNodeBudget(n)
    if n <= 10 then return 100000 end
    if n <= 15 then return 60000 end
    return 15000
end

local REVEAL_LEVELS = { 1.0, 1.15, 1.3, 100.0 } -- multipliers on CLUE_KEEP ratio (last guarantees full reveal)

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

-- Reveals clues from the full (every-cell) clue grid at the given keep
-- ratio. Repicking which cells reveal their clue for the SAME loop shape
-- is much cheaper than regenerating the loop, and a higher ratio can only
-- add constraints -- same lever as shikaku/lightup/tapa.
local function pickClues(full_clues, n, keep)
    local clues = emptyGrid(n, n, -1)
    for r = 1, n do
        for c = 1, n do
            if math.random() <= keep then
                clues[r][c] = full_clues[r][c]
            end
        end
    end
    return clues
end

-- Win-check is a literal comparison to the stored solution -- there's no
-- "given" mask beyond which clues get revealed, so like hitori/lightup/
-- tapa this generates+verifies whole candidates instead of digging.
-- Measured pre-fix: real, graduated ambiguity (worse at hard/larger n --
-- n=10/hard only 1/10 unique). Escalates the clue-keep ratio in bounded
-- steps (nominal, then higher, then a guaranteed full reveal) for a given
-- loop shape before drawing a fresh one, same shape as the hitori/lightup/
-- tapa fix -- a plain "retry the same nominal ratio" loop was already
-- shown not to help in this audit when the nominal ratio is itself often
-- ambiguous.
function SlitherlinkBoard:generate(difficulty)
    self.difficulty = difficulty or self.difficulty
    self.reveal     = false
    self.undo:clear()

    local n = self.n
    local base_keep = CLUE_KEEP[self.difficulty] or CLUE_KEEP.easy
    local node_budget = uniquenessNodeBudget(n)

    local h_sol, v_sol, clues
    local best_h_sol, best_v_sol, best_clues

    for _ = 1, 40 do
        if h_sol then break end
        local cand_h, cand_v, full_clues = tryGenerate(n)
        if cand_h then
            for _, mult in ipairs(REVEAL_LEVELS) do
                if h_sol then break end
                local keep = math.min(1.0, base_keep * mult)
                local sub_attempts = keep >= 1.0 and 1 or 2
                for _ = 1, sub_attempts do
                    local candidate_clues = pickClues(full_clues, n, keep)

                    if not best_h_sol then
                        best_h_sol, best_v_sol, best_clues = cand_h, cand_v, candidate_clues
                    end

                    local solutions, exhausted = countSolutions(candidate_clues, n, 2, node_budget)
                    if solutions == 1 and not exhausted then
                        h_sol, v_sol, clues = cand_h, cand_v, candidate_clues
                        break
                    end
                end
            end
        end
    end
    if not h_sol then
        h_sol, v_sol, clues = best_h_sol, best_v_sol, best_clues
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
