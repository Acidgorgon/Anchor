-- Anchor core, multi-server: session contention and handoff, crash recovery, messages,
-- and the compatibility contract with stock ProfileStore 1.0.3 servers on the same keys.
local T = require("@mock/testkit")
local Sim = require("@mock/sim")

local STOCK = "reference/ProfileStore-1.0.3.luau"
local TEMPLATE = { Coins = 0, Items = {}, Settings = { Music = true } }

local function anchor(server)
	return server:require("src", { name = "Anchor" })
end

local function stock(server)
	return server:require(STOCK, { name = "ProfileStore" })
end

local function load(s, store, key, params)
	return s:await(store.StartSessionAsync, store, key, params)
end

local function rich()
	local cards = {}
	for i = 1, 40 do
		cards[i] = { Id = "card" .. i, Level = i % 7, Xp = i * 13.5, Shiny = i % 5 == 0, Tags = { "a", "b" } }
	end
	return { Coins = 123456789, Items = { "Sword", "Shield" }, Settings = { Music = false }, Cards = cards }
end

----------------------------------------------------------------------------
-- Anchor <-> Anchor
----------------------------------------------------------------------------

T.test("two servers: second load asks the owner to release via PS_ message, data handed over", function()
	local s1 = Sim.newServer({ JobId = "A" })
	local s2 = Sim.newServer({ JobId = "B" })
	local st1 = anchor(s1).New("PlayerData", TEMPLATE)
	local st2 = anchor(s2).New("PlayerData", TEMPLATE)
	local p1 = load(s1, st1, "Player_1")
	p1.Data.Coins = 10
	local reason
	p1.OnLastSave:Connect(function(r)
		reason = r
	end)
	local t0 = Sim.now()
	local p2 = load(s2, st2, "Player_1")
	T.expect(p2, "second server got the profile")
	T.expect(Sim.now() - t0 < 10, `handoff took {Sim.now() - t0} s`)
	T.eq(reason, "External")
	T.expect(not p1:IsActive())
	T.eq(p2.Data.Coins, 10)
	T.eq(p2.SessionLoadCount, 2)
	T.expect(Sim.stats().publishes >= 1)
end)

T.test("messages dropped: the waiting server steals after SESSION_STEAL; old owner stops writing", function()
	Sim.configure({ messageDropRate = 1 })
	local s1 = Sim.newServer({ JobId = "A" })
	local s2 = Sim.newServer({ JobId = "B" })
	local st1 = anchor(s1).New("PlayerData", TEMPLATE)
	local st2 = anchor(s2).New("PlayerData", TEMPLATE)
	local p1 = load(s1, st1, "Player_1")
	p1.Data.Coins = 1
	T.eq(s1:await(p1.SaveAsync, p1), true)
	local ended = false
	p1.OnSessionEnd:Connect(function()
		ended = true
	end)
	local t0 = Sim.now()
	local p2 = load(s2, st2, "Player_1")
	T.expect(p2)
	local took = Sim.now() - t0
	T.expect(took >= 40 and took < 60, `steal after {took} s`)
	T.eq(p2.Data.Coins, 1)
	p1.Data.Coins = 666 -- the old owner can't write any more
	p1:Save()
	Sim.advance(2)
	T.expect(ended, "old owner noticed")
	T.eq(Sim.peek("PlayerData", "Player_1").Data.Coins, 1)
end)

T.test("crashed owner: after ASSUME_DEAD another server takes the profile at once", function()
	local s1 = Sim.newServer({ JobId = "A" })
	local st1 = anchor(s1).New("PlayerData", TEMPLATE)
	local p1 = load(s1, st1, "Player_1")
	p1.Data.Coins = 5
	T.eq(s1:await(p1.SaveAsync, p1), true)
	s1:crash()
	Sim.advance(640)
	local s2 = Sim.newServer({ JobId = "B" })
	local st2 = anchor(s2).New("PlayerData", TEMPLATE)
	local t0 = Sim.now()
	local p2 = load(s2, st2, "Player_1")
	T.expect(Sim.now() - t0 < 2, "no conflict handling needed")
	T.eq(p2.Data.Coins, 5)
end)

T.test("Steal = true takes the session immediately", function()
	local s1 = Sim.newServer({ JobId = "A" })
	local s2 = Sim.newServer({ JobId = "B" })
	local p1 = load(s1, anchor(s1).New("PlayerData", TEMPLATE), "Player_1")
	local st2 = anchor(s2).New("PlayerData", TEMPLATE)
	local t0 = Sim.now()
	local p2 = load(s2, st2, "Player_1", { Steal = true })
	T.expect(p2 and Sim.now() - t0 < 2)
	local _ = p1
end)

T.test("MessageAsync from another server reaches the owner's MessageHandler and is cleared", function()
	local s1 = Sim.newServer({ JobId = "A" })
	local s2 = Sim.newServer({ JobId = "B" })
	local st1 = anchor(s1).New("PlayerData", TEMPLATE)
	local st2 = anchor(s2).New("PlayerData", TEMPLATE)
	local p1 = load(s1, st1, "Player_1")
	local got = {}
	p1:MessageHandler(function(message, processed)
		table.insert(got, message)
		p1.Data.Coins += message.Gift
		processed()
	end)
	T.eq(s2:await(st2.MessageAsync, st2, "Player_1", { Gift = 25 }), true)
	T.expect(Sim.runUntil(function()
		return #got == 1
	end, 15), "delivered via PS_ ping + save")
	T.eq(got[1].Gift, 25)
	T.eq(s1:await(p1.SaveAsync, p1), true)
	local raw = Sim.peek("PlayerData", "Player_1")
	T.eq(raw.Data.Coins, 25)
	T.eq(#raw.GlobalUpdates[2], 0, "processed message removed")
	T.eq(raw.GlobalUpdates[1], 1)
end)

T.test("messages queued while offline are handed to MessageHandler after load", function()
	local s = Sim.newServer()
	local store = anchor(s).New("PlayerData", TEMPLATE)
	for i = 1, 3 do
		T.eq(s:await(store.MessageAsync, store, "Player_1", { Gift = i }), true)
	end
	local p = load(s, store, "Player_1")
	local total = 0
	p:MessageHandler(function(m, processed)
		total += m.Gift
		processed()
	end)
	T.eq(total, 6)
	p:EndSession()
	Sim.advance(2)
	T.eq(#Sim.peek("PlayerData", "Player_1").GlobalUpdates[2], 0)
end)

T.test("clean-save skip: idle profile writes less but the lock never gets near ASSUME_DEAD", function()
	local s1 = Sim.newServer({ JobId = "A" })
	local A = anchor(s1)
	A.SetConstant("AUTO_SAVE_PERIOD", 30)
	local st1 = A.New("PlayerData", TEMPLATE, { LockRefresh = 120 })
	local p1 = load(s1, st1, "Player_1")
	local maxAge = 0
	local writes = 0
	local lastWrite = Sim.now()
	local lastUpdate = Sim.peek("PlayerData", "Player_1").MetaData.LastUpdate
	for _ = 1, 1500 do
		Sim.advance(1)
		local lu = Sim.peek("PlayerData", "Player_1").MetaData.LastUpdate
		if lu ~= lastUpdate then
			writes += 1
			lastUpdate = lu
			lastWrite = Sim.now()
		end
		maxAge = math.max(maxAge, Sim.now() - lastWrite)
	end
	T.expect(writes >= 9 and writes <= 14, `{writes} lock refreshes in 1500 s (stock: ~50 autosaves)`)
	T.expect(maxAge <= 120 + 30 + 2, `lock age reached {maxAge} s`)
	T.expect(p1.skipped_saves > 25, `skipped {p1.skipped_saves}`)

	-- A change is saved by the next autosave.
	p1.Data.Coins = 9
	Sim.advance(32)
	T.eq(Sim.peek("PlayerData", "Player_1").Data.Coins, 9)

	-- Another server never sees a dead-looking lock: it negotiates a handoff instead.
	local s2 = Sim.newServer({ JobId = "B" })
	local st2 = anchor(s2).New("PlayerData", TEMPLATE)
	Sim.advance(100)
	local p2 = load(s2, st2, "Player_1")
	T.eq(p2.Data.Coins, 9)
	T.expect(not p1:IsActive())
end)

T.test("clean-save skip: LockRefresh is clamped so a huge value still refreshes before ASSUME_DEAD", function()
	local s1 = Sim.newServer({ JobId = "A" })
	local A = anchor(s1)
	A.SetConstant("AUTO_SAVE_PERIOD", 60)
	local p1 = load(s1, A.New("PlayerData", TEMPLATE, { LockRefresh = 100000 }), "Player_1")
	local lastUpdate = Sim.peek("PlayerData", "Player_1").MetaData.LastUpdate
	local maxAge = 0
	for _ = 1, 3000 do
		Sim.advance(1)
		local raw = Sim.peek("PlayerData", "Player_1")
		maxAge = math.max(maxAge, Sim.unixTime() - raw.MetaData.LastUpdate)
	end
	T.expect(maxAge < 630 * 0.75 + 2, `lock age reached {maxAge} s`)
	T.expect(p1.skipped_saves > 0)
	local _ = lastUpdate
end)

T.test("clean-save skip: processed messages, UserIds, RobloxMetaData and IsDirty are respected", function()
	local s = Sim.newServer()
	local A = anchor(s)
	A.SetConstant("AUTO_SAVE_PERIOD", 20)
	local dirty = false
	local cleared = 0
	local store = A.New("PlayerData", TEMPLATE, {
		LockRefresh = 300,
		IsDirty = function()
			return dirty
		end,
		ClearDirty = function()
			dirty = false
			cleared += 1
		end,
	})
	local p = load(s, store, "Player_1")
	Sim.advance(25)
	p:AddUserId(77)
	Sim.advance(25)
	T.deepEq(Sim.peek("PlayerData", "Player_1").UserIds, { 77 })
	p.RobloxMetaData.X = 1
	Sim.advance(25)
	T.eq(Sim.peek("PlayerData", "Player_1").RobloxMetaData.X, 1)

	-- IsDirty false: skipped without even encoding; true: written and cleared.
	p.Data.Coins = 3 -- a write behind the tracker's back...
	Sim.advance(25)
	T.eq(Sim.peek("PlayerData", "Player_1").Data.Coins, 0, "trusted IsDirty = false")
	dirty = true
	Sim.advance(25)
	T.eq(Sim.peek("PlayerData", "Player_1").Data.Coins, 3)
	T.expect(cleared >= 1)
	-- ...and a release always writes everything.
	p.Data.Coins = 4
	p:EndSession()
	Sim.advance(2)
	T.eq(Sim.peek("PlayerData", "Player_1").Data.Coins, 4)
end)

----------------------------------------------------------------------------
-- Mixed fleet: stock ProfileStore and Anchor on the same keys
----------------------------------------------------------------------------

T.test("mixed fleet: stock -> Anchor -> stock handoffs keep every change", function()
	local sS = Sim.newServer({ JobId = "STOCK" })
	local sA = Sim.newServer({ JobId = "ANCHOR" })
	local stockStore = stock(sS).New("PlayerData", TEMPLATE)
	local anchorStore = anchor(sA).New("PlayerData", TEMPLATE)

	local ps = load(sS, stockStore, "Player_1")
	ps.Data.Coins = 1
	table.insert(ps.Data.Items, "FromStock")
	local stockGotMsg
	ps:MessageHandler(function(m, processed)
		stockGotMsg = m
		processed()
	end)

	-- Anchor takes it from the stock server (stock answers the PS_ request):
	local pa = load(sA, anchorStore, "Player_1")
	T.expect(pa, "Anchor loaded from stock")
	T.expect(not ps:IsActive())
	T.eq(pa.Data.Coins, 1)
	T.deepEq(pa.Data.Items, { "FromStock" })
	T.eq(pa.SessionLoadCount, 2)
	pa.Data.Coins = 2
	table.insert(pa.Data.Items, "FromAnchor")
	pa.Data.Cards = rich().Cards
	T.eq(sA:await(pa.SaveAsync, pa), true)
	local raw = Sim.peek("PlayerData", "Player_1")
	T.eq(raw.MetaData.Anchor, nil)
	T.eq(raw.MetaData.SessionLoadCount, 2)

	-- Stock messages the Anchor-held profile:
	local got
	pa:MessageHandler(function(m, processed)
		got = m
		processed()
	end)
	T.eq(sS:await(stockStore.MessageAsync, stockStore, "Player_1", { Hi = "anchor" }), true)
	T.expect(Sim.runUntil(function()
		return got ~= nil
	end, 15))

	-- Stock takes it back from Anchor (Anchor answers the PS_ request):
	local ps2 = load(sS, stockStore, "Player_1")
	T.expect(ps2, "stock loaded from Anchor")
	T.expect(not pa:IsActive())
	T.eq(ps2.Data.Coins, 2)
	T.deepEq(ps2.Data.Items, { "FromStock", "FromAnchor" })
	T.deepEq(ps2.Data.Cards, rich().Cards)
	T.eq(ps2.SessionLoadCount, 3)

	-- Anchor messages the stock-held profile:
	ps2:MessageHandler(function(m, processed)
		stockGotMsg = m
		processed()
	end)
	T.eq(sA:await(anchorStore.MessageAsync, anchorStore, "Player_1", { Hi = "stock" }), true)
	T.expect(Sim.runUntil(function()
		return stockGotMsg ~= nil and stockGotMsg.Hi == "stock"
	end, 15))

	-- and once more to Anchor, then release and check the final stored value.
	ps2.Data.Coins = 3
	local pa2 = load(sA, anchorStore, "Player_1")
	T.eq(pa2.Data.Coins, 3)
	pa2:EndSession()
	Sim.advance(2)
	raw = Sim.peek("PlayerData", "Player_1")
	T.eq(raw.Data.Coins, 3)
	T.eq(raw.MetaData.ActiveSession, nil)
	T.eq(raw.MetaData.SessionLoadCount, 4)
	T.eq(#raw.GlobalUpdates[2], 0)
end)

T.test("Compat writes exactly the stock envelope (same keys, same Data JSON)", function()
	local sS = Sim.newServer({ JobId = "S" })
	local sA = Sim.newServer({ JobId = "A" })
	local stores = { stock(sS).New("Stock", TEMPLATE), anchor(sA).New("Anchor", TEMPLATE) }
	local servers = { sS, sA }
	for i, store in stores do
		local p = load(servers[i], store, "K")
		for k, v in rich() do
			p.Data[k] = v
		end
		p:AddUserId(5)
		p:EndSession()
	end
	Sim.advance(2)
	local a, b = Sim.peek("Stock", "K"), Sim.peek("Anchor", "K")
	local function keys(t)
		local out = {}
		for k in t do
			table.insert(out, k)
		end
		table.sort(out)
		return table.concat(out, ",")
	end
	T.eq(keys(b), keys(a))
	T.eq(keys(b.MetaData), keys(a.MetaData))
	T.eq(Sim.JSON.encode(b.Data), Sim.JSON.encode(a.Data))
	T.deepEq(b.UserIds, a.UserIds)
	T.deepEq(b.GlobalUpdates, a.GlobalUpdates)
end)

----------------------------------------------------------------------------
-- Compact format vs stock
----------------------------------------------------------------------------

local function compactProfile()
	-- An Anchor Compact server creates and releases a profile; returns its stored value.
	local s = Sim.newServer({ JobId = "COMPACT" })
	local store = anchor(s).New("PlayerData", TEMPLATE, { Format = "Compact" })
	local p = load(s, store, "Player_1")
	for k, v in rich() do
		p.Data[k] = v
	end
	p:EndSession()
	Sim.advance(2)
	return Sim.peek("PlayerData", "Player_1"), s, store
end

T.test("Compact profile: poisoned counter, blob data, Anchor reads it back", function()
	local raw, s, store = compactProfile()
	T.eq(raw.MetaData.SessionLoadCount, "Anchor")
	T.eq(raw.MetaData.Anchor.LoadCount, 1)
	T.eq(typeof(raw.Data.AnchorBlob), "buffer")
	local n = 0
	for _ in raw.Data do
		n += 1
	end
	T.eq(n, 1)
	T.expect(#Sim.rawJson("PlayerData", "Player_1") < #Sim.JSON.encode(rich()), "smaller than plain JSON")
	local p = load(s, store, "Player_1")
	T.deepEq(p.Data, rich())
	T.eq(p.SessionLoadCount, 2)
	T.eq(Sim.peek("PlayerData", "Player_1").MetaData.Anchor.LoadCount, 2)
end)

T.test("Compact profile + stock server: stock never loads it and never changes Data", function()
	-- (no uncaught thread errors expected: stock catches its own transform error)
	local before = compactProfile()
	local sS = Sim.newServer({ JobId = "STOCK" })
	local PS = stock(sS)
	local stockErrors = {}
	PS.OnError:Connect(function(m)
		table.insert(stockErrors, m)
	end)
	local stockStore = PS.New("PlayerData", TEMPLATE)

	-- 1. released profile
	local versionsBefore = #Sim.versions("PlayerData", "Player_1")
	local t0 = Sim.now()
	local p = load(sS, stockStore, "Player_1")
	T.eq(p, nil, "stock gives up")
	T.expect(Sim.now() - t0 >= 120, "after its START_SESSION_TIMEOUT")
	T.eq(#Sim.versions("PlayerData", "Player_1"), versionsBefore, "stock wrote nothing")
	T.expect(#stockErrors > 0 and string.find(stockErrors[1], "arithmetic", 1, true), stockErrors[1])
	local after = Sim.peek("PlayerData", "Player_1")
	T.deepEq(after.Data, before.Data, "blob untouched")
	T.eq(after.MetaData.SessionLoadCount, "Anchor")
	T.eq(after.MetaData.ActiveSession, nil)

	-- 2. Steal = true
	T.eq(load(sS, stockStore, "Player_1", { Steal = true }), nil)
	T.deepEq(Sim.peek("PlayerData", "Player_1").Data, before.Data)

	-- 3. held by a live Anchor server: stock's ForceLoad makes Anchor release, stock still fails
	local sA = Sim.newServer({ JobId = "ANCHOR2" })
	local aStore = anchor(sA).New("PlayerData", TEMPLATE, { Format = "Compact" })
	local pa = load(sA, aStore, "Player_1")
	pa.Data.Coins = 1
	T.eq(load(sS, stockStore, "Player_1"), nil)
	T.expect(not pa:IsActive(), "Anchor honoured stock's ForceLoad request")
	local raw = Sim.peek("PlayerData", "Player_1")
	T.eq(raw.MetaData.SessionLoadCount, "Anchor")
	T.expect(typeof(raw.Data.AnchorBlob) == "buffer")
	T.eq(sA:await(aStore.GetAsync, aStore, "Player_1").Data.Coins, 1, "release saved the change")

	-- 4. held by a crashed Anchor server: stock's ASSUME_DEAD path still can't claim it
	local pa2 = load(sA, aStore, "Player_1")
	T.expect(pa2, "Anchor loads it again (stale ForceLoadSession is harmless)")
	pa2.Data.Coins = 2
	T.eq(sA:await(pa2.SaveAsync, pa2), true)
	local saved = Sim.peek("PlayerData", "Player_1")
	sA:crash()
	Sim.advance(700)
	T.eq(load(sS, stockStore, "Player_1"), nil)
	T.deepEq(Sim.peek("PlayerData", "Player_1").Data, saved.Data)

	-- 5. stock MessageAsync still works and is delivered to the next Anchor owner
	T.eq(sS:await(stockStore.MessageAsync, stockStore, "Player_1", { Gift = 5 }), true)
	local sB = Sim.newServer({ JobId = "ANCHOR3" })
	local bStore = anchor(sB).New("PlayerData", TEMPLATE, { Format = "Compact" })
	local pb = load(sB, bStore, "Player_1")
	T.eq(pb.Data.Coins, 2)
	local gift
	pb:MessageHandler(function(m, processed)
		gift = m.Gift
		processed()
	end)
	T.eq(gift, 5)
end)

T.test("Compact -> Compat: the writer un-poisons and stock can load it again", function()
	compactProfile()
	local sA = Sim.newServer({ JobId = "COMPAT" })
	local st = anchor(sA).New("PlayerData", TEMPLATE) -- default Compat writer
	local p = load(sA, st, "Player_1")
	T.deepEq(p.Data, rich(), "Compat writer reads Compact")
	T.eq(p.SessionLoadCount, 2)
	local raw = Sim.peek("PlayerData", "Player_1")
	T.eq(raw.MetaData.SessionLoadCount, "Anchor", "still poisoned until the first plain write")
	p.Data.Coins = 1
	p:EndSession()
	Sim.advance(2)
	raw = Sim.peek("PlayerData", "Player_1")
	T.eq(raw.MetaData.SessionLoadCount, 2)
	T.eq(raw.MetaData.Anchor, nil)
	T.eq(raw.Data.Coins, 1)
	T.eq(raw.Data.AnchorBlob, nil)

	local sS = Sim.newServer({ JobId = "STOCK" })
	local ps = load(sS, stock(sS).New("PlayerData", TEMPLATE), "Player_1")
	T.expect(ps, "stock loads the un-poisoned profile")
	T.eq(ps.Data.Coins, 1)
	T.deepEq(ps.Data.Cards, rich().Cards)
	T.eq(ps.SessionLoadCount, 3)
end)

T.test("Compact writes keep MetaData.Anchor keys from other versions and stock MetaData fields", function()
	local s = Sim.newServer()
	local store = anchor(s).New("PlayerData", TEMPLATE, { Format = "Compact" })
	Sim.poke("PlayerData", "Player_1", {
		Data = { Coins = 1 },
		MetaData = {
			ProfileCreateTime = 5,
			SessionLoadCount = 7,
			MetaTags = { Legacy = true },
			LastUpdate = 0,
			Anchor = { Future = { x = 1 } },
		},
		GlobalUpdates = { 0, {} },
		RobloxMetaData = {},
		UserIds = {},
	})
	local p = load(s, store, "Player_1")
	T.eq(p.SessionLoadCount, 8)
	T.deepEq(p.anchor_meta, { Future = { x = 1 } })
	p:EndSession()
	Sim.advance(2)
	local raw = Sim.peek("PlayerData", "Player_1")
	T.eq(raw.MetaData.SessionLoadCount, "Anchor")
	T.deepEq(raw.MetaData.Anchor, { LoadCount = 8, Future = { x = 1 } })
	T.deepEq(raw.MetaData.MetaTags, { Legacy = true })
	T.eq(raw.MetaData.ProfileCreateTime, 5)
end)

T.test("corrupt Compact blob: no session, OnError, stored value untouched", function()
	local raw = compactProfile()
	local blob = raw.Data.AnchorBlob
	local bad = buffer.create(buffer.len(blob))
	buffer.copy(bad, 0, blob)
	buffer.writeu8(bad, 3, 99) -- unknown codec version
	raw.Data.AnchorBlob = bad
	Sim.poke("PlayerData", "Player_1", raw)
	local s = Sim.newServer({ JobId = "X" })
	local A = anchor(s)
	local errors = {}
	A.OnError:Connect(function(m)
		table.insert(errors, m)
	end)
	local store = A.New("PlayerData", TEMPLATE, { Format = "Compact" })
	T.eq(load(s, store, "Player_1"), nil)
	T.expect(#errors >= 1 and string.find(errors[1], "decoded", 1, true), errors[1])
	local after = Sim.peek("PlayerData", "Player_1")
	T.eq(buffer.tostring(after.Data.AnchorBlob), buffer.tostring(bad))
	T.eq(after.MetaData.ActiveSession, nil, "lock released")
end)

----------------------------------------------------------------------------
-- Migration
----------------------------------------------------------------------------

T.test("migration: profiles written by stock ProfileStore load in Anchor unchanged (both formats)", function()
	local sS = Sim.newServer({ JobId = "STOCK" })
	local stockStore = stock(sS).New("PlayerData", TEMPLATE)
	for i = 1, 2 do
		local p = load(sS, stockStore, "Player_" .. i)
		for k, v in rich() do
			p.Data[k] = v
		end
		p:AddUserId(i)
		p.RobloxMetaData.Note = "stock"
		p:EndSession()
	end
	T.eq(sS:await(stockStore.MessageAsync, stockStore, "Player_1", { Gift = 1 }), true)
	Sim.advance(2)
	local stockRaw = Sim.peek("PlayerData", "Player_1")
	sS:shutdown()

	for i, format in { "Compat", "Compact" } do
		local sA = Sim.newServer({ JobId = "A" .. i })
		local st = anchor(sA).New("PlayerData", TEMPLATE, { Format = format })
		local p = load(sA, st, "Player_" .. i)
		T.deepEq(p.Data, rich(), format)
		T.deepEq(p.LastSavedData, rich())
		T.deepEq(p.UserIds, { i })
		T.eq(p.RobloxMetaData.Note, "stock")
		T.eq(p.FirstSessionTime, stockRaw.MetaData.ProfileCreateTime)
		T.eq(p.SessionLoadCount, 2)
		if i == 1 then
			local gift
			p:MessageHandler(function(m, processed)
				gift = m.Gift
				processed()
			end)
			T.eq(gift, 1)
		end
		p:EndSession()
		Sim.advance(2)
		local s2 = Sim.newServer({ JobId = "B" .. i })
		local again = load(s2, anchor(s2).New("PlayerData", TEMPLATE), "Player_" .. i)
		T.deepEq(again.Data, rich(), format .. " round trip")
	end
end)

T.test("migration: ProfileService-era blob (4-field messages, 2-field session) loads and saves", function()
	local s = Sim.newServer({ JobId = "A" })
	local A = anchor(s)
	Sim.poke("PlayerData", "Player_9", {
		Data = { Coins = 70, Items = { "Old" } },
		MetaData = {
			ProfileCreateTime = 1500000000,
			SessionLoadCount = 41,
			ActiveSession = { 555, "dead-ps-server" },
			ForceLoadSession = nil,
			MetaTags = { Level = 3 },
			LastUpdate = Sim.unixTime() - 2000,
		},
		GlobalUpdates = { 3, { { 2, 1, false, { Gift = 5 } }, { 3, 2, false, { Gift = 7 } } } },
	})
	local store = A.New("PlayerData", TEMPLATE)
	local p = load(s, store, "Player_9")
	T.expect(p, "dead ProfileService session taken over")
	T.eq(p.SessionLoadCount, 42)
	T.deepEq(p.Data, { Coins = 70, Items = { "Old" } })
	local gifts = 0
	p:MessageHandler(function(m, processed)
		gifts += m.Gift
		processed()
	end)
	T.eq(gifts, 12)
	p:Reconcile()
	p:EndSession()
	Sim.advance(2)
	local raw = Sim.peek("PlayerData", "Player_9")
	T.eq(#raw.GlobalUpdates[2], 0)
	T.eq(raw.GlobalUpdates[1], 3)
	T.deepEq(raw.MetaData.MetaTags, { Level = 3 })
	T.eq(raw.Data.Settings.Music, true)
	T.eq(raw.MetaData.SessionLoadCount, 42)
	-- A message to the ProfileStore-format queue continues the index:
	T.eq(s:await(store.MessageAsync, store, "Player_9", { Gift = 1 }), true)
	T.eq(Sim.peek("PlayerData", "Player_9").GlobalUpdates[2][1][1], 4)
end)
