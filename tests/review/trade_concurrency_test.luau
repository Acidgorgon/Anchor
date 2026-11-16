-- Review (held up): overlapping trades A-B, B-C, A-C, C-D ... on one server with write
-- conflicts (transform re-runs), random latency, dropped MessagingService pings, and
-- duplicated MessageAsync deliveries of a trade message. Coins and unique items are conserved.
local T = require("@mock/testkit")
local Sim = require("@mock/sim")

local TEMPLATE = { Coins = 0, Items = {}, Bag = {} }

local function anchor(server)
	return server:require("src", { name = "Anchor" })
end

local KEYS = { "A", "B", "C", "D" }

local function seedAll()
	for i, k in KEYS do
		local items, bag = {}, {}
		for j = 1, 3 do
			items[`{k}{j}`] = { From = k }
			table.insert(bag, `{k}-bag{j}`)
		end
		Sim.poke("Main", k, {
			Data = { Coins = 1000, Items = items, Bag = bag },
			MetaData = { ProfileCreateTime = 0, SessionLoadCount = 1, LastUpdate = Sim.unixTime(), MetaTags = {} },
			GlobalUpdates = { 0, {} },
			RobloxMetaData = {},
			UserIds = {},
		})
	end
end

local function census(datas)
	local coins, items, bag = 0, {}, {}
	for _, d in datas do
		coins += d.Coins
		for name in d.Items do
			items[name] = (items[name] or 0) + 1
		end
		for _, v in d.Bag do
			bag[v] = (bag[v] or 0) + 1
		end
	end
	return coins, items, bag
end

T.test("overlapping random trades with conflicts and jitter conserve everything", function()
	Sim.configure({ conflictRate = 0.4, latency = { 0.05, 1.5 }, messageDropRate = 0.5 })
	seedAll()
	local s = Sim.newServer({ JobId = "S1" })
	local An = anchor(s)
	local st = An.New("Main", TEMPLATE)
	local P = {}
	for _, k in KEYS do
		P[k] = s:await(st.StartSessionAsync, st, k)
	end
	local x = 7
	local function rand(n)
		x = (x * 1103515245 + 12345) % 2147483648
		return 1 + (x // 65536) % n
	end
	local jobs = {}
	for _ = 1, 60 do
		local i = rand(4)
		local j = rand(3)
		if j >= i then
			j += 1
		end
		local a, b = P[KEYS[i]], P[KEYS[j]]
		table.insert(jobs, s:spawn(An.Trade, a, b, function(da, db)
			local amt = rand(50)
			da.Coins -= amt
			db.Coins += amt
			local name = next(da.Items)
			if name then
				db.Items[name], da.Items[name] = da.Items[name], nil
			end
			local v = table.remove(db.Bag, 1)
			if v then
				table.insert(da.Bag, v)
			end
		end, { Timeout = 600 }))
		Sim.advance(0.1 * rand(5))
	end
	T.expect(Sim.awaitJobs(jobs, 900))
	Sim.advance(400)
	for _, p in P do
		p:EndSession()
	end
	Sim.advance(30)
	local datas = {}
	for _, k in KEYS do
		datas[k] = Sim.peek("Main", k).Data
		T.eq(Sim.peek("Main", k).MetaData.Anchor and Sim.peek("Main", k).MetaData.Anchor.Tx, nil, k .. " has no pending tx")
	end
	local coins, items, bag = census(datas)
	T.eq(coins, 4000)
	for name, n in items do
		T.eq(n, 1, name)
	end
	for name, n in bag do
		T.eq(n, 1, name)
	end
end)

T.test("a trade message queued twice (same id) is applied once", function()
	Sim.poke("Main", "B", {
		Data = { Coins = 0, Items = {}, Bag = {} },
		MetaData = { ProfileCreateTime = 0, SessionLoadCount = 1, LastUpdate = Sim.unixTime(), MetaTags = {} },
		GlobalUpdates = { 0, {} },
		RobloxMetaData = {},
		UserIds = {},
	})
	local s = Sim.newServer({ JobId = "S1" })
	local st = anchor(s).New("Main", TEMPLATE)
	local msg = { AnchorTx = "X", Patch = { { "Inc", { "Coins" }, 10 }, { "Push", { "Bag" }, "gem" } } }
	T.eq(s:await(st.MessageAsync, st, "B", msg), true)
	T.eq(s:await(st.MessageAsync, st, "B", msg), true)
	local B = s:await(st.StartSessionAsync, st, "B")
	T.eq(s:await(st.MessageAsync, st, "B", msg), true)
	Sim.advance(400)
	T.eq(B.Data.Coins, 10)
	T.deepEq(B.Data.Bag, { "gem" })
end)
