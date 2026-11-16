-- Review: B's Applied ledger is pruned by count (oldest applied-time first) and the resend
-- guard compares B's AppliedFloor with the record's creation time using A's clock, with a
-- 1 h margin. If B's server clock runs > 1 h behind A's, the trade id B just applied gets
-- the OLDEST time in a full ledger (2000 recent entries, e.g. a busy trader/gift receiver),
-- is pruned in the same tick, and AppliedFloor stays below created - 1 h. A's re-read then
-- says "missing" and resends: B receives its side twice.
local T = require("@mock/testkit")
local Sim = require("@mock/sim")

local TEMPLATE = { Coins = 0, Items = {}, Bag = {} }

local function anchor(server)
	return server:require("src", { name = "Anchor" })
end

T.test("B's server clock 2 h behind + full Applied ledger: PB applied twice", function()
	local now = Sim.unixTime()
	local applied = {}
	for i = 1, 2000 do
		applied[`old-{i}`] = now - 60 -- 2000 trades/gifts in the last few minutes
	end
	Sim.poke("Main", "A", {
		Data = { Coins = 500, Items = {}, Bag = {} },
		MetaData = { ProfileCreateTime = now, SessionLoadCount = 1, LastUpdate = now, MetaTags = {} },
		GlobalUpdates = { 0, {} },
		RobloxMetaData = {},
		UserIds = {},
	})
	Sim.poke("Main", "B", {
		Data = { Coins = 0, Items = {}, Bag = {} },
		MetaData = { ProfileCreateTime = now, SessionLoadCount = 1, LastUpdate = now, MetaTags = {}, Anchor = { Applied = applied } },
		GlobalUpdates = { 0, {} },
		RobloxMetaData = {},
		UserIds = {},
	})
	Sim.configure({ latency = { 1, 1 } })
	local s1 = Sim.newServer({ JobId = "S1" })
	local An = anchor(s1)
	local st = An.New("Main", TEMPLATE)
	local A = s1:await(st.StartSessionAsync, st, "A")
	local B = s1:await(st.StartSessionAsync, st, "B")
	local job = s1:spawn(An.Trade, A, B, function(da, db)
		da.Coins -= 100
		db.Coins += 100
	end)
	Sim.advance(0.2)
	B:EndSession() -- PB goes through B's queue
	T.expect(Sim.awaitJobs({ job }, 60))
	T.eq(job:result(), true)
	Sim.advance(5)

	local s2 = Sim.newServer({ JobId = "S2", timeSkew = -2 * 3600 })
	local st2 = anchor(s2).New("Main", TEMPLATE)
	local B2 = s2:await(st2.StartSessionAsync, st2, "B")
	s2:await(B2.SaveAsync, B2)
	Sim.advance(900)
	B2:EndSession()
	A:EndSession()
	Sim.advance(30)
	T.eq(Sim.peek("Main", "A").Data.Coins + Sim.peek("Main", "B").Data.Coins, 500, "coins conserved")
	T.eq(Sim.peek("Main", "B").Data.Coins, 100, "B's side applied once")
end)
