-- Anchor.Trade: happy path, cancellation, errors, locks, live proxies, leaving mid-trade,
-- gifts, and patch redo onto newer data.
local T = require("@mock/testkit")
local Sim = require("@mock/sim")

local TEMPLATE = { Coins = 0, Items = {}, Bag = {} }

local function anchor(server)
	return server:require("src", { name = "Anchor" })
end

local function load(s, store, key)
	return s:await(store.StartSessionAsync, store, key)
end

local function seed(storeName, key, data)
	Sim.poke(storeName, key, {
		Data = data,
		MetaData = { ProfileCreateTime = Sim.unixTime(), SessionLoadCount = 1, LastUpdate = Sim.unixTime(), MetaTags = {} },
		GlobalUpdates = { 0, {} },
		RobloxMetaData = {},
		UserIds = {},
	})
end

local function swap(da, db)
	if da.Coins < 100 or db.Items.Gem == nil then
		return false
	end
	da.Coins -= 100
	db.Coins += 100
	da.Items.Gem, db.Items.Gem = db.Items.Gem, nil
	db.Items.Sword, da.Items.Sword = da.Items.Sword, nil
end

local function setup()
	seed("Main", "A", { Coins = 500, Items = { Sword = { Level = 3 } }, Bag = { "apple" } })
	seed("Main", "B", { Coins = 50, Items = { Gem = { Shiny = true } }, Bag = { "pear" } })
	local s = Sim.newServer({ JobId = "S1" })
	local Anchor = anchor(s)
	local store = Anchor.New("Main", TEMPLATE)
	local A = load(s, store, "A")
	local B = load(s, store, "B")
	return s, Anchor, store, A, B
end

T.test("happy path: both sides change, both saved, tx record cleared, B applied once", function()
	local s, Anchor, _, A, B = setup()
	local ok, reason = s:await(Anchor.Trade, A, B, swap)
	T.eq(ok, true, tostring(reason))
	T.eq(A.Data.Coins, 400)
	T.eq(B.Data.Coins, 150)
	T.deepEq(A.Data.Items, { Gem = { Shiny = true } })
	T.deepEq(B.Data.Items, { Sword = { Level = 3 } })
	Sim.advance(5)
	local ra, rb = Sim.peek("Main", "A"), Sim.peek("Main", "B")
	T.eq(ra.Data.Coins, 400)
	T.eq(rb.Data.Coins, 150)
	T.deepEq(rb.Data.Items, { Sword = { Level = 3 } })
	T.eq(ra.MetaData.Anchor, nil, "A's tx record dropped after B confirmed")
	T.expect(type(rb.MetaData.Anchor.Applied) == "table", "B remembers the applied tx")
	local n = 0
	for _ in rb.MetaData.Anchor.Applied do
		n += 1
	end
	T.eq(n, 1)
end)

T.test("fn returns false -> Cancelled, fn errors -> Error; nothing changes or saves", function()
	local s, Anchor, _, A, B = setup()
	local writes = Sim.stats().calls.UpdateAsync or 0
	local ok, reason = s:await(Anchor.Trade, A, B, function(da)
		da.Coins = 0
		return false
	end)
	T.eq(ok, false)
	T.eq(reason, "Cancelled")
	local ok2, reason2, msg = s:await(Anchor.Trade, A, B, function(da, db)
		da.Coins = 0
		db.Coins = 0
		error("boom")
	end)
	T.eq(ok2, false)
	T.eq(reason2, "Error")
	T.expect(string.find(msg, "boom", 1, true), msg)
	T.eq(A.Data.Coins, 500)
	T.eq(B.Data.Coins, 50)
	T.eq((Sim.stats().calls.UpdateAsync or 0) - writes, 0, "no DataStore writes")
	T.eq(A.anchor_meta.Tx, nil)
end)

T.test("invalid args: same profile, inactive profile, unstorable draft values", function()
	local s, Anchor, store, A, B = setup()
	local ok, reason = s:await(Anchor.Trade, A, A, swap)
	T.eq(ok, false)
	T.eq(reason, "Invalid")
	local ok2, reason2 = s:await(Anchor.Trade, A, B, function(da)
		da.Thing = function() end
	end)
	T.eq(ok2, false)
	T.eq(reason2, "Invalid")
	local ok3, reason3 = s:await(Anchor.Trade, A, B, function(da)
		da.Coins = 0 / 0
	end)
	T.eq(ok3, false)
	T.eq(reason3, "Invalid")
	T.eq(A.Data.Thing, nil)
	B:EndSession()
	Sim.advance(2)
	local ok4, reason4 = s:await(Anchor.Trade, A, B, swap)
	T.eq(ok4, false)
	T.eq(reason4, "Inactive")
	local _ = store
end)

T.test("concurrent trades on one profile queue; the second sees the first's result", function()
	local s, Anchor, store, A, B = setup()
	seed("Main", "C", { Coins = 0, Items = {}, Bag = {} })
	local C = load(s, store, "C")
	local function pay300(da, dc)
		if da.Coins < 300 then
			return false
		end
		da.Coins -= 300
		dc.Coins += 300
	end
	local j1 = s:spawn(Anchor.Trade, A, B, pay300)
	local j2 = s:spawn(Anchor.Trade, A, C, pay300)
	T.expect(Sim.awaitJobs({ j1, j2 }, 60))
	local r1, r2 = { j1:result() }, { j2:result() }
	T.eq(r1[1], true)
	T.eq(r2[1], false)
	T.eq(r2[2], "Cancelled", "second trade ran after the first and saw 200 coins")
	T.eq(A.Data.Coins, 200)
	T.eq(B.Data.Coins, 350)
	T.eq(C.Data.Coins, 0)

	-- Busy: a lock held longer than the timeout
	local slow = s:spawn(Anchor.Trade, A, B, function()
		s.task.wait(5)
	end)
	local busy = { s:await(Anchor.Trade, A, C, pay300, { Timeout = 1 }) }
	T.eq(busy[1], false)
	T.eq(busy[2], "Busy")
	T.expect(Sim.awaitJobs({ slow }, 20))
end)

T.test("many trades in a row keep totals exact (currency is conserved)", function()
	local s, Anchor, _, A, B = setup()
	for i = 1, 20 do
		local ok = s:await(Anchor.Trade, A, B, function(da, db)
			local amount = (i % 3) + 1
			if i % 2 == 0 then
				da.Coins -= amount
				db.Coins += amount
			else
				db.Coins -= amount
				da.Coins += amount
			end
		end)
		T.eq(ok, true)
	end
	Sim.advance(10)
	T.eq(A.Data.Coins + B.Data.Coins, 550)
	local ra, rb = Sim.peek("Main", "A"), Sim.peek("Main", "B")
	T.eq(ra.Data.Coins + rb.Data.Coins, 550)
	T.eq(ra.MetaData.Anchor, nil)
end)

T.test("array items move by value; arrays never get holes", function()
	local s, Anchor, _, A, B = setup()
	A.Data.Bag = { "apple", "kiwi", "plum" }
	B.Data.Bag = { "pear" }
	local ok = s:await(Anchor.Trade, A, B, function(da, db)
		table.remove(da.Bag, 2) -- kiwi
		table.insert(db.Bag, "kiwi")
		table.remove(db.Bag, 1) -- pear
		table.insert(da.Bag, "pear")
	end)
	T.eq(ok, true)
	table.sort(A.Data.Bag)
	T.deepEq(A.Data.Bag, { "apple", "pear", "plum" })
	table.sort(B.Data.Bag)
	T.deepEq(B.Data.Bag, { "kiwi" })
end)

T.test("player leaves mid-trade: A ends its session during the commit -> trade still lands once", function()
	local s, Anchor, _, A, B = setup()
	Sim.configure({ latency = { 1, 1 } })
	local job = s:spawn(Anchor.Trade, A, B, swap)
	Sim.advance(0.2) -- A's intent save is in flight
	A:EndSession()
	T.expect(Sim.awaitJobs({ job }, 60))
	T.eq(job:result(), true)
	Sim.advance(10)
	local ra, rb = Sim.peek("Main", "A"), Sim.peek("Main", "B")
	T.eq(ra.Data.Coins, 400)
	T.eq(rb.Data.Coins, 150)
	T.eq(ra.MetaData.ActiveSession, nil)
end)

T.test("player leaves while fn runs -> Inactive, nothing changes", function()
	local s, Anchor, _, A, B = setup()
	local job = s:spawn(Anchor.Trade, A, B, function(da, db)
		swap(da, db)
		A:EndSession() -- the player leaves while fn runs
	end)
	T.expect(Sim.awaitJobs({ job }, 60))
	local ok, reason = job:result()
	-- A became inactive while fn ran: the trade is refused, nothing changed
	T.eq(ok, false)
	T.eq(reason, "Inactive")
	Sim.advance(5)
	T.eq(Sim.peek("Main", "A").Data.Coins, 500)
	T.eq(B.Data.Coins, 50)
end)

T.test("B leaves mid-trade: PB goes through B's message queue and is applied on B's next load", function()
	local s, Anchor, store, A, B = setup()
	Sim.configure({ latency = { 1, 1 } })
	local job = s:spawn(Anchor.Trade, A, B, swap)
	Sim.advance(0.2)
	B:EndSession()
	T.expect(Sim.awaitJobs({ job }, 60))
	T.eq(job:result(), true)
	Sim.advance(10)
	local rb = Sim.peek("Main", "B")
	T.eq(rb.Data.Coins, 50, "B released before the patch arrived")
	T.eq(#rb.GlobalUpdates[2], 1, "patch waits in B's queue")
	T.expect(A.anchor_meta.Tx ~= nil, "A keeps its record until B has applied it")
	-- B joins another server: applied at load, exactly once
	local s2 = Sim.newServer({ JobId = "S2" })
	local st2 = anchor(s2).New("Main", TEMPLATE)
	local B2 = load(s2, st2, "B")
	T.eq(B2.Data.Coins, 150)
	T.deepEq(B2.Data.Items, { Sword = { Level = 3 } })
	B2:EndSession()
	Sim.advance(5)
	T.expect(Sim.runUntil(function()
		return A.anchor_meta.Tx == nil
	end, 400), "A re-read B's key, saw Applied, dropped the record")
	Sim.advance(5)
	T.eq(Sim.peek("Main", "A").MetaData.Anchor, nil)
	local B3 = load(s2, st2, "B")
	T.eq(B3.Data.Coins, 150, "not applied twice")
	T.eq(#Sim.peek("Main", "B").GlobalUpdates[2], 0)
	local _ = store
end)

T.test("redo onto newer B data keeps B's progress (increments, per-key sets)", function()
	local s, Anchor, _, A, B = setup()
	-- Crash right after A's intent landed: B never got its side on this server.
	local armed = true
	Sim.injectError({
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
	s:spawn(Anchor.Trade, A, B, swap)
	Sim.advance(5)
	T.expect(not s.alive)
	T.allowThreadErrors()

	-- B plays on S2 first and makes progress
	local s2 = Sim.newServer({ JobId = "S2" })
	local st2 = anchor(s2).New("Main", TEMPLATE)
	local B2 = load(s2, st2, "B")
	T.eq(B2.Data.Coins, 50)
	B2.Data.Coins += 1000
	B2.Data.Items.Shield = true
	table.insert(B2.Data.Bag, "melon")
	T.eq(s2:await(B2.SaveAsync, B2), true)

	-- A comes back on S3: recovery redelivers PB to B (on S2) through MessagingService
	local s3 = Sim.newServer({ JobId = "S3" })
	local st3 = anchor(s3).New("Main", TEMPLATE)
	local A3 = load(s3, st3, "A")
	T.eq(A3.Data.Coins, 400)
	T.expect(Sim.runUntil(function()
		return B2.Data.Coins ~= 1050
	end, 30), "patch reached B")
	T.eq(B2.Data.Coins, 1150, "increment on top of progress")
	T.deepEq(B2.Data.Items, { Shield = true, Sword = { Level = 3 } })
	T.deepEq(B2.Data.Bag, { "pear", "melon" })
	Sim.advance(20)
	T.expect(A3.anchor_meta.Tx ~= nil, "applied in B's memory only: A keeps its record")
	T.expect(Sim.runUntil(function()
		return A3.anchor_meta.Tx == nil
	end, 700), "cleared after B's save with Applied landed and A re-read it")
end)

T.test("live proxies: writes go through the proxy; a rejected field falls back to the plain table", function()
	local s, Anchor, _, A, B = setup()
	local log = {}
	local function proxy(plain, path, rejectKey)
		return setmetatable({}, {
			__index = function(_, k)
				local v = plain[k]
				if type(v) == "table" then
					return proxy(v, path .. "." .. tostring(k), rejectKey)
				end
				return v
			end,
			__newindex = function(_, k, v)
				if k == rejectKey then
					error("schema: bad write to " .. k)
				end
				table.insert(log, path .. "." .. tostring(k))
				plain[k] = v
			end,
		})
	end
	local errors = {}
	Anchor.OnError:Connect(function(message)
		table.insert(errors, message)
	end)
	local liveA = proxy(A.Data, "A", "Coins")
	local liveB = proxy(B.Data, "B", nil)
	local ok = s:await(Anchor.Trade, A, B, swap, { Live = { liveA, liveB } })
	T.eq(ok, true)
	T.eq(A.Data.Coins, 400, "fallback wrote the plain table")
	T.eq(B.Data.Coins, 150)
	T.deepEq(A.Data.Items, { Gem = { Shiny = true } })
	T.deepEq(B.Data.Items, { Sword = { Level = 3 } })
	T.expect(table.find(log, "A.Items.Gem"), "A's item went through the proxy")
	T.expect(table.find(log, "B.Coins"), "B's coins went through the proxy")
	T.expect(table.find(log, "B.Items.Sword"))
	T.eq(table.find(log, "A.Coins"), nil)
	T.expect(#errors >= 1 and string.find(errors[1], "Data.Coins", 1, true), errors[1])
	-- assigned tables are fresh copies, not the patch's tables
	T.expect(B.Data.Items.Sword ~= A.anchor_meta.Tx, "")
	Sim.advance(5)
	T.eq(Sim.peek("Main", "A").Data.Coins, 400)
end)

T.test("Gift: online elsewhere, offline, and idempotent with an Id", function()
	local s1 = Sim.newServer({ JobId = "S1" })
	local s2 = Sim.newServer({ JobId = "S2" })
	local D1 = anchor(s1).new("Main", TEMPLATE)
	local D2 = anchor(s2).new("Main", TEMPLATE)
	D2:Bind()
	local p = s2:addPlayer(5)
	local prof = s2:await(D2.Await, D2, p)
	prof.Data.Coins = 7

	-- online on another server
	T.eq(s1:await(D1.Gift, D1, 5, function(data)
		data.Coins += 100
		data.Items.Hat = true
	end), true)
	T.expect(Sim.runUntil(function()
		return prof.Data.Coins == 107
	end, 30))
	T.eq(prof.Data.Items.Hat, true)

	-- the same Id twice: once
	for _ = 1, 2 do
		T.eq(s1:await(D1.Gift, D1, 5, { { "Inc", { "Coins" }, 1 } }, { Id = "login-bonus" }), true)
	end
	-- (owner pings within 6 s of each other are coalesced by stock; the autosave picks it up)
	T.expect(Sim.runUntil(function()
		return prof.Data.Coins ~= 107
	end, 400))
	Sim.advance(30)
	T.eq(prof.Data.Coins, 108)

	-- offline player (never joined): delivered on first join
	T.eq(s1:await(D1.Gift, D1, 9, function(data)
		data.Coins += 5
	end), true)
	local q = s2:addPlayer(9)
	local qp = s2:await(D2.Await, D2, q)
	T.eq(qp.Data.Coins, 5)
end)

T.test("A's intent save keeps failing while A is active -> SaveFailed, undone in memory", function()
	local s, Anchor, _, A, B = setup()
	local rule = Sim.injectError({ method = "UpdateAsync", key = "A" })
	local ok, reason = s:await(Anchor.Trade, A, B, swap)
	T.eq(ok, false)
	T.eq(reason, "SaveFailed")
	T.eq(A.Data.Coins, 500)
	T.deepEq(A.Data.Items, { Sword = { Level = 3 } })
	T.deepEq(A.Data.Bag, { "apple" })
	T.eq(A.anchor_meta.Tx, nil)
	T.eq(B.Data.Coins, 50)
	rule:remove()
	T.eq(s:await(A.SaveAsync, A), true)
	T.eq(Sim.peek("Main", "A").Data.Coins, 500)
	-- and a later trade works
	T.eq(s:await(Anchor.Trade, A, B, swap), true)
	T.eq(B.Data.Coins, 150)
end)

T.test("A's intent save fails, then A leaves: the release save carries the tx and the trade lands", function()
	local s, Anchor, _, A, B = setup()
	local rule = Sim.injectError({ method = "UpdateAsync", key = "A", count = 1 })
	local job = s:spawn(Anchor.Trade, A, B, swap)
	Sim.advance(0.5) -- first attempt failed, trade is backing off
	T.eq(rule.hits, 1)
	A:EndSession()
	T.expect(Sim.awaitJobs({ job }, 60))
	T.eq(job:result(), true)
	Sim.advance(5)
	T.eq(Sim.peek("Main", "A").Data.Coins, 400)
	T.eq(Sim.peek("Main", "B").Data.Coins, 150)
	T.eq(B.Data.Coins, 150)
end)

T.test("A's session is stolen before any write of the trade lands -> SessionLost, nothing changed", function()
	local s, Anchor, _, A, B = setup()
	local rule = Sim.injectError({ method = "UpdateAsync", key = "A", server = s })
	local job = s:spawn(Anchor.Trade, A, B, swap, { Timeout = 5 })
	Sim.advance(0.5)
	-- another server steals A
	local s2 = Sim.newServer({ JobId = "S2" })
	local st2 = anchor(s2).New("Main", TEMPLATE)
	local A2 = s2:await(st2.StartSessionAsync, st2, "A", { Steal = true })
	T.expect(A2)
	rule:remove()
	T.expect(Sim.awaitJobs({ job }, 120))
	local ok, reason = job:result()
	T.eq(ok, false)
	T.eq(reason, "SessionLost")
	T.eq(A2.Data.Coins, 500)
	Sim.advance(30)
	T.eq(B.Data.Coins, 50)
	T.eq(A2.Data.Coins, 500)
end)
