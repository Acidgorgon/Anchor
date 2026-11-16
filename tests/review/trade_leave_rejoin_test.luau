-- Review: B leaves during A's intent save (the commit window), rejoins on another server
-- before PB reaches B's queue, and gives the traded item away there. PB's "Remove Gem" is
-- then a no-op on B's newer data: the Gem exists twice (A has it from PA, C from B's 2nd
-- trade). Claim under test: "exactly-once ... even if either player leaves ... players
-- exploiting timing (leaving and rejoining during the commit window)".
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

local function countGems(datas)
	local n = 0
	for _, d in datas do
		if d.Items.Gem ~= nil then
			n += 1
		end
		for _, v in d.Bag do
			if v == "gem" then
				n += 1
			end
		end
	end
	return n
end

local function settle(keys)
	Sim.advance(120)
	local r = Sim.newServer({ JobId = "R" })
	local st = anchor(r).New("Main", TEMPLATE)
	local out = {}
	for _, k in keys do
		out[k] = r:awaitFor(300, st.StartSessionAsync, st, k)
	end
	Sim.advance(30)
	local datas = {}
	for k, p in out do
		datas[k] = p.Data
	end
	return datas
end

local function run(itemInBag)
	Sim.configure({ latency = { 1, 1 } })
	seed("A", { Coins = 500, Items = {}, Bag = {} })
	if itemInBag then
		seed("B", { Coins = 0, Items = {}, Bag = { "gem" } })
	else
		seed("B", { Coins = 0, Items = { Gem = { Shiny = true } }, Bag = {} })
	end
	seed("C", { Coins = 500, Items = {}, Bag = {} })

	local s1 = Sim.newServer({ JobId = "S1" })
	local s2 = Sim.newServer({ JobId = "S2" })
	local An1 = anchor(s1)
	local An2 = anchor(s2)
	local st1 = An1.New("Main", TEMPLATE)
	local st2 = An2.New("Main", TEMPLATE)
	local A = s1:await(st1.StartSessionAsync, st1, "A")
	local B = s1:await(st1.StartSessionAsync, st1, "B")
	local C = s2:await(st2.StartSessionAsync, st2, "C")

	-- A buys B's gem for 100 coins.
	local job = s1:spawn(An1.Trade, A, B, function(da, db)
		da.Coins -= 100
		db.Coins += 100
		if itemInBag then
			table.remove(db.Bag, table.find(db.Bag, "gem"))
			table.insert(da.Bag, "gem")
		else
			da.Items.Gem, db.Items.Gem = db.Items.Gem, nil
		end
	end)
	Sim.advance(0.2)
	B:EndSession() -- B leaves while A's intent save is in flight
	Sim.advance(1.1) -- B's release save has landed
	local bjob = s2:spawn(st2.StartSessionAsync, st2, "B")
	T.expect(Sim.awaitJobs({ bjob }, 60))
	local B2 = bjob:result()
	T.expect(B2 ~= nil, "B rejoined on S2")

	-- On S2, B still holds the gem and gives it to C for 100 coins.
	local ok2, why2 = s2:await(An2.Trade, B2, C, function(db, dc)
		if itemInBag then
			local i = table.find(db.Bag, "gem")
			if i == nil then
				return false
			end
			table.remove(db.Bag, i)
			table.insert(dc.Bag, "gem")
		else
			if db.Items.Gem == nil then
				return false
			end
			dc.Items.Gem, db.Items.Gem = db.Items.Gem, nil
		end
		dc.Coins -= 100
		db.Coins += 100
	end)
	T.expect(Sim.awaitJobs({ job }, 60))
	T.eq(job:result(), true, "A-B trade reports done")
	print(`    B->C trade on S2: {tostring(ok2)} {tostring(why2)}`)

	A:EndSession()
	B2:EndSession()
	C:EndSession()
	local d = settle({ "A", "B", "C" })
	print(`    A={T.show(d.A)} B={T.show(d.B)} C={T.show(d.C)}`)
	T.eq(d.A.Coins + d.B.Coins + d.C.Coins, 1000, "coins conserved")
	T.eq(countGems(d), 1, "exactly one gem must exist (it was traded A<-B, then B->C)")
end

T.test("B leaves mid-commit, rejoins elsewhere and trades the map item away: item duplicated", function()
	run(false)
end)

T.test("B leaves mid-commit, rejoins elsewhere and trades the array item away: item duplicated", function()
	run(true)
end)
