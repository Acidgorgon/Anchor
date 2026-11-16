-- A's trade record is dropped only once B has APPLIED the patch (never on "message
-- accepted"); ambiguous redos are held for manual review; Update waits for a trade.
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

local function queued(key, id)
	for _, u in Sim.peek("Main", key).GlobalUpdates[2] do
		if type(u[2]) == "table" and u[2].AnchorTx == id then
			return true
		end
	end
	return false
end

T.test("B offline with 1000+ queued messages: the trade message is pushed out, A resends, no loss", function()
	Sim.configure({ latency = 0.01 })
	local filler = {}
	for i = 1, 1000 do
		filler[i] = { i, { Note = i } }
	end
	seed("A", { Coins = 500, Items = { Sword = true } })
	seed("B", { Coins = 50, Items = { Gem = true } }, filler)
	local s1 = Sim.newServer({ JobId = "S1" })
	local Anchor = anchor(s1)
	local store = Anchor.New("Main", TEMPLATE)
	local A = s1:await(store.StartSessionAsync, store, "A")
	local B = s1:await(store.StartSessionAsync, store, "B")
	local job = s1:spawn(Anchor.Trade, A, B, swap)
	B:EndSession() -- B leaves during the commit
	T.expect(Sim.awaitJobs({ job }, 60))
	T.eq(job:result(), true)
	local id = next(A.anchor_meta.Tx)
	T.expect(Sim.runUntil(function()
		return queued("B", id)
	end, 30), "sent to B's queue")
	T.eq(#Sim.peek("Main", "B").GlobalUpdates[2], 1000, "queue at its cap")

	-- 1000 more messages arrive while B is offline: the oldest (ours among them) drop off
	local s2 = Sim.newServer({ JobId = "SPAM" })
	local spam = anchor(s2).New("Main", TEMPLATE)
	local spammer = s2:spawn(function()
		for i = 1, 1000 do
			spam:MessageAsync("B", { Spam = i })
		end
	end)
	local dropped = false
	T.expect(Sim.runUntil(function()
		dropped = dropped or not queued("B", id)
		return spammer.done
	end, 3000))
	T.expect(dropped, "the trade message was pushed out of B's queue")
	T.expect(A.anchor_meta.Tx ~= nil and A.anchor_meta.Tx[id] ~= nil, "A still holds the record")
	T.expect(Sim.runUntil(function()
		return queued("B", id)
	end, 700), "A re-read B's key and resent")

	-- B comes back: applied exactly once, A's record goes away
	local s3 = Sim.newServer({ JobId = "S3" })
	local st3 = anchor(s3).New("Main", TEMPLATE)
	local B3 = s3:await(st3.StartSessionAsync, st3, "B")
	T.eq(B3.Data.Coins, 150)
	T.deepEq(B3.Data.Items, { Sword = true })
	T.eq(s3:await(B3.SaveAsync, B3), true)
	T.expect(Sim.runUntil(function()
		return A.anchor_meta.Tx == nil
	end, 700))
	T.eq(A.Data.Coins, 400)
	T.deepEq(A.Data.Items, { Gem = true })
	B3:EndSession()
	Sim.advance(5)
	local B4 = s3:await(st3.StartSessionAsync, st3, "B")
	T.eq(B4.Data.Coins, 150, "not applied twice")
end)

-- A's server dies right after A's intent landed (B never got its side).
local function crashAfterIntent()
	seed("A", { Coins = 500, Items = { Sword = true } })
	seed("B", { Coins = 50, Items = { Gem = true } })
	local s1 = Sim.newServer({ JobId = "S1" })
	local Anchor = anchor(s1)
	local store = Anchor.New("Main", TEMPLATE)
	local A = s1:await(store.StartSessionAsync, store, "A")
	local B = s1:await(store.StartSessionAsync, store, "B")
	local armed = true
	local rule = Sim.injectError({
		method = "UpdateAsync",
		key = "A",
		when = function(info)
			if armed then
				armed = false
				info.server:crash()
			end
			return false
		end,
	})
	s1:spawn(Anchor.Trade, A, B, swap)
	Sim.advance(5)
	rule:remove()
	T.allowThreadErrors()
	local raw = Sim.peek("Main", "A")
	local id = next(raw.MetaData.Anchor.Tx)
	return raw, id
end

local function loadOnNewServer(key)
	local s = Sim.newServer()
	local Anchor = anchor(s)
	local store = Anchor.New("Main", TEMPLATE)
	local errors = {}
	Anchor.OnError:Connect(function(message)
		table.insert(errors, message)
	end)
	local p = s:awaitFor(300, store.StartSessionAsync, store, key)
	return s, store, p, errors
end

T.test("a leftover record older than B's Applied window is not resent: OnError + PendingTrades", function()
	local raw, id = crashAfterIntent()
	raw.MetaData.Anchor.Tx[id].t -= 91 * 24 * 3600
	Sim.poke("Main", "A", raw)
	local _, store, A, errors = loadOnNewServer("A")
	Sim.advance(30)
	T.eq(#Sim.peek("Main", "B").GlobalUpdates[2], 0, "nothing resent")
	T.expect(#errors >= 1 and string.find(errors[#errors], "NEEDS MANUAL REVIEW", 1, true), T.show(errors))
	local pending = store:PendingTrades(A)
	T.eq(#pending, 1)
	T.eq(pending[1].Id, id)
	T.eq(pending[1].Key, "B")
	T.eq(pending[1].Status, "NeedsReview")
	T.expect(type(pending[1].Patch) == "table" and #pending[1].Patch > 0)
	-- kept across saves and later loads; still not resent
	A:EndSession()
	Sim.advance(5)
	T.expect(Sim.peek("Main", "A").MetaData.Anchor.Tx[id] ~= nil, "record kept in A's save")
	local _, _, _, errors2 = loadOnNewServer("A")
	Sim.advance(30)
	T.eq(#Sim.peek("Main", "B").GlobalUpdates[2], 0)
	T.expect(#errors2 >= 1)
end)

T.test("B forgot applied ids newer than the record (trimmed): no resend, review instead", function()
	local _, id = crashAfterIntent()
	local rawB = Sim.peek("Main", "B")
	rawB.MetaData.Anchor = { AppliedFloor = Sim.unixTime() } -- B trimmed entries up to now
	Sim.poke("Main", "B", rawB)
	local _, store, A, errors = loadOnNewServer("A")
	Sim.advance(30)
	T.eq(#Sim.peek("Main", "B").GlobalUpdates[2], 0)
	T.expect(#errors >= 1 and string.find(errors[#errors], "NEEDS MANUAL REVIEW", 1, true), T.show(errors))
	T.eq(store:PendingTrades(A)[1].Id, id)
end)

T.test("a fresh leftover record whose B never applied it is resent and lands once", function()
	local _, id = crashAfterIntent()
	local s, _, A = loadOnNewServer("A")
	T.expect(Sim.runUntil(function()
		return queued("B", id)
	end, 30))
	local store = anchor(s).New("Main", TEMPLATE)
	local B = s:await(store.StartSessionAsync, store, "B")
	T.eq(B.Data.Coins, 150)
	T.expect(Sim.runUntil(function()
		return A.anchor_meta.Tx == nil
	end, 60))
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
