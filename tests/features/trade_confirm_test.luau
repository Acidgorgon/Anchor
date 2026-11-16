-- Escrow-specific behaviour: an unreachable decision key keeps items escrowed (never
-- guesses), resolution that would overwrite changed data is held for review, a first
-- writer decides races, big trades are refused, and Update waits for a trade.
local T = require("@mock/testkit")
local Sim = require("@mock/sim")

local TEMPLATE = { Coins = 0, Items = {} }

local function anchor(server)
	return server:require("src", { name = "Anchor" })
end

local function seed(key, data, queue)
	Sim.poke("Main", key, {
		Data = data,
		MetaData = { ProfileCreateTime = Sim.unixTime(), SessionLoadCount = 1, LastUpdate = Sim.unixTime(), MetaTags = {} },
		GlobalUpdates = { queue and #queue or 0, queue or {} },
		RobloxMetaData = {},
		UserIds = {},
	})
end

local function swap(da, db)
	da.Coins -= 100
	db.Coins += 100
	da.Items.Gem, db.Items.Gem = db.Items.Gem, nil
	db.Items.Sword, da.Items.Sword = da.Items.Sword, nil
end

local function setup()
	seed("A", { Coins = 500, Items = { Sword = true } })
	seed("B", { Coins = 50, Items = { Gem = true } })
	local s = Sim.newServer({ JobId = "S1" })
	local Anchor = anchor(s)
	local store = Anchor.New("Main", TEMPLATE)
	local A = s:await(store.StartSessionAsync, store, "A")
	local B = s:await(store.StartSessionAsync, store, "B")
	return s, Anchor, store, A, B
end

T.test("decision key unreachable: Pending, items stay escrowed (unspendable), then it resolves itself", function()
	local s, Anchor, store, A, B = setup()
	local errors = {}
	Anchor.OnError:Connect(function(m)
		table.insert(errors, m)
	end)
	local rule = Sim.injectError({ method = "UpdateAsync", store = "AnchorTx" })
	local ok, reason = s:await(Anchor.Trade, A, B, swap)
	T.eq(ok, false)
	T.eq(reason, "Pending")
	T.eq(A.Data.Items.Sword, nil, "A's sword escrowed")
	T.eq(B.Data.Items.Gem, nil, "B's gem escrowed")
	T.eq(A.Data.Coins, 400)
	T.expect(#errors >= 1 and string.find(errors[1], "unreachable", 1, true), T.show(errors))
	local pending = store:PendingTrades(A)
	T.eq(#pending, 1)
	T.eq(pending[1].Role, "A")
	Sim.advance(60)
	T.expect(A.anchor_meta.Tx ~= nil, "still escrowed while the key is down")
	rule:remove()
	T.expect(Sim.runUntil(function()
		return A.anchor_meta.Tx == nil and B.anchor_meta.Tx == nil
	end, 200))
	T.eq(A.Data.Items.Gem, true, "both escrows had landed: committed")
	T.eq(B.Data.Items.Sword, true)
	T.eq(A.Data.Coins + B.Data.Coins, 550)
end)

T.test("a side loading elsewhere races the decision: one stored decision, both sides follow it", function()
	local s, Anchor, _, A, B = setup()
	Sim.configure({ latency = { 1, 1 } })
	local job = s:spawn(Anchor.Trade, A, B, swap)
	Sim.advance(0.2)
	B:EndSession()
	local s2 = Sim.newServer({ JobId = "S2" })
	local st2 = anchor(s2).New("Main", TEMPLATE)
	-- Pre-empt: S2 loads B and resolves with "abort" if it reaches the key first.
	local bjob = s2:spawn(st2.StartSessionAsync, st2, "B")
	T.expect(Sim.awaitJobs({ job, bjob }, 120))
	local B2 = bjob:result()
	T.expect(Sim.runUntil(function()
		return B2.anchor_meta.Tx == nil
	end, 60))
	local ok = job:result()
	local decision = Sim.peek("AnchorTx", Sim.keys("AnchorTx")[1]).D
	T.eq(ok, decision == "commit", "the trading server reports the stored decision")
	Sim.advance(5)
	local total = A.Data.Coins + B2.Data.Coins
	T.eq(total, 550)
	local gems = (if A.Data.Items.Gem then 1 else 0) + (if B2.Data.Items.Gem then 1 else 0)
	local swords = (if A.Data.Items.Sword then 1 else 0) + (if B2.Data.Items.Sword then 1 else 0)
	T.eq(gems, 1)
	T.eq(swords, 1)
end)

T.test("resolution that would overwrite migrated data is held: OnError + PendingTrades, record kept", function()
	T.allowThreadErrors()
	local s, Anchor, _, A, B = setup()
	-- crash right after the commit decision: both records survive in the saves
	local armed = true
	Sim.injectError({
		method = "UpdateAsync",
		store = "AnchorTx",
		when = function(info)
			if armed then
				armed = false
				info.server:crash()
			end
			return false
		end,
	})
	s:spawn(Anchor.Trade, A, B, swap)
	Sim.advance(5)
	-- B's Coins were migrated to a table before B comes back (B's incoming has Inc Coins)
	local raw = Sim.peek("Main", "B")
	raw.Data.Coins = { Amount = 50 }
	Sim.poke("Main", "B", raw)
	local s2 = Sim.newServer({ JobId = "S2" })
	local An2 = anchor(s2)
	local st2 = An2.New("Main", TEMPLATE)
	local errors = {}
	An2.OnError:Connect(function(m)
		table.insert(errors, m)
	end)
	local B2 = s2:awaitFor(300, st2.StartSessionAsync, st2, "B")
	Sim.advance(10)
	T.expect(B2.anchor_meta.Tx ~= nil, "record kept")
	T.eq(type(B2.Data.Coins), "table", "migrated value never replaced")
	T.eq(B2.Data.Items.Sword, nil, "nothing of the record applied (all or nothing)")
	T.expect(#errors >= 1 and string.find(errors[#errors], "NEEDS MANUAL REVIEW", 1, true), T.show(errors))
	local pending = st2:PendingTrades(B2)
	T.eq(pending[1].Status, "NeedsReview")
	T.expect(#pending[1].Incoming > 0)
end)

T.test("B with 1000+ queued messages: the trade does not use the queue and lands once", function()
	local filler = {}
	for i = 1, 1000 do
		filler[i] = { i, { Note = i } }
	end
	seed("A", { Coins = 500, Items = { Sword = true } })
	seed("B", { Coins = 50, Items = { Gem = true } }, filler)
	local s = Sim.newServer({ JobId = "S1" })
	local Anchor = anchor(s)
	local store = Anchor.New("Main", TEMPLATE)
	local A = s:await(store.StartSessionAsync, store, "A")
	local B = s:await(store.StartSessionAsync, store, "B")
	Sim.configure({ latency = { 1, 1 } })
	local job = s:spawn(Anchor.Trade, A, B, swap)
	Sim.advance(0.2)
	B:EndSession()
	T.expect(Sim.awaitJobs({ job }, 60))
	T.eq(job:result(), true)
	Sim.advance(5)
	T.eq(#Sim.peek("Main", "B").GlobalUpdates[2], 1000)
	local s2 = Sim.newServer({ JobId = "S2" })
	local st2 = anchor(s2).New("Main", TEMPLATE)
	local B2 = s2:await(st2.StartSessionAsync, st2, "B")
	T.expect(Sim.runUntil(function()
		return B2.anchor_meta.Tx == nil
	end, 30))
	T.eq(B2.Data.Coins, 150)
	T.deepEq(B2.Data.Items, { Sword = true })
end)

T.test("a trade that would push a side over the size limit is refused with nothing changed", function()
	local s, Anchor, _, A, B = setup()
	A.Data.Items.Statue = string.rep("x", 2100000)
	B.Data.Items.Filler = string.rep("y", 2100000)
	local ok, reason = s:await(Anchor.Trade, A, B, function(da, db)
		db.Items.Statue, da.Items.Statue = da.Items.Statue, nil
		da.Coins += 1
		db.Coins -= 1
	end)
	T.eq(ok, false)
	T.eq(reason, "TooBig")
	T.expect(A.Data.Items.Statue ~= nil)
	T.eq(A.anchor_meta.Tx, nil)
end)

T.test("Data:Update on a trading profile waits for the trade; IsTrading is true meanwhile", function()
	Sim.configure({ latency = { 1, 1 } })
	local s = Sim.newServer()
	local Anchor = anchor(s)
	local Data = Anchor.new("Main", TEMPLATE)
	Data:Bind()
	local pa, pb = s:addPlayer(1), s:addPlayer(2)
	local A = s:await(Data.Await, Data, pa)
	local B = s:await(Data.Await, Data, pb)
	A.Data.Coins, B.Data.Coins = 500, 50
	local trade = s:spawn(Anchor.Trade, A, B, function(da, db)
		da.Coins -= 100
		db.Coins += 100
	end)
	T.eq(A:IsTrading(), true)
	T.eq(B:IsTrading(), true)
	local update = s:spawn(Data.Update, Data, pb, function(data)
		data.Coins *= 2
	end)
	Sim.advance(0.5)
	T.eq(update.done, false, "waits while B is trading")
	T.eq(B.Data.Coins, 50)
	T.expect(Sim.awaitJobs({ trade, update }, 30))
	T.eq(trade:result(), true)
	T.eq(update:result(), true)
	T.eq(B.Data.Coins, 300, "(50 + 100) * 2: the update ran on the post-trade data")
	T.eq(A:IsTrading(), false)
	T.eq(B:IsTrading(), false)
end)
