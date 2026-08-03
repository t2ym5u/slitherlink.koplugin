local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

package.preload["gettext"] = function()
    return setmetatable({}, { __call = function(_, s) return s end })
end
package.path = DIR .. "common/?.lua;" .. DIR .. "?.lua;" .. package.path

describe("SlitherlinkBoard", function()
    local Board

    setup(function()
        Board = require("board")
    end)


    local function newBoard(n, diff)
        math.randomseed(42)
        local b = Board:new{ n = n or 5 }
        b:generate(diff or "easy")
        return b
    end

    describe("construction", function()
        it("creates a 5×5 board by default", function()
            local b = Board:new()
            assert.are.equal(5, b.n)
        end)

        it("starts with all edges unknown", function()
            local b = Board:new{ n = 5 }
            local n = b.n
            for r = 1, n+1 do
                for c = 1, n do
                    assert.are.equal(Board.EDGE_UNKNOWN, b.h_user[r][c])
                end
            end
            for r = 1, n do
                for c = 1, n+1 do
                    assert.are.equal(Board.EDGE_UNKNOWN, b.v_user[r][c])
                end
            end
        end)
    end)

    describe("generate", function()
        it("solution has at least one line edge", function()
            local b = newBoard(5)
            local n   = b.n
            local cnt = 0
            for r = 1, n+1 do for c = 1, n do   if b.h_sol[r][c] then cnt = cnt + 1 end end end
            for r = 1, n do   for c = 1, n+1 do if b.v_sol[r][c] then cnt = cnt + 1 end end end
            assert.is_true(cnt > 0, "solution has no line edges")
        end)

        it("clue values are in range [-1, 4]", function()
            local b = newBoard(5)
            for r = 1, b.n do
                for c = 1, b.n do
                    assert.is_true(b.clues[r][c] >= -1 and b.clues[r][c] <= 4,
                        ("clue[%d][%d] = %d out of range"):format(r, c, b.clues[r][c]))
                end
            end
        end)

        it("clue cells match solution edge count", function()
            math.randomseed(7)
            local b = Board:new{ n = 5 }
            b:generate("easy")
            local n = b.n
            for r = 1, n do
                for c = 1, n do
                    if b.clues[r][c] >= 0 then
                        local cnt = 0
                        if b.h_sol[r][c]   then cnt = cnt + 1 end
                        if b.h_sol[r+1][c] then cnt = cnt + 1 end
                        if b.v_sol[r][c]   then cnt = cnt + 1 end
                        if b.v_sol[r][c+1] then cnt = cnt + 1 end
                        assert.are.equal(b.clues[r][c], cnt,
                            ("clue[%d][%d] %d != %d"):format(r, c, b.clues[r][c], cnt))
                    end
                end
            end
        end)
    end)

    describe("setHEdge / setVEdge / cycle", function()
        it("setHEdge sets a horizontal edge", function()
            local b = newBoard(5)
            local ok = b:setHEdge(1, 1, Board.EDGE_LINE)
            assert.is_true(ok)
            assert.are.equal(Board.EDGE_LINE, b.h_user[1][1])
        end)

        it("cycleHEdge cycles through states", function()
            local b = newBoard(5)
            assert.are.equal(Board.EDGE_UNKNOWN, b.h_user[1][1])
            b:cycleHEdge(1, 1)
            assert.are.equal(Board.EDGE_LINE, b.h_user[1][1])
            b:cycleHEdge(1, 1)
            assert.are.equal(Board.EDGE_CROSS, b.h_user[1][1])
            b:cycleHEdge(1, 1)
            assert.are.equal(Board.EDGE_UNKNOWN, b.h_user[1][1])
        end)

        it("setVEdge rejects out-of-range indices", function()
            local b = newBoard(5)
            assert.is_false(b:setVEdge(0, 1, Board.EDGE_LINE))
            assert.is_false(b:setVEdge(1, 7, Board.EDGE_LINE))
        end)
    end)

    describe("undo", function()
        it("canUndo is false before any edge action", function()
            local b = newBoard(5)
            assert.is_false(b:canUndo())
        end)

        it("undoes a horizontal edge change", function()
            local b = newBoard(5)
            b:setHEdge(1, 1, Board.EDGE_LINE)
            assert.is_true(b:canUndo())
            Board.undo(b)
            assert.are.equal(Board.EDGE_UNKNOWN, b.h_user[1][1])
            assert.is_false(b:canUndo())
        end)

        it("undoes a vertical edge change", function()
            local b = newBoard(5)
            b:setVEdge(1, 1, Board.EDGE_CROSS)
            Board.undo(b)
            assert.are.equal(Board.EDGE_UNKNOWN, b.v_user[1][1])
        end)
    end)

    describe("checkProgress", function()
        it("marks a wrong LINE edge", function()
            math.randomseed(42)
            local b = Board:new{ n = 5 }
            b:generate("easy")
            -- Find a solution-false h_edge and mark it as LINE
            local r, c
            for rr = 1, b.n+1 do
                for cc = 1, b.n do
                    if not b.h_sol[rr][cc] then r, c = rr, cc; goto done end
                end
            end
            ::done::
            if not r then return end
            b.h_user[r][c] = Board.EDGE_LINE
            b:checkProgress()
            assert.is_true(b.wrong_h[r][c])
        end)
    end)

    describe("isSolved", function()
        it("returns false for untouched board", function()
            local b = newBoard(5)
            assert.is_false(b:isSolved())
        end)

        it("returns true when user matches solution exactly", function()
            math.randomseed(42)
            local b = Board:new{ n = 5 }
            b:generate("easy")
            local n = b.n
            for r = 1, n+1 do
                for c = 1, n do
                    b.h_user[r][c] = b.h_sol[r][c] and Board.EDGE_LINE or Board.EDGE_CROSS
                end
            end
            for r = 1, n do
                for c = 1, n+1 do
                    b.v_user[r][c] = b.v_sol[r][c] and Board.EDGE_LINE or Board.EDGE_CROSS
                end
            end
            assert.is_true(b:isSolved())
        end)
    end)

    describe("getRemainingEdges", function()
        it("counts unknown edges", function()
            local b = newBoard(5)
            local n = b.n
            local total = (n+1)*n + n*(n+1)
            assert.are.equal(total, b:getRemainingEdges())
        end)
    end)

    describe("serialize / load", function()
        it("round-trips board state", function()
            math.randomseed(42)
            local b = Board:new{ n = 5 }
            b:generate("easy")
            b:setHEdge(1, 1, Board.EDGE_LINE)

            local data = b:serialize()
            local b2   = Board:new{ n = 5 }
            local ok   = b2:load(data)
            assert.is_true(ok)
            assert.are.equal(b.n, b2.n)
            assert.are.equal(Board.EDGE_LINE, b2.h_user[1][1])
            -- Clues preserved
            for r = 1, b.n do
                for c = 1, b.n do
                    assert.are.equal(b.clues[r][c], b2.clues[r][c])
                end
            end
        end)

        it("load returns false for invalid data", function()
            local b = Board:new()
            assert.is_false(b:load(nil))
            assert.is_false(b:load({}))
        end)
    end)
end)
