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

-- ---------------------------------------------------------------------------
-- Logic solver (1.6.0). Grades a clue set by the deductions a player needs,
-- and never guesses: every rule below only forces what every single-loop
-- solution consistent with the clues shares, so when it decides every edge
-- the puzzle has one solution and needs no trial and error.
--
-- Tier 1, the basic rules:
--   - a clue's line count: reached -> cross the rest; only as many
--     undecided edges as missing lines -> they're all lines;
--   - a dot has 0 or 2 lines.
-- Tier 2, patterns and the loop as a whole:
--   - one clue and its four corner dots taken together (3 or 1 in a
--     corner, a line entering a 3, ...): every way to finish that clue that
--     leaves each corner dot able to reach 0 or 2 lines;
--   - the same for two neighbouring clues (side or corner: two 3s side by
--     side, diagonal 3s, ...);
--   - a line may not close a loop that leaves other lines (or unmet clues)
--     outside it;
--   - inside/outside: every edge separates two cells (or a cell and the
--     outside); a line means they're on different sides, a cross that
--     they're on the same side. Chains of these settle edges far apart, and
--     a 1, 2 or 3 whose two neighbours are known to share a side (or not)
--     settles its other edges.
-- A tier-2 step is one application of one of these, after which tier 1
-- runs again to a standstill: the step count measures how much a puzzle
-- leans on the harder reasoning. Work is counted, never timed.
-- ---------------------------------------------------------------------------

local function buildGraph(n)
    local W  = n + 1
    local HN = (n + 1) * n
    local E  = HN + n * (n + 1)
    local ea, eb, eside1, eside2 = {}, {}, {}, {}
    local vedges, cedges, cdots = {}, {}, {}
    for d = 1, W * W do vedges[d] = {} end
    local function cellId(r, c)
        if r >= 1 and r <= n and c >= 1 and c <= n then return (r - 1) * n + c end
        return 0                                    -- the outside
    end
    for r = 1, n + 1 do for c = 1, n do             -- h[r][c]: dot (r,c)-(r,c+1)
        local e = (r - 1) * n + c
        local a, b = (r - 1) * W + c, (r - 1) * W + c + 1
        ea[e], eb[e] = a, b
        eside1[e], eside2[e] = cellId(r - 1, c), cellId(r, c)
        vedges[a][#vedges[a] + 1] = e; vedges[b][#vedges[b] + 1] = e
    end end
    for r = 1, n do for c = 1, n + 1 do             -- v[r][c]: dot (r,c)-(r+1,c)
        local e = HN + (r - 1) * (n + 1) + c
        local a, b = (r - 1) * W + c, r * W + c
        ea[e], eb[e] = a, b
        eside1[e], eside2[e] = cellId(r, c - 1), cellId(r, c)
        vedges[a][#vedges[a] + 1] = e; vedges[b][#vedges[b] + 1] = e
    end end
    for r = 1, n do for c = 1, n do
        local i = (r - 1) * n + c
        cedges[i] = { (r - 1) * n + c, r * n + c,
                      HN + (r - 1) * (n + 1) + c, HN + (r - 1) * (n + 1) + c + 1 }
        cdots[i]  = { (r - 1) * W + c, (r - 1) * W + c + 1, r * W + c, r * W + c + 1 }
    end end
    local ecells = {}                               -- edge -> its clue cells
    cedges[0] = {}                                  -- the outside: the border
    for e = 1, E do
        local l = {}
        if eside1[e] > 0 then l[#l + 1] = eside1[e] end
        if eside2[e] > 0 then l[#l + 1] = eside2[e] end
        ecells[e] = l
        if #l == 1 then cedges[0][#cedges[0] + 1] = e end
    end

    local dcells = {}                               -- dot -> cells it's a corner of
    for d = 1, W * W do dcells[d] = {} end
    for i = 1, n * n do
        for _, d in ipairs(cdots[i]) do dcells[d][#dcells[d] + 1] = i end
    end

    -- Windows, built when first needed (only clued cells have any) and
    -- shared by every candidate of one generate(). Key: first cell * 5 +
    -- kind, kind 0 = the cell alone, 1..4 = with its right, lower,
    -- lower-right or lower-left neighbour. A window's edges are its cells'
    -- edges; each of its dots lists which of those meet there (din, as
    -- indices) and its other edges (dout). An out edge belongs to one window
    -- dot only, so the dots can be checked independently once the cell
    -- edges are fixed.
    local wcache = {}
    local OFFSET = { [0] = 0, 1, n, n + 1, n - 1 }
    local function window(key)
        local w = wcache[key]
        if w then return w end
        local first, kind = math.floor(key / 5), key % 5
        local cells = { first }
        if kind > 0 then cells[2] = first + OFFSET[kind] end
        local edges, inA, inB = {}, {}, {}
        local function idxOf(e)
            for i = 1, #edges do if edges[i] == e then return i end end
        end
        for ci, cell in ipairs(cells) do
            for _, e in ipairs(cedges[cell]) do
                local i = idxOf(e)
                if not i then
                    i = #edges + 1
                    edges[i] = e; inA[i] = false; inB[i] = false
                end
                if ci == 1 then inA[i] = true else inB[i] = true end
            end
        end
        local dots, seen = {}, {}
        for _, cell in ipairs(cells) do
            for _, d in ipairs(cdots[cell]) do
                if not seen[d] then
                    seen[d] = true
                    local din, dout = {}, {}
                    for _, e in ipairs(vedges[d]) do
                        local i = idxOf(e)
                        if i then din[#din + 1] = i else dout[#dout + 1] = e end
                    end
                    dots[#dots + 1] = { din = din, dout = dout }
                end
            end
        end
        w = { cells = cells, edges = edges, inA = inA, inB = inB, dots = dots }
        wcache[key] = w
        return w
    end
    -- The windows holding a cell: alone, then with each of its 8 neighbours.
    local function cellWindows(i, out)
        local r, c = math.floor((i - 1) / n) + 1, (i - 1) % n + 1
        local k = 1
        out[k] = i * 5
        local function add(key) k = k + 1; out[k] = key end
        if c < n then add(i * 5 + 1) end
        if c > 1 then add((i - 1) * 5 + 1) end
        if r < n then add(i * 5 + 2) end
        if r > 1 then add((i - n) * 5 + 2) end
        if r < n and c < n then add(i * 5 + 3) end
        if r > 1 and c > 1 then add((i - n - 1) * 5 + 3) end
        if r < n and c > 1 then add(i * 5 + 4) end
        if r > 1 and c < n then add((i - n + 1) * 5 + 4) end
        for x = k + 1, #out do out[x] = nil end
        return out
    end

    return { n = n, W = W, HN = HN, E = E, ea = ea, eb = eb,
             eside1 = eside1, eside2 = eside2, ecells = ecells,
             vedges = vedges, cedges = cedges, dcells = dcells,
             window = window, cellWindows = cellWindows }
end

-- clue: flat array cell -> 0..4 or nil. The solver keeps a reference and
-- addClue() fills it in, so a stuck solver can be handed one more clue and
-- carry on from where it stood (a clue only ever adds constraints).
local function newSolver(G, clue)
    local n, W, E = G.n, G.W, G.E
    local ea, eb, ecells, vedges, cedges = G.ea, G.eb, G.ecells, G.vedges, G.cedges
    local eside1, eside2 = G.eside1, G.eside2
    local dcells, window, cellWindows = G.dcells, G.window, G.cellWindows

    local s, vline, vund, cline, cund = {}, {}, {}, {}, {}
    for e = 1, E do s[e] = 0 end
    for d = 1, W * W do vline[d] = 0; vund[d] = #vedges[d] end
    for i = 1, n * n do cline[i] = 0; cund[i] = 4 end
    local mate, plen = {}, {}
    for d = 1, W * W do mate[d] = d; plen[d] = 0 end
    local lines, undecided, closed = 0, E, false
    -- The loop rule looks at the whole board, so it only runs again once
    -- something it reads has changed (a new line or clue).
    local loop_dirty = true
    -- inside/outside: union-find with parity over cells (0 = the outside).
    -- A merge is the only thing that can settle an edge by sides, or let a
    -- clue relate its neighbours, so each merge lists the edges and clues
    -- around the smaller group for the rules to look at (pend_e, rel).
    local parent, par, members = {}, {}, {}
    for i = 0, n * n do parent[i] = i; par[i] = 0; members[i] = { i } end
    local pend_e, rel, rel_on = {}, {}, {}
    local function relDirty(c)
        if c > 0 and clue[c] and not rel_on[c] then rel_on[c] = true; rel[#rel + 1] = c end
    end
    local function find(i)
        local p = 0
        local r = i
        while parent[r] ~= r do p = (p + par[r]) % 2; r = parent[r] end
        -- path compression with parity
        local q = p
        while parent[i] ~= r do
            local nxt, np = parent[i], par[i]
            parent[i] = r; par[i] = q
            q = (q + np) % 2
            i = nxt
        end
        return r, p
    end
    local function union(a, b, p)   -- returns ok, merged
        local ra, pa = find(a)
        local rb, pb = find(b)
        if ra == rb then return (pa + pb) % 2 == p, false end
        if #members[ra] > #members[rb] then ra, rb = rb, ra end
        parent[ra] = rb; par[ra] = (pa + pb + p) % 2
        local into = members[rb]
        for _, x in ipairs(members[ra]) do
            into[#into + 1] = x
            for _, e in ipairs(cedges[x]) do
                if s[e] == 0 then
                    pend_e[#pend_e + 1] = e
                    relDirty(eside1[e] == x and eside2[e] or eside1[e])
                end
            end
            relDirty(x)
        end
        members[ra] = nil
        return true, true
    end

    local queue, qh, qt = {}, 1, 0               -- dots (+) / cells (-)
    -- Cells whose windows may have something new to say: those with a
    -- corner on an edge just decided. version counts decided edges, so a
    -- window seen from both its cells is only checked once per change.
    local cdirty, clist, version, wver = {}, {}, 0, {}
    local function dirtyCell(c)
        if not cdirty[c] then cdirty[c] = true; clist[#clist + 1] = c end
    end

    local bad = false
    local function set(e, val)
        local st = s[e]
        if st ~= 0 then return st == val end
        local a, b = ea[e], eb[e]
        if val == 1 then
            if closed or vline[a] >= 2 or vline[b] >= 2 then return false end
            local a_end = vline[a] == 0 and a or mate[a]
            local b_end = vline[b] == 0 and b or mate[b]
            if a_end == b then
                if plen[a] ~= lines then return false end
                closed = true
            else
                local len = (vline[a] == 0 and 0 or plen[a]) + (vline[b] == 0 and 0 or plen[b]) + 1
                mate[a_end], mate[b_end] = b_end, a_end
                plen[a_end], plen[b_end] = len, len
            end
            vline[a] = vline[a] + 1; vline[b] = vline[b] + 1
            for _, cell in ipairs(ecells[e]) do cline[cell] = cline[cell] + 1 end
            lines = lines + 1
            loop_dirty = true
        end
        s[e] = val
        vund[a] = vund[a] - 1; vund[b] = vund[b] - 1
        for _, cell in ipairs(ecells[e]) do cund[cell] = cund[cell] - 1 end
        undecided = undecided - 1
        if not union(eside1[e], eside2[e], val == 1 and 1 or 0) then return false end
        qt = qt + 1; queue[qt] = a
        qt = qt + 1; queue[qt] = b
        for _, cell in ipairs(ecells[e]) do qt = qt + 1; queue[qt] = -cell end
        version = version + 1
        for _, c in ipairs(dcells[a]) do dirtyCell(c) end
        for _, c in ipairs(dcells[b]) do dirtyCell(c) end
        return true
    end
    local function setAll(list, val)
        for _, e in ipairs(list) do
            if s[e] == 0 and not set(e, val) then return false end
        end
        return true
    end

    -- A window is live once all its cells carry a clue. Every way to finish
    -- its cells' edges that meets their clues is tried; a way stands if
    -- each window dot can still end with 0 or 2 lines through its other
    -- edges. Whatever every standing way agrees on is forced.
    -- Returns ok, changed.
    -- Per window dot: lo / uo = lines / undecided among its out edges;
    -- n0, n1, n2 = some standing way needs 0, 1 or 2 more lines out there.
    local vals, sup1, sup2 = {}, {}, {}
    local und, dlo, duo, dA, dB, n0, n1, n2 = {}, {}, {}, {}, {}, {}, {}, {}
    local w_edges, w_inA, w_inB, w_dots, kA, kB, nu, any
    local function leaf()
        local dots = w_dots
        for di = 1, #dots do
            local din = dots[di].din
            local xin = 0
            for x = 1, #din do if vals[din[x]] == 1 then xin = xin + 1 end end
            -- 0 lines in all (none in, none out yet), or 2: 2 - xin - lo more
            local lo = dlo[di]
            local zero = xin == 0 and lo == 0
            local two = 2 - xin - lo
            if two < 0 or two > duo[di] then two = nil end
            if not zero and not two then return end
            dA[di], dB[di] = zero, two
        end
        any = true
        for j = 1, nu do
            local i = und[j]
            if vals[i] == 1 then sup1[i] = true else sup2[i] = true end
        end
        for di = 1, #dots do
            if dA[di] then n0[di] = true end
            local t = dB[di]
            if t == 0 then n0[di] = true elseif t == 1 then n1[di] = true
            elseif t == 2 then n2[di] = true end
        end
    end
    -- lA/rA: lines / undecided edges so far left for the first cell; B: second
    local function enum(j, lA, rA, lB, rB)
        if j > nu then
            if lA == kA and (not kB or lB == kB) then leaf() end
            return
        end
        local i = und[j]
        local a, b = w_inA[i], w_inB[i]
        local da, db = a and 1 or 0, b and 1 or 0
        if (not a or lA < kA) and (not b or lB < kB) then
            vals[i] = 1
            enum(j + 1, lA + da, rA - da, lB + db, rB - db)
        end
        if (not a or lA + rA - 1 >= kA) and (not b or lB + rB - 1 >= kB) then
            vals[i] = 2
            enum(j + 1, lA, rA - da, lB, rB - db)
        end
    end
    local function winCheck(w)
        local cells = w.cells
        kA = clue[cells[1]]
        kB = cells[2] and clue[cells[2]]
        if not kA or (cells[2] and not kB) then return true, false end
        w_edges, w_inA, w_inB, w_dots = w.edges, w.inA, w.inB, w.dots
        nu = 0
        local lA, rA, lB, rB = 0, 0, 0, 0
        for i = 1, #w_edges do
            local v = s[w_edges[i]]
            vals[i] = v
            if v == 0 then
                nu = nu + 1; und[nu] = i
                sup1[i], sup2[i] = false, false
                if w_inA[i] then rA = rA + 1 end
                if w_inB[i] then rB = rB + 1 end
            elseif v == 1 then
                if w_inA[i] then lA = lA + 1 end
                if w_inB[i] then lB = lB + 1 end
            end
        end
        local outs = 0
        for di = 1, #w_dots do
            local lo, uo = 0, 0
            for _, e in ipairs(w_dots[di].dout) do
                local se = s[e]
                if se == 1 then lo = lo + 1 elseif se == 0 then uo = uo + 1 end
            end
            dlo[di], duo[di] = lo, uo
            n0[di], n1[di], n2[di] = false, false, false
            outs = outs + uo
        end
        if nu == 0 and outs == 0 then return true, false end
        any = false
        enum(1, lA, rA, lB, rB)
        if not any then return false, false end
        local changed = false
        for j = 1, nu do
            local i = und[j]
            local e = w_edges[i]
            local v = (not sup1[i]) and 2 or (not sup2[i]) and 1 or nil
            if v and s[e] == 0 then
                if not set(e, v) then return false, false end
                changed = true
            end
        end
        -- Out edges: with one undecided, it's a line iff 1 more is needed;
        -- with two, "1 more" lets either be either way.
        for di = 1, #w_dots do
            local uo = duo[di]
            if uo > 0 then
                local can1, can2
                if uo == 1 then can1, can2 = n1[di], n0[di]
                else can1, can2 = n1[di] or n2[di], n1[di] or n0[di] end
                local v = (not can1) and 2 or (not can2) and 1 or nil
                if v then
                    for _, e in ipairs(w_dots[di].dout) do
                        if s[e] == 0 then
                            if not set(e, v) then return false, false end
                            changed = true
                        end
                    end
                end
            end
        end
        return true, changed
    end

    -- Tier 1 to a standstill. Returns false on a contradiction.
    local function tier1()
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
            qh, qt = 1, 0
            -- once the loop is closed, every edge left is a cross
            if not (closed and undecided > 0) then return true end
            for e = 1, E do
                if s[e] == 0 and not set(e, 2) then return false end
            end
        end
    end

    local function edgeBetween(a, b)
        for _, e in ipairs(vedges[a]) do
            if ea[e] == b or eb[e] == b then return e end
        end
    end

    -- One tier-2 step. Returns ok, kind (nil when nothing applies).
    local function tier2()
        local keys = {}
        while #clist > 0 do
            local c = clist[#clist]
            if clue[c] then
                for _, key in ipairs(cellWindows(c, keys)) do
                    if wver[key] ~= version then
                        wver[key] = version
                        local ok, ch = winCheck(window(key))
                        if not ok then return false end
                        -- c stays listed: its other windows come next time
                        if ch then return true, "pattern" end
                    end
                end
            end
            clist[#clist] = nil
            cdirty[c] = false
        end
        -- loop closure
        for d = loop_dirty and 1 or math.huge, W * W do
            if vline[d] == 1 then
                local m = mate[d]
                if m > d then
                    local e = edgeBetween(d, m)
                    if e and s[e] == 0 then
                        local cross = plen[d] ~= lines
                        if not cross then
                            -- closing would end the puzzle: every clue must be met
                            for cell = 1, n * n do
                                local k = clue[cell]
                                if k then
                                    local l = cline[cell]
                                    for _, c2 in ipairs(ecells[e]) do if c2 == cell then l = l + 1 end end
                                    if l ~= k then cross = true; break end
                                end
                            end
                        end
                        if cross then
                            if not set(e, 2) then return false end
                            return true, "loop"
                        end
                    end
                end
            end
        end
        loop_dirty = false
        -- inside/outside
        while true do
            while #pend_e > 0 do
                local e = pend_e[#pend_e]
                pend_e[#pend_e] = nil
                if s[e] == 0 then
                    local ra, pa = find(eside1[e])
                    local rb, pb = find(eside2[e])
                    if ra == rb then
                        if not set(e, (pa + pb) % 2 == 1 and 1 or 2) then return false end
                        return true, "side"
                    end
                end
            end
            if #rel == 0 then return true, nil end
            local cell = rel[#rel]
            local k = clue[cell]
            if k >= 1 and k <= 3 and cund[cell] > 0 then
                local ce = cedges[cell]
                local nb = {}
                for j = 1, 4 do
                    local e = ce[j]
                    nb[j] = eside1[e] == cell and eside2[e] or eside1[e]
                end
                for i = 1, 3 do for j = i + 1, 4 do
                    local ri, pi = find(nb[i])
                    local rj, pj = find(nb[j])
                    if ri == rj then
                        local p = (pi + pj) % 2
                        local o1, o2
                        for t = 1, 4 do
                            if t ~= i and t ~= j then
                                if o1 then o2 = t else o1 = t end
                            end
                        end
                        if k == 2 then
                            if p == 0 then
                                if not union(nb[o1], nb[o2], 0) then return false end
                                if not union(nb[o1], nb[i], 1) then return false end
                            elseif not union(nb[o1], nb[o2], 1) then
                                return false
                            end
                        else
                            local val = k == 1 and 2 or 1
                            local a, b
                            if p == 0 then a, b = ce[i], ce[j] else a, b = ce[o1], ce[o2] end
                            if s[a] == 0 or s[b] == 0 then
                                -- the cell stays listed: it may have more to say
                                if not set(a, val) or not set(b, val) then return false end
                                return true, "side"
                            end
                        end
                    end
                end end
            end
            -- done with this cell (unless a merge above listed it again)
            if rel[#rel] == cell then rel[#rel] = nil; rel_on[cell] = false end
        end
    end

    local self = { s = s, cund = cund, stats = {} }
    -- Every clue is checked once, and its windows (a new clue also opens
    -- the windows it shares with its neighbours).
    local function seedClue(cell)
        qt = qt + 1; queue[qt] = -cell
        dirtyCell(cell)
        relDirty(cell)
    end
    for cell = 1, n * n do if clue[cell] then seedClue(cell) end end

    function self.addClue(cell, k)
        clue[cell] = k
        loop_dirty = true
        seedClue(cell)
        for _, key in ipairs(cellWindows(cell, {})) do
            for _, c in ipairs(window(key).cells) do dirtyCell(c) end
        end
    end

    -- max_tier 1 or 2. Returns "solved", "stuck" or "contradiction",
    -- plus the number of tier-2 steps taken in this call.
    function self.run(max_tier, max_steps)
        local steps = 0
        local stats = self.stats
        while true do
            if bad or not tier1() then bad = true; return "contradiction", steps end
            if undecided == 0 then
                if closed then return "solved", steps end
                bad = true
                return "contradiction", steps
            end
            if max_tier < 2 then return "stuck", steps end
            if max_steps and steps >= max_steps then return "stuck", steps end
            local ok, kind = tier2()
            if not ok then bad = true; return "contradiction", steps end
            if not kind then return "stuck", steps end
            steps = steps + 1
            stats[kind] = (stats[kind] or 0) + 1
        end
    end
    return self
end
-- The solver runs interpreted. Each newSolver() makes fresh closures, and
-- LuaJIT's traces are tied to the closures they were recorded with, so the
-- JIT kept recompiling the solver's many branches for every new solver:
-- most of a generation went into the compiler (20x20 Hard: worst ~135 ms
-- with the JIT, ~28 ms without, same puzzles).
if jit then jit.off(newSolver, true) end

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

-- What each level asks for (1.6.0). Before, a level only set the share of
-- clues shown (85/70/55 %) and checked that the loop was unique: Easy was
-- solved by the basic rules alone, Hard at times needed trial and error,
-- and a candidate that wasn't unique was retried with more clues, up to
-- all of them.
--   keep            share of clues drawn at first; the solver then asks for
--                   one more clue wherever it gets stuck
--   max_share       past this share of clues the loop is dropped: some
--                   stretches of a loop stay ambiguous whatever is shown
--   tier            1: the basic rules alone solve it; 2: patterns and
--                   loop reasoning too (see the logic solver above)
--   min_t2/max_t2   how many tier-2 steps the solution needs
-- Easy: basic rules only, many clues.
-- Medium: a few patterns or loop deductions.
-- Hard: fewer clues, many of them.
-- Never trial and error, at any level.
local LEVELS = {
    easy   = function(n) return { keep = 0.55, max_share = 0.9, tier = 1, -- luacheck: ignore n
                                  min_t2 = 0, max_t2 = 0 } end,
    medium = function(n) return { keep = 0.55, max_share = 0.75, tier = 2,
                                  min_t2 = 1, max_t2 = math.max(3, math.floor(n * 0.4)) } end,
    hard   = function(n) return { keep = 0.25, max_share = 0.55, tier = 2,
                                  min_t2 = math.max(4, math.floor(n / 2)), max_t2 = math.huge } end,
}

-- Loop shapes drawn per puzzle, and clue sets tried per shape.
local SHAPES, CLUE_SETS = 40, 3

-- Builds a clue set for one loop: a random share of its clues, then, each
-- time the solver stalls, the clue of the cell with the most undecided
-- edges around it (cells visited in a shuffled order, so ties don't pile up
-- in one corner). Medium also stops at max_t2 tier-2 steps and asks for a
-- clue there instead. Returns the clue set (flat) and the tier-2 steps a
-- fresh solve needs, or nil when the loop can't be made solvable.
local function buildClues(G, full, level)
    local n = G.n
    local N = n * n
    local order = {}
    for i = 1, N do order[i] = i end
    shuffle(order)
    local clue = {}
    for i = 1, N do
        if math.random() <= level.keep then clue[i] = full[i] end
    end
    local sv = newSolver(G, clue)
    local budget = level.max_t2 < math.huge and level.max_t2 or nil
    local st, steps = sv.run(level.tier, budget)
    local shown, max_shown = 0, math.floor(level.max_share * N)
    for i = 1, N do if clue[i] then shown = shown + 1 end end
    while st == "stuck" do
        shown = shown + 1
        if shown > max_shown then return nil end
        if budget then budget = math.max(0, budget - steps) end
        local best, best_u = nil, 0
        for _, i in ipairs(order) do
            if not clue[i] and sv.cund[i] > best_u then best, best_u = i, sv.cund[i] end
        end
        if not best then return nil end
        sv.addClue(best, full[best])
        st, steps = sv.run(level.tier, budget)
    end
    if st ~= "solved" then return nil end

    -- Grade from scratch: a clue added late may make an earlier step moot.
    local final = {}
    for i = 1, N do final[i] = clue[i] end
    local grader = newSolver(G, final)
    st, steps = grader.run(level.tier)
    if st ~= "solved" then return nil end
    return clue, steps, grader.s
end

function SlitherlinkBoard:generate(difficulty, on_progress)
    self.difficulty = difficulty or self.difficulty
    self.reveal     = false
    self.undo:clear()

    local n = self.n
    local level = (LEVELS[self.difficulty] or LEVELS.easy)(n)
    local G = buildGraph(n)
    local W, HN = n + 1, (n + 1) * n

    -- The logic solver's edges must be the loop's, edge for edge.
    local function matches(s, h_sol, v_sol)
        for r = 1, n + 1 do for c = 1, n do
            if (s[(r - 1) * n + c] == 1) ~= h_sol[r][c] then return false end
        end end
        for r = 1, n do for c = 1, W do
            if (s[HN + (r - 1) * W + c] == 1) ~= v_sol[r][c] then return false end
        end end
        return true
    end

    local best
    for shape = 1, SHAPES do
        local h_sol, v_sol, full_clues = tryGenerate(n)
        if h_sol then
            local full = {}
            for r = 1, n do for c = 1, n do full[(r - 1) * n + c] = full_clues[r][c] end end
            for _ = 1, CLUE_SETS do
                local clue, t2, s = buildClues(G, full, level)
                if not clue then break end
                if matches(s, h_sol, v_sol) then
                    local miss = t2 < level.min_t2 and level.min_t2 - t2
                              or t2 > level.max_t2 and t2 - level.max_t2 or 0
                    if not best or miss < best.miss then
                        best = { h_sol = h_sol, v_sol = v_sol, clue = clue, t2 = t2, miss = miss }
                    end
                    if miss == 0 then break end
                end
            end
        end
        if on_progress then on_progress(shape / SHAPES) end
        if best and best.miss == 0 then break end
    end

    local h_sol, v_sol, clues
    if best then
        h_sol, v_sol = best.h_sol, best.v_sol
        clues = emptyGrid(n, n, -1)
        for r = 1, n do for c = 1, n do
            local k = best.clue[(r - 1) * n + c]
            if k then clues[r][c] = k end
        end end
        self.t2_steps = best.t2
    else
        -- Never reached in practice (every size finds a loop in its first
        -- few shapes): the border loop with every clue shown, which the
        -- basic rules solve.
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
        self.t2_steps = 0
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
SlitherlinkBoard.LEVELS         = LEVELS
-- logicSolve(clues2d, n, max_tier) -> "solved"|"stuck"|"contradiction", tier-2 steps
function SlitherlinkBoard.logicSolve(clues, n, max_tier)
    local flat = {}
    for r = 1, n do for c = 1, n do
        local k = clues[r][c]
        if k and k >= 0 then flat[(r - 1) * n + c] = k end
    end end
    local sv = newSolver(buildGraph(n), flat)
    return sv.run(max_tier or 2)
end

return SlitherlinkBoard
