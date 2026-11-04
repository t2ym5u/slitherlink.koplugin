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
-- them?
--
-- Backtracking over edges (0 undecided, 1 line, 2 cross) with queue-driven
-- propagation; every rule only forces what all solutions extending the
-- current partial grid share, so solutions are counted exactly:
--   - clue: a cell's line count reaching its clue crosses the rest; when
--     only as many undecided edges are left as lines missing, they're all
--     lines.
--   - dot: a dot never has more than 2 lines; with 2 the rest are crossed;
--     its last undecided edge is forced so it doesn't end at degree 1.
--   - sub-loops: each line path's two ends know each other (mate[], kept
--     on the trail so backtracking restores it). Joining a path's own two
--     ends closes a loop, which is only allowed when every line so far
--     belongs to that path; after that no new line may appear. An edge
--     that would close a loop too early is crossed as soon as it's seen.
-- The search branches on an edge at a path end (one of its free edges
-- must be a line), so the loop is followed rather than guessed edge by
-- edge in raster order. node_budget counts search nodes, so a seed gives
-- the same verdict on every device.
-- 1.5.0: replaces a raster-order backtracker that only checked for
-- sub-loops once every edge was decided (up to 11 s at 20x20 on a
-- desktop, minutes on an e-reader).
-- ---------------------------------------------------------------------------

local function countSolutions(clues, n, limit, node_budget)
    local W = n + 1                     -- dots per row
    local HN = (n + 1) * n              -- horizontal edges come first
    local E = HN + n * (n + 1)
    local ea, eb, ecells = {}, {}, {}   -- edge -> its two dots, its cells
    local vedges, cedges = {}, {}       -- dot -> edges, cell -> edges
    for i = 1, W * W do vedges[i] = {} end
    for i = 1, n * n do cedges[i] = {} end
    local function addEdge(e, a, b)
        ea[e], eb[e], ecells[e] = a, b, {}
        local va, vb = vedges[a], vedges[b]
        va[#va + 1] = e; vb[#vb + 1] = e
    end
    local function addCell(e, r, c)
        if r >= 1 and r <= n and c >= 1 and c <= n then
            local cell = (r - 1) * n + c
            local ec = ecells[e]
            ec[#ec + 1] = cell
            local ce = cedges[cell]
            ce[#ce + 1] = e
        end
    end
    for r = 1, n + 1 do for c = 1, n do       -- h[r][c]: dot (r,c)-(r,c+1)
        local e = (r - 1) * n + c
        addEdge(e, (r - 1) * W + c, (r - 1) * W + c + 1)
        addCell(e, r - 1, c); addCell(e, r, c)
    end end
    for r = 1, n do for c = 1, n + 1 do       -- v[r][c]: dot (r,c)-(r+1,c)
        local e = HN + (r - 1) * (n + 1) + c
        addEdge(e, (r - 1) * W + c, r * W + c)
        addCell(e, r, c - 1); addCell(e, r, c)
    end end
    local clue = {}
    for r = 1, n do for c = 1, n do
        local k = clues[r][c]
        clue[(r - 1) * n + c] = (k and k >= 0) and k or nil
    end end
    local function edgeBetween(a, b)
        for _, e in ipairs(vedges[a]) do
            if ea[e] == b or eb[e] == b then return e end
        end
    end

    local state, vline, vund, cline, cund = {}, {}, {}, {}, {}
    for e = 1, E do state[e] = 0 end
    for i = 1, W * W do vline[i] = 0; vund[i] = #vedges[i] end
    for i = 1, n * n do cline[i] = 0; cund[i] = 4 end
    local mate, plen = {}, {}           -- valid at path ends only
    for i = 1, W * W do mate[i] = i; plen[i] = 0 end
    local lines, undecided, closed = 0, E, false

    -- Trail entries: an edge id, or a negated dot id followed by the dot's
    -- previous mate and plen (restored in reverse order).
    local trail, tn = {}, 0
    local queue, qh, qt = {}, 1, 0      -- dots (positive) / cells (negated)

    local function saveDot(d)
        trail[tn + 1] = mate[d]; trail[tn + 2] = plen[d]; trail[tn + 3] = -d
        tn = tn + 3
    end
    local function undo(mark)
        while tn > mark do
            local x = trail[tn]
            if x < 0 then
                local d = -x
                plen[d] = trail[tn - 1]; mate[d] = trail[tn - 2]
                tn = tn - 3
            else
                local e = x
                local a, b = ea[e], eb[e]
                vund[a] = vund[a] + 1; vund[b] = vund[b] + 1
                for _, cell in ipairs(ecells[e]) do cund[cell] = cund[cell] + 1 end
                if state[e] == 1 then
                    vline[a] = vline[a] - 1; vline[b] = vline[b] - 1
                    for _, cell in ipairs(ecells[e]) do cline[cell] = cline[cell] - 1 end
                    lines = lines - 1
                    if closed then closed = false end  -- only the closing edge can be undone while closed
                end
                state[e] = 0
                undecided = undecided + 1
                tn = tn - 1
            end
        end
    end
    -- "closed" is restored by undo(): the only line set while closed would be
    -- a contradiction (rejected before it's recorded), so the most recent
    -- line edge on the trail when closed is the one that closed the loop.

    -- Returns false on a contradiction.
    local function set(e, val)
        local s = state[e]
        if s ~= 0 then return s == val end
        local a, b = ea[e], eb[e]
        if val == 1 then
            if closed or vline[a] >= 2 or vline[b] >= 2 then return false end
            local ea_end = vline[a] == 0 and a or mate[a]
            local eb_end = vline[b] == 0 and b or mate[b]
            if ea_end == b then
                -- a and b are the two ends of one path: this closes a loop,
                -- which must then be the whole solution.
                if plen[a] ~= lines then return false end
                closed = true
            else
                local len = (vline[a] == 0 and 0 or plen[a]) + (vline[b] == 0 and 0 or plen[b]) + 1
                saveDot(ea_end); saveDot(eb_end)
                mate[ea_end], mate[eb_end] = eb_end, ea_end
                plen[ea_end], plen[eb_end] = len, len
                -- the new ends may now face each other across one edge
                qt = qt + 1; queue[qt] = ea_end
                qt = qt + 1; queue[qt] = eb_end
            end
            vline[a] = vline[a] + 1; vline[b] = vline[b] + 1
            for _, cell in ipairs(ecells[e]) do cline[cell] = cline[cell] + 1 end
            lines = lines + 1
        end
        state[e] = val
        vund[a] = vund[a] - 1; vund[b] = vund[b] - 1
        for _, cell in ipairs(ecells[e]) do cund[cell] = cund[cell] - 1 end
        undecided = undecided - 1
        tn = tn + 1; trail[tn] = e
        qt = qt + 1; queue[qt] = a
        qt = qt + 1; queue[qt] = b
        for _, cell in ipairs(ecells[e]) do qt = qt + 1; queue[qt] = -cell end
        return true
    end

    local function setAll(list, val)
        for _, e in ipairs(list) do
            if state[e] == 0 and not set(e, val) then return false end
        end
        return true
    end

    local function propagate()
        while true do
            while qh <= qt do
                local x = queue[qh]; qh = qh + 1
                if x > 0 then
                    local d = x
                    local l, u = vline[d], vund[d]
                    if l > 2 or (l == 1 and u == 0) then return false end
                    if u > 0 then
                        if l == 2 then
                            if not setAll(vedges[d], 2) then return false end
                        elseif u == 1 then
                            if not setAll(vedges[d], l == 1 and 1 or 2) then return false end
                        elseif l == 1 then
                            -- A path end next to its own other end: that edge
                            -- would close a loop, fine only if it'd hold every line.
                            local m = mate[d]
                            if m ~= d and plen[d] ~= lines then
                                local e = edgeBetween(d, m)
                                if e and state[e] == 0 and not set(e, 2) then return false end
                            end
                        end
                    end
                else
                    local cell = -x
                    local k = clue[cell]
                    if k then
                        local l, u = cline[cell], cund[cell]
                        if l > k or l + u < k then return false end
                        if u > 0 then
                            if l == k then
                                if not setAll(cedges[cell], 2) then return false end
                            elseif l + u == k then
                                if not setAll(cedges[cell], 1) then return false end
                            end
                        end
                    end
                end
            end
            -- Once the loop is closed, every edge left is a cross.
            if not (closed and undecided > 0) then break end
            for e = 1, E do
                if state[e] == 0 and not set(e, 2) then return false end
            end
        end
        return true
    end

    local function pickEdge()
        local best, best_u = nil, 99
        for d = 1, W * W do
            if vline[d] == 1 and vund[d] > 0 and vund[d] < best_u then
                best, best_u = d, vund[d]
                if best_u == 2 then break end
            end
        end
        if best then
            for _, e in ipairs(vedges[best]) do
                if state[e] == 0 then return e end
            end
        end
        -- No path yet: start next to the most demanding clue.
        local cbest, ck = nil, -1
        for cell = 1, n * n do
            local k = clue[cell]
            if k and cund[cell] > 0 and k - cline[cell] > ck then cbest, ck = cell, k - cline[cell] end
        end
        if cbest then
            for _, e in ipairs(cedges[cbest]) do
                if state[e] == 0 then return e end
            end
        end
        for e = 1, E do if state[e] == 0 then return e end end
    end

    local solutions, nodes, exhausted = 0, 0, false
    local function search()
        nodes = nodes + 1
        if nodes > node_budget then exhausted = true; return end
        if not propagate() then qh, qt = 1, 0; return end
        qh, qt = 1, 0
        if undecided == 0 then
            if closed then solutions = solutions + 1 end
            return
        end
        local e = pickEdge()
        for val = 1, 2 do
            local mark = tn
            if set(e, val) then search() end
            qh, qt = 1, 0
            undo(mark)
            if solutions >= limit or exhausted then return end
        end
    end
    -- Every clue is checked once up front (a 0 crosses its edges, ...).
    for cell = 1, n * n do
        if clue[cell] then qt = qt + 1; queue[qt] = -cell end
    end
    search()
    return solutions, exhausted, nodes
end

-- Search nodes allowed per uniqueness check; running out counts as "not
-- unique". With the propagation above a unique clue set is proved in under
-- 50 nodes even at 20x20 (measured on 600 puzzles), so this only cuts
-- short the rare sparse non-unique set that wanders before its second
-- solution turns up.
local function uniquenessNodeBudget(n) -- luacheck: ignore n
    return 2000
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

-- ---------------------------------------------------------------------------
-- Hints
--
-- The unit here is an edge, not a cell, so this cannot use the shared
-- Hint.install helper: a slitherlink position has two independent edge grids
-- and "R3C4" alone would not say which. Each step therefore carries its own
-- wording and a `tag` of "h" or "v", which is what lets ScreenBase tell the
-- two apart when deciding whether a second tap means "now do it".
--
-- Crossing an edge out is optional bookkeeping -- only drawn segments decide
-- the loop -- so a cross where the solution has nothing is left alone, and
-- only a missing segment is ever offered.
local function slitherlinkScan(grid_user, grid_sol, rows, cols)
    local mistake, blank
    for r = 1, rows do
        for c = 1, cols do
            local u, sol = grid_user[r][c], grid_sol[r][c]
            if (u == EDGE_LINE and not sol) or (u == EDGE_CROSS and sol) then
                mistake = mistake or { r = r, c = c }
            elseif u == EDGE_UNKNOWN and sol then
                blank = blank or { r = r, c = c }
            end
        end
    end
    return mistake, blank
end

function SlitherlinkBoard:findHint()
    if self.reveal then return nil, "stuck" end
    local n = self.n
    local mh, bh = slitherlinkScan(self.h_user, self.h_sol, n + 1, n)
    local mv, bv = slitherlinkScan(self.v_user, self.v_sol, n, n + 1)

    local function step(kind, tag, cell)
        return { kind = kind, tag = tag, r = cell.r, c = cell.c }
    end

    -- A wrong segment always comes before a fresh one: building on it wastes
    -- the player's work.
    if mh then return step("mistake", "h", mh) end
    if mv then return step("mistake", "v", mv) end
    if bh then return step("fill", "h", bh) end
    if bv then return step("fill", "v", bv) end
    return nil, "complete"
end

function SlitherlinkBoard:applyHint(step)
    if not step then return false end
    local state = (step.kind == "mistake") and EDGE_UNKNOWN or EDGE_LINE
    if step.tag == "h" then return self:setHEdge(step.r, step.c, state) ~= false end
    return self:setVEdge(step.r, step.c, state) ~= false
end

function SlitherlinkBoard:getHintsUsed()
    return self.hints_used or 0
end

function SlitherlinkBoard:noteHintUsed()
    self.hints_used = (self.hints_used or 0) + 1
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

-- exposed for the specs
SlitherlinkBoard.countSolutions = countSolutions

return SlitherlinkBoard
