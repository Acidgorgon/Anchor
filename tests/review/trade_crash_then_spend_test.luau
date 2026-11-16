-- Review: S1 crashes right after A's intent write lands (before B's save). B's side now
-- lives only in A's save and is redone when A next loads. Until then B's stored data still
-- holds the gem, and B plays on. If B gives the gem away before A comes back, the later
-- redo of PB ("Remove Gem" / "Pull gem") is a no-op and the gem exists twice.
-- The existing crash tests (tests/features/trade_crash_test.luau) reload both players
-- without letting either act in between, so they cannot see this.
local T = require("@mock/testkit")
local Sim = require("@mock/sim")

local TEMPLATE = { Coins = 0, Items = {}, Bag = {} }

local function anchor(server)
	return server:require("src", { name = "Anchor" })
end

local function seed(key, data)
	Sim.poke("Main", key, {
		Data = data,
		MetaData = { ProfileCreateTime = Sim.unixTime(), SessionLoadCount = 1, LastUpdate = Sim.unixTime(), MetaTags = {} },
		GlobalUpdates = { 0, {} },
		RobloxMetaData = {},
		UserIds = {},
	})
end

T.test("crash after A's intent, B gives the gem to C before A reloads: gem duplicated", function()
	T.allowThreadErrors()
	seed("A", { Coins = 500, Items = {}, Bag = {} })
	seed("B", { Coins = 0, Items = { Gem = { Shiny = true } }, Bag = {} })
	seed("C", { Coins = 500, Items = {}, Bag = {} })
	local s1 = Sim.newServer({ JobId = "S1" })
	local An1 = anchor(s1)
	local st1 = An1.New("Main", TEMPLATE)
	local A = s1:await(st1.StartSessionAsync, st1, "A")
	local B = s1:await(st1.StartSessionAsync, st1, "B")

	local armed = true
	local rule = Sim.injectError({
		method = "UpdateAsync",
		key = "A",
		when = function(info)
			if armed then
				armed = false
				info.server:crash() -- dies after the intent commits (it is in the 2nd half of the call)
			end
			return false
		end,
	})
	s1:spawn(An1.Trade, A, B, function(da, db)
		da.Coins -= 100
		db.Coins += 100
		da.Items.Gem, db.Items.Gem = db.Items.Gem, nil
	end)
	Sim.advance(5)
	rule:remove()
	T.expect(not s1.alive)
	-- [adjusted for the escrow protocol: A's first write is its escrow, not "intent with PA"]
	T.expect(Sim.peek("Main", "A").MetaData.Anchor.Tx ~= nil, "A's escrow landed")

	-- B and C play on S2 (session of B on dead S1 is stolen after the usual wait).
	local s2 = Sim.newServer({ JobId = "S2" })
	local An2 = anchor(s2)
	local st2 = An2.New("Main", TEMPLATE)
	local B2 = s2:awaitFor(300, st2.StartSessionAsync, st2, "B")
	local C2 = s2:await(st2.StartSessionAsync, st2, "C")
	-- [adjusted: a leftover escrow record resolves (here: abort -> refund) right after load]
	T.expect(Sim.runUntil(function()
		return B2.anchor_meta.Tx == nil
	end, 30), "B's escrow resolved")
	T.expect(B2.Data.Items.Gem ~= nil, "B still holds the gem while A is offline")
	local ok = s2:await(An2.Trade, B2, C2, function(db, dc)
		if db.Items.Gem == nil then
			return false
		end
		dc.Items.Gem, db.Items.Gem = db.Items.Gem, nil
		dc.Coins -= 100
		db.Coins += 100
	end)
	T.eq(ok, true)
	Sim.advance(10)

	-- A comes back later on S3: recovery redelivers PB to B (on S2).
	local s3 = Sim.newServer({ JobId = "S3" })
	local st3 = anchor(s3).New("Main", TEMPLATE)
	local A3 = s3:awaitFor(300, st3.StartSessionAsync, st3, "A")
	Sim.advance(400)
	A3:EndSession()
	B2:EndSession()
	C2:EndSession()
	Sim.advance(10)
	local a, b, c = Sim.peek("Main", "A").Data, Sim.peek("Main", "B").Data, Sim.peek("Main", "C").Data
	print(`    A={T.show(a)} B={T.show(b)} C={T.show(c)}`)
	T.eq(a.Coins + b.Coins + c.Coins, 1000, "coins conserved")
	local gems = (if a.Items.Gem then 1 else 0) + (if b.Items.Gem then 1 else 0) + (if c.Items.Gem then 1 else 0)
	T.eq(gems, 1, "one gem in the world")
end)
