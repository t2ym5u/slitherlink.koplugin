-- Difficulty guarantees for Slitherlink: every size x level builds a
-- unique puzzle quickly, the game's logic solver finishes it within the
-- level's tier and tier-2 window with no trial, Easy needs the basic rules
-- only, levels are ordered (fewer clues, more tier-2 steps), and a seed gives
-- the same puzzle without reading the clock.
local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

package.preload["gettext"] = function()
    return setmetatable({}, { __call = function(_, s) return s end })
end
package.path = DIR .. "common/?.lua;" .. DIR .. "?.lua;" .. package.path

-- Runs fn with os.clock/os.time/os.date replaced by functions that fail:
-- a generator must bound its work by counts, never by time.
local function withoutClock(fn)
    local oc, ot, od = os.clock, os.time, os.date
    local function boom(name) return function() error("generator read " .. name, 2) end end
    os.clock, os.time, os.date = boom("os.clock"), boom("os.time"), boom("os.date")
    local ok, err = pcall(fn)
    os.clock, os.time, os.date = oc, ot, od
    if not ok then error(err, 0) end
end

describe("Slitherlink difficulty", function()
    local Board

    setup(function()
        Board = require("board")
    end)

    -- 1.6.0: graded by the logic solver (tier 1 = basic rules, tier 2 =
    -- patterns, loop and inside/outside), never by trial and error.
    describe("difficulty (1.6.0)", function()
        local function share(b)
            local k = 0
            for r = 1, b.n do for c = 1, b.n do
                if b.clues[r][c] >= 0 then k = k + 1 end
            end end
            return k / (b.n * b.n)
        end

        it("every puzzle is unique and solved without trial, in its level's window", function()
            local seeds = { [5] = 30, [10] = 30, [15] = 10, [20] = 6 }
            for _, n in ipairs({ 5, 10, 15, 20 }) do
                local shares = {}
                for _, diff in ipairs({ "easy", "medium", "hard" }) do
                    local L = Board.LEVELS[diff](n)
                    local total, worst = 0, 0
                    for seed = 1, seeds[n] do
                        math.randomseed(seed * 7919 + n)
                        local b = Board:new{ n = n }
                        local t0 = os.clock()
                        b:generate(diff)
                        worst = math.max(worst, os.clock() - t0)
                        local tag = ("n=%d %s seed=%d"):format(n, diff, seed)
                        local st, steps = Board.logicSolve(b.clues, n, L.tier)
                        assert.are.equal("solved", st, tag)
                        assert.are.equal(b.t2_steps, steps, tag)
                        assert.is_true(steps >= L.min_t2 and steps <= L.max_t2, tag .. " t2=" .. steps)
                        if diff ~= "easy" then
                            -- the basic rules alone don't get there
                            assert.are_not.equal("solved", (Board.logicSolve(b.clues, n, 1)), tag)
                        end
                        local solutions, exhausted = Board.countSolutions(b.clues, n, 2, 1e6)
                        assert.is_false(exhausted, tag)
                        assert.are.equal(1, solutions, tag)
                        total = total + share(b)
                    end
                    shares[diff] = total / seeds[n]
                    -- ~50 ms worst on a desktop (LuaJIT); generous for busted
                    assert.is_true(worst < 2.0, ("n=%d %s took %.2fs"):format(n, diff, worst))
                end
                assert.is_true(shares.easy > shares.medium and shares.medium > shares.hard,
                    ("n=%d clue shares %.2f/%.2f/%.2f"):format(n, shares.easy, shares.medium, shares.hard))
            end
        end)

        it("levels ask for different amounts of tier-2 reasoning", function()
            for _, n in ipairs({ 5, 10, 15, 20 }) do
                local e, m, h = Board.LEVELS.easy(n), Board.LEVELS.medium(n), Board.LEVELS.hard(n)
                assert.are.equal(1, e.tier)
                assert.are.equal(0, e.max_t2)
                assert.is_true(m.min_t2 >= 1)
                assert.is_true(h.min_t2 > m.max_t2)
            end
        end)

        it("the same seed builds the same puzzle", function()
            for _, diff in ipairs({ "easy", "hard" }) do
                math.randomseed(2026)
                local a = Board:new{ n = 10 }; a:generate(diff)
                math.randomseed(2026)
                local b = Board:new{ n = 10 }; b:generate(diff)
                assert.are.same(a.clues, b.clues)
                assert.are.same(a.h_sol, b.h_sol)
                assert.are.same(a.v_sol, b.v_sol)
            end
        end)

        it("the logic solver never contradicts a real loop, nor decides an edge wrong", function()
            math.randomseed(99)
            local checked = 0
            for _ = 1, 150 do
                local n = math.random(4, 8)
                -- a solved puzzle's loop, with a random part of its clues
                local src = Board:new{ n = n }
                src:generate("easy")
                local clues = {}
                local all = {}
                for r = 1, n do
                    clues[r], all[r] = {}, {}
                    for c = 1, n do
                        local k = 0
                        if src.h_sol[r][c] then k = k + 1 end
                        if src.h_sol[r + 1][c] then k = k + 1 end
                        if src.v_sol[r][c] then k = k + 1 end
                        if src.v_sol[r][c + 1] then k = k + 1 end
                        all[r][c] = k
                        clues[r][c] = math.random() < 0.5 and k or -1
                    end
                end
                local st = Board.logicSolve(clues, n, 2)
                assert.are_not.equal("contradiction", st)
                if st == "solved" then
                    checked = checked + 1
                    assert.are.equal(1, (Board.countSolutions(clues, n, 2, 1e6)))
                end
                assert.are_not.equal("contradiction", (Board.logicSolve(all, n, 2)))
            end
            assert.is_true(checked > 0)
        end)

        it("tier-2 steps rise on averages: Easy < Medium < Hard", function()
            for _, n in ipairs({ 5, 10 }) do
                local avg = {}
                for _, diff in ipairs({ "easy", "medium", "hard" }) do
                    local sum = 0
                    for seed = 1, 6 do
                        math.randomseed(seed * 31 + n)
                        local b = Board:new{ n = n }
                        b:generate(diff)
                        local st, steps = Board.logicSolve(b.clues, n, 2)
                        assert.are.equal("solved", st)
                        sum = sum + steps
                    end
                    avg[diff] = sum / 6
                end
                assert.is_true(avg.easy < avg.medium and avg.medium < avg.hard,
                    ("n=%d tier-2 steps %.1f/%.1f/%.1f"):format(n, avg.easy, avg.medium, avg.hard))
            end
        end)

        it("generation never reads the clock", function()
            for _, n in ipairs({ 5, 10, 15, 20 }) do
                for _, diff in ipairs({ "easy", "medium", "hard" }) do
                    local b = Board:new{ n = n }
                    math.randomseed(n * 5)
                    withoutClock(function() b:generate(diff) end)
                end
            end
        end)
    end)
end)
