-- Review: A's intent write COMMITS but the call reports an error (timeout after commit),
-- the two retries fail -> Anchor.Trade returns false, "SaveFailed" ("The trade was undone;
-- nothing changed") and undoes A in memory. The DataStore however holds A with PA + Tx[id].
-- If A's server dies before A's next successful write, A's next load delivers PB: the
-- "failed" trade happens after all, onto B's newer data. If B (told the trade failed) gave
-- the item to C meanwhile, PB's Remove is a no-op and the item exists twice.
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

local function buyGem(da, db)
	if db.Items.Gem == nil then
		return false
	end
	da.Coins -= 100
	db.Coins += 100
	da.Items.Gem, db.Items.Gem = db.Items.Gem, nil
end

local function setup()
	seed("A", { Coins = 500, Items = {}, Bag = {} })
	seed("B", { Coins = 0, Items = { Gem = { Shiny = true } }, Bag = {} })
	seed("C", { Coins = 500, Items = {}, Bag = {} })
	local s1 = Sim.newServer({ JobId = "S1" })
	local An = anchor(s1)
	local st = An.New("Main", TEMPLATE)
	local A = s1:await(st.StartSessionAsync, st, "A")
	local B = s1:await(st.StartSessionAsync, st, "B")
	local C = s1:await(st.StartSessionAsync, st, "C")
	return s1, An, st, A, B, C
end

local function failIntent()
	-- 1st write of A: commits, caller sees an error. 2nd and 3rd: fail before commit.
	Sim.injectError({ method = "UpdateAsync", key = "A", phase = "after", count = 1 })
	Sim.injectError({ method = "UpdateAsync", key = "A", count = 2 })
end

local function reload(keys)
	local r = Sim.newServer({ JobId = "R" })
	local st = anchor(r).New("Main", TEMPLATE)
	local out = {}
	for _, k in keys do
		out[k] = r:awaitFor(300, st.StartSessionAsync, st, k)
	end
	Sim.advance(120)
	for _, p in out do
		p:EndSession()
	end
	Sim.advance(10)
	local r2 = Sim.newServer({ JobId = "R2" })
	local st2 = anchor(r2).New("Main", TEMPLATE)
	local d = {}
	for _, k in keys do
		d[k] = r2:awaitFor(300, st2.StartSessionAsync, st2, k).Data
	end
	return d
end

T.test("SaveFailed is returned although A's intent landed; a crash later completes the 'failed' trade", function()
	T.allowThreadErrors()
	local s1, An, _, A, B = setup()
	failIntent()
	local ok, reason = s1:await(An.Trade, A, B, buyGem)
	T.eq(ok, false)
	T.eq(reason, "SaveFailed")
	T.eq(A.Data.Coins, 500, "undone in memory")
	T.expect(Sim.peek("Main", "A").MetaData.Anchor ~= nil, "...but the DataStore holds A's Tx record")
	T.eq(Sim.peek("Main", "A").Data.Coins, 400, "...and PA")
	Sim.advance(5)
	s1:crash() -- before A's next autosave
	local d = reload({ "A", "B" })
	T.eq(d.A.Coins, 500, "the game was told nothing changed")
	T.eq(d.B.Items.Gem ~= nil, true, "the game was told nothing changed")
end)

T.test("SaveFailed-but-landed + B gives the gem to C + crash: gem duplicated", function()
	T.allowThreadErrors()
	local s1, An, _, A, B, C = setup()
	failIntent()
	local ok, reason = s1:await(An.Trade, A, B, buyGem)
	T.eq(ok, false)
	T.eq(reason, "SaveFailed")
	Sim.clearInjectedErrors()
	-- B still has the gem (trade failed) and sells it to C; that trade fully completes.
	local ok2 = s1:await(An.Trade, B, C, function(db, dc)
		dc.Items.Gem, db.Items.Gem = db.Items.Gem, nil
		dc.Coins -= 100
		db.Coins += 100
	end)
	T.eq(ok2, true)
	Sim.advance(10)
	T.eq(Sim.peek("Main", "C").Data.Items.Gem ~= nil, true)
	s1:crash() -- A had no write since the "failed" trade
	local d = reload({ "A", "B", "C" })
	local gems = 0
	for _, x in d do
		if x.Items.Gem ~= nil then
			gems += 1
		end
	end
	print(`    A={T.show(d.A)} B={T.show(d.B)} C={T.show(d.C)}`)
	T.eq(d.A.Coins + d.B.Coins + d.C.Coins, 1000, "coins conserved")
	T.eq(gems, 1, "one gem in the world")
end)
