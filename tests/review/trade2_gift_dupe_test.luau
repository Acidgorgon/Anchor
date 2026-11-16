-- Review: gifts lost their applied-id ledger; dedup is now "seen this session" only.
-- Gift's MessageAsync retries a write whose first attempt committed but reported an error,
-- so the same message (same AnchorTx id) can be queued twice. If the owner processes the
-- first copy and its session ends before the second copy lands, the next session applies
-- the gift again.
local T = require("@mock/testkit")
local Sim = require("@mock/sim")

local TEMPLATE = { Coins = 0 }

local function anchor(server)
	return server:require("src", { name = "Anchor" })
end

T.test("a gift whose send was retried after a committed-but-errored write applies twice", function()
	local s1 = Sim.newServer({ JobId = "S1" })
	local s2 = Sim.newServer({ JobId = "S2" })
	local D1 = anchor(s1).new("Main", TEMPLATE)
	local st2 = anchor(s2).New("Main", TEMPLATE)
	-- S1's first write to B commits but errors; the next 3 attempts fail (backoff 1+2+4 s).
	Sim.injectError({ method = "UpdateAsync", key = "Player_7", server = s1, phase = "after", count = 1 })
	Sim.injectError({ method = "UpdateAsync", key = "Player_7", server = s1, count = 3 })
	local job = s1:spawn(D1.Gift, D1, 7, { { "Inc", { "Coins" }, 50 } })
	Sim.advance(0.5) -- copy 1 is in B's queue
	-- B plays a short session on S2: the gift is applied at load, saved, B leaves.
	local B = s2:await(st2.StartSessionAsync, st2, "Player_7")
	T.eq(B.Data.Coins, 50)
	s2:await(B.SaveAsync, B)
	B:EndSession()
	T.expect(Sim.awaitJobs({ job }, 120))
	T.eq(job:result(), true)
	Sim.advance(5)
	local B2 = s2:await(st2.StartSessionAsync, st2, "Player_7")
	Sim.advance(5)
	T.eq(B2.Data.Coins, 50, "one gift, applied once")
end)
