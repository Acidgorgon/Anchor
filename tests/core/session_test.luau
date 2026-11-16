-- Anchor core: the single-server behaviours stock ProfileStore has (same checks as
-- tests/stock/session_test.luau), plus Anchor's own single-server guarantees.
local T = require("@mock/testkit")
local Sim = require("@mock/sim")

local TEMPLATE = { Coins = 0, Items = {}, Settings = { Music = true } }

local function boot(server)
	return server:require("src", { name = "Anchor" })
end

local function load(s, store, key, params)
	return s:await(store.StartSessionAsync, store, key, params)
end

T.test("load creates profile from template, Save writes it, EndSession releases", function()
	local s = Sim.newServer({ PlaceId = 10, JobId = "A" })
	local A = boot(s)
	T.eq(A.DataStoreState, "Access")
	local store = A.New("PlayerData", TEMPLATE)

	local profile = load(s, store, "Player_1")
	T.expect(profile, "profile loaded")
	T.deepEq(profile.Data, TEMPLATE)
	T.expect(profile:IsActive())
	T.eq(profile.SessionLoadCount, 1)

	local raw = Sim.peek("PlayerData", "Player_1")
	T.eq(raw.MetaData.ActiveSession[1], 10)
	T.eq(raw.MetaData.ActiveSession[2], "A")
	T.eq(type(raw.MetaData.ActiveSession[3]), "string")
	T.eq(raw.MetaData.Anchor, nil, "Compat writes no Anchor bookkeeping")

	profile.Data.Coins = 42
	table.insert(profile.Data.Items, "Sword")
	local saved = 0
	profile.OnAfterSave:Connect(function()
		saved += 1
	end)
	profile:Save()
	T.expect(Sim.runUntil(function()
		return saved == 1
	end, 5), "OnAfterSave after Save")
	T.eq(Sim.peek("PlayerData", "Player_1").Data.Coins, 42)
	T.eq(profile.LastSavedData.Coins, 42)

	local lastReason
	profile.OnLastSave:Connect(function(reason)
		lastReason = reason
	end)
	profile.Data.Coins = 43
	profile:EndSession()
	T.expect(not profile:IsActive(), "inactive right after EndSession")
	Sim.advance(2)
	T.eq(lastReason, "Manual")
	raw = Sim.peek("PlayerData", "Player_1")
	T.eq(raw.MetaData.ActiveSession, nil)
	T.eq(raw.Data.Coins, 43)
	T.deepEq(raw.Data.Items, { "Sword" })

	local again = load(s, store, "Player_1")
	T.eq(again.Data.Coins, 43)
	T.eq(again.SessionLoadCount, 2)
	T.expect(s.stats.bytesWritten > 0)
	T.eq(s.stats.calls.UpdateAsync, 4) -- load, save, release, load
end)

T.test("autosave fires about 300 virtual seconds after load", function()
	local s = Sim.newServer()
	local store = boot(s).New("PlayerData", TEMPLATE)
	local profile = load(s, store, "Player_1")
	local loadedAt = Sim.now()
	local saves = {}
	profile.OnAfterSave:Connect(function()
		table.insert(saves, Sim.now() - loadedAt)
	end)
	profile.Data.Coins = 7

	Sim.advance(295)
	T.eq(#saves, 0, "no save before 300 s")
	T.eq(Sim.peek("PlayerData", "Player_1").Data.Coins, 0)
	Sim.advance(10)
	T.eq(#saves, 1, "one autosave")
	T.near(saves[1], 300, 1.5)
	T.eq(Sim.peek("PlayerData", "Player_1").Data.Coins, 7)

	-- Default constants: a clean autosave can't be skipped (the lock would get too old),
	-- so stock's one-write-per-300 s cadence is kept.
	Sim.advance(1800)
	T.eq(#saves, 7)
end)

T.test("autosave ring: many profiles, releases in any order, every profile keeps saving", function()
	local s = Sim.newServer()
	local A = boot(s)
	A.SetConstant("AUTO_SAVE_PERIOD", 60)
	local store = A.New("PlayerData", TEMPLATE)
	local profiles = {}
	for i = 1, 12 do
		profiles[i] = load(s, store, "Player_" .. i)
	end
	T.eq(#A.Test().AutoSaveList, 12)
	for _, i in { 3, 1, 12, 7 } do
		profiles[i]:EndSession()
	end
	Sim.advance(2)
	T.eq(#A.Test().AutoSaveList, 8)
	local counts = {}
	for i, p in profiles do
		p.Data.Coins = i
		p.OnSave:Connect(function() -- fires for skipped clean autosaves too
			counts[i] = (counts[i] or 0) + 1
		end)
	end
	Sim.advance(240)
	for i, p in profiles do
		if p:IsActive() then
			T.expect((counts[i] or 0) >= 3, `profile {i} autosaved {counts[i] or 0} times in 240 s`)
			T.eq(Sim.peek("PlayerData", "Player_" .. i).Data.Coins, i)
		else
			T.eq(counts[i], nil, `released profile {i} not autosaved`)
		end
	end
	-- Save() moves the profile behind the cursor; the list stays consistent.
	profiles[2]:Save()
	profiles[2]:Save()
	T.eq(#A.Test().AutoSaveList, 8)
	for _, p in profiles do
		p:EndSession()
	end
	Sim.advance(2)
	T.eq(#A.Test().AutoSaveList, 0)
end)

T.test("BindToClose releases every active profile on shutdown", function()
	local s = Sim.newServer({ JobId = "A" })
	local store = boot(s).New("PlayerData", TEMPLATE)
	local p1 = load(s, store, "Player_1")
	local p2 = load(s, store, "Player_2")
	p1.Data.Coins = 1
	p2.Data.Coins = 2
	local reasons = {}
	p1.OnLastSave:Connect(function(r)
		reasons[1] = r
	end)
	local result = s:shutdown()
	T.expect(not result.timedOut, "BindToClose finished in time")
	T.expect(result.elapsed < 5, `shutdown took {result.elapsed} s`)
	T.expect(not s.alive)
	T.eq(reasons[1], "Shutdown")
	for i, key in { "Player_1", "Player_2" } do
		local raw = Sim.peek("PlayerData", key)
		T.eq(raw.MetaData.ActiveSession, nil, key .. " released")
		T.eq(raw.Data.Coins, i)
	end
end)

T.test("crash skips BindToClose: lock stays, unsaved changes are lost", function()
	local s = Sim.newServer({ JobId = "A" })
	local store = boot(s).New("PlayerData", TEMPLATE)
	local p = load(s, store, "Player_1")
	p.Data.Coins = 99
	s:crash()
	Sim.advance(1000)
	local raw = Sim.peek("PlayerData", "Player_1")
	T.expect(raw.MetaData.ActiveSession ~= nil, "still locked by the dead server")
	T.eq(raw.Data.Coins, 0)
	T.eq(s.stats.calls.UpdateAsync, 1)
end)

T.test("Profile.Data identity never changes across saves, messages and reconcile", function()
	local s = Sim.newServer()
	local A = boot(s)
	A.SetConstant("AUTO_SAVE_PERIOD", 30)
	for _, format in { "Compat", "Compact" } do
		local store = A.New("PlayerData_" .. format, TEMPLATE, { Format = format })
		local p = load(s, store, "Player_1")
		local data = p.Data
		p:Reconcile()
		p.Data.Coins = 5
		p:Save()
		Sim.advance(2)
		T.eq(s:await(p.SaveAsync, p), true)
		Sim.advance(200) -- autosaves
		T.expect(rawequal(p.Data, data), format .. ": same Data table")
		T.eq(p.Data.Coins, 5)
		p:EndSession()
		Sim.advance(2)
		T.expect(rawequal(p.Data, data), format .. ": same Data table after release")
	end
end)

T.test("LastSavedData is decoded lazily and equals what was saved", function()
	local s = Sim.newServer()
	local A = boot(s)
	for _, format in { "Compat", "Compact" } do
		local store = A.New("PlayerData_" .. format, TEMPLATE, { Format = format })
		local p = load(s, store, "Player_1")
		T.eq(rawget(p, "LastSavedData"), nil, format .. ": not materialised at load")
		T.deepEq(p.LastSavedData, TEMPLATE)
		T.expect(rawget(p, "LastSavedData") ~= nil, "cached after first read")
		T.expect(not rawequal(p.LastSavedData, p.Data), "a snapshot, not the live table")

		p.Data.Coins = 11
		table.insert(p.Data.Items, { Id = "Sword", Level = 3 })
		T.eq(s:await(p.SaveAsync, p), true)
		T.eq(rawget(p, "LastSavedData"), nil, format .. ": dropped after save until read")
		local expected = { Coins = 11, Items = { { Id = "Sword", Level = 3 } }, Settings = { Music = true } }
		T.deepEq(p.LastSavedData, expected)
		p.Data.Coins = 12 -- unsaved change is not in LastSavedData
		T.eq(p.LastSavedData.Coins, 11)

		-- What is in the DataStore decodes to the same thing:
		local got = s:await(store.GetAsync, store, "Player_1")
		T.deepEq(got.Data, expected)

		-- OnAfterSave still receives the snapshot:
		local received
		p.OnAfterSave:Connect(function(lsd)
			received = lsd
		end)
		p:Save()
		Sim.advance(2)
		T.eq(received and received.Coins, 12)
		p:EndSession()
		Sim.advance(2)
	end
end)

T.test("SaveAsync yields and reports whether the write landed", function()
	local s = Sim.newServer({ JobId = "A" })
	local store = boot(s).New("PlayerData", TEMPLATE)
	local p = load(s, store, "Player_1")
	p.Data.Coins = 3
	local t0 = Sim.now()
	T.eq(s:await(p.SaveAsync, p), true)
	T.expect(Sim.now() > t0, "yielded")
	T.eq(Sim.peek("PlayerData", "Player_1").Data.Coins, 3)

	-- DataStore error -> false, profile stays active
	local rule = Sim.injectError({ method = "UpdateAsync", key = "Player_1", count = 1 })
	p.Data.Coins = 4
	T.eq(s:await(p.SaveAsync, p), false)
	T.eq(rule.hits, 1)
	T.expect(p:IsActive())
	T.eq(s:await(p.SaveAsync, p), true)
	T.eq(Sim.peek("PlayerData", "Player_1").Data.Coins, 4)

	-- Session lost to another server -> false, nothing written over it
	local raw = Sim.peek("PlayerData", "Player_1")
	raw.MetaData.ActiveSession = { 99, "Other", "guid" }
	raw.MetaData.SessionLoadCount += 1
	Sim.poke("PlayerData", "Player_1", raw)
	p.Data.Coins = 5
	T.eq(s:await(p.SaveAsync, p), false)
	T.expect(not p:IsActive(), "session ended")
	T.eq(Sim.peek("PlayerData", "Player_1").Data.Coins, 4)

	p:EndSession()
	T.eq(s:await(p.SaveAsync, p), false, "inactive profile")
end)

T.test("invalid data: OnError with path, no DataStore write, profile stays active", function()
	local s = Sim.newServer()
	local A = boot(s)
	A.SetConstant("AUTO_SAVE_PERIOD", 20)
	local store = A.New("PlayerData", TEMPLATE)
	local p = load(s, store, "Player_1")
	local errors = {}
	A.OnError:Connect(function(message, storeName, key)
		table.insert(errors, { message, storeName, key })
	end)
	local callsBefore = s.stats.calls.UpdateAsync
	p.Data.Items.Bad = function() end
	T.eq(s:await(p.SaveAsync, p), false)
	T.eq(s.stats.calls.UpdateAsync, callsBefore, "no DataStore call")
	T.eq(#errors, 1)
	T.expect(string.find(errors[1][1], "Data.Items.Bad", 1, true), errors[1][1])
	T.eq(errors[1][2], "PlayerData")
	T.eq(errors[1][3], "Player_1")
	T.expect(p:IsActive())

	Sim.advance(60) -- autosaves keep being blocked, no calls
	T.eq(s.stats.calls.UpdateAsync, callsBefore)
	T.expect(not A.IsCriticalState, "validation failures don't count as DataStore errors")

	-- Fixing the data lets the next save through.
	p.Data.Items.Bad = nil
	p.Data.Coins = 9
	Sim.advance(25)
	T.eq(Sim.peek("PlayerData", "Player_1").Data.Coins, 9)

	-- Release with bad data keeps retrying (lock kept, like stock), then succeeds once fixed.
	p.Data.Items.Bad = newproxy()
	p:EndSession()
	Sim.advance(30)
	T.expect(Sim.peek("PlayerData", "Player_1").MetaData.ActiveSession ~= nil, "lock kept while data is bad")
	p.Data.Items.Bad = nil
	Sim.advance(30)
	T.eq(Sim.peek("PlayerData", "Player_1").MetaData.ActiveSession, nil, "released after fix")
end)

T.test("data Codec rejects but no hard DataStore rule matches: the DataStore decides, like stock", function()
	-- Codec rejects mixed tables; Anchor's own hard-reject list doesn't include them
	-- (Roblox's handling is the DataStore's call), so the write is attempted in the plain
	-- stock format exactly as stock would. The mock DataStore rejects it; nothing is lost.
	local s = Sim.newServer()
	local A = boot(s)
	for _, format in { "Compat", "Compact" } do
		local name = "PlayerData_" .. format
		local store = A.New(name, TEMPLATE, { Format = format })
		local p = load(s, store, "Player_1")
		local errors = 0
		local conn = A.OnError:Connect(function()
			errors += 1
		end)
		p.Data.Coins = 77
		p.Data.Items = { "a", "b", Extra = true }
		local before = s.stats.calls.UpdateAsync
		T.eq(s:await(p.SaveAsync, p), false)
		T.eq(s.stats.calls.UpdateAsync, before + 1, format .. ": write attempted (not blocked)")
		T.eq(errors, 1, "one OnError, from the DataStore, as in stock")
		local raw = Sim.peek(name, "Player_1")
		T.eq(raw.Data.Coins, 0, "stored value untouched")
		T.expect(p:IsActive())
		p.Data.Items = { "a", "b" }
		T.eq(s:await(p.SaveAsync, p), true)
		raw = Sim.peek(name, "Player_1")
		if format == "Compact" then
			T.eq(raw.MetaData.SessionLoadCount, "Anchor")
		else
			T.eq(raw.Data.Coins, 77)
		end
		conn:Disconnect()
		p:EndSession()
		Sim.advance(2)
	end
end)

T.test("Mock stores are isolated from the real DataStore", function()
	local s = Sim.newServer()
	local store = boot(s).New("PlayerData", TEMPLATE)
	local p = s:await(store.Mock.StartSessionAsync, store.Mock, "Player_1")
	T.expect(p)
	p.Data.Coins = 50
	p:Save()
	Sim.advance(2)
	T.eq(Sim.peek("PlayerData", "Player_1"), nil, "nothing in the real DataStore")
	T.eq(s.stats.calls.UpdateAsync, nil)
	-- a real session for the same key is independent
	local real = load(s, store, "Player_1")
	T.eq(real.Data.Coins, 0)
	p:EndSession()
	Sim.advance(1)
	local again = s:await(store.Mock.StartSessionAsync, store.Mock, "Player_1")
	T.eq(again.Data.Coins, 50)
	T.expect(s:await(store.Mock.MessageAsync, store.Mock, "Player_1", { Gift = 1 }))
	local view = s:await(store.Mock.GetAsync, store.Mock, "Player_1")
	T.eq(view.Data.Coins, 50)
	T.expect(s:await(store.Mock.RemoveAsync, store.Mock, "Player_1"))
end)

T.test("GetAsync view profiles, SetAsync and RemoveAsync", function()
	local s = Sim.newServer()
	local store = boot(s).New("PlayerData", TEMPLATE)
	T.eq(s:await(store.GetAsync, store, "Nobody"), nil)
	local p = load(s, store, "Player_1")
	p.Data.Coins = 8
	p:EndSession()
	Sim.advance(2)
	local view = s:await(store.GetAsync, store, "Player_1")
	T.eq(view.Data.Coins, 8)
	T.throws(function()
		view:Save()
	end, "view mode")
	view.Data.Coins = 100
	s:await(view.SetAsync, view)
	T.eq(Sim.peek("PlayerData", "Player_1").Data.Coins, 100)
	T.eq(s:await(store.RemoveAsync, store, "Player_1"), true)
	T.eq(Sim.peek("PlayerData", "Player_1"), nil)
end)

T.test("VersionQuery walks saved versions", function()
	local s = Sim.newServer()
	local store = boot(s).New("PlayerData", TEMPLATE)
	local p = load(s, store, "Player_1")
	for i = 1, 3 do
		p.Data.Coins = i
		T.eq(s:await(p.SaveAsync, p), true)
	end
	local q = store:VersionQuery("Player_1")
	local seen = {}
	while true do
		local v = s:await(q.NextAsync, q)
		if v == nil then
			break
		end
		table.insert(seen, v.Data.Coins)
	end
	T.deepEq(seen, { 0, 1, 2, 3 })
end)

T.test("DataStore errors at load are retried; critical state after repeated errors", function()
	local s = Sim.newServer()
	local A = boot(s)
	local store = A.New("PlayerData", TEMPLATE)
	local toggles = {}
	A.OnCriticalToggle:Connect(function(v)
		table.insert(toggles, v)
	end)
	Sim.injectError({ method = "UpdateAsync", count = 5 })
	local p = load(s, store, "Player_1")
	T.expect(p, "loaded after retries")
	Sim.advance(1)
	T.eq(toggles[1], true)
	Sim.advance(300)
	T.eq(toggles[2], false)
end)

T.test("Reconcile, AddUserId, RemoveUserId, RobloxMetaData are saved", function()
	local s = Sim.newServer()
	local store = boot(s).New("PlayerData", { Coins = 0, New = { X = 1 } })
	Sim.poke("PlayerData", "Player_1", {
		Data = { Coins = 5 },
		MetaData = { ProfileCreateTime = 1, SessionLoadCount = 3, MetaTags = {} },
		GlobalUpdates = { 0, {} },
		RobloxMetaData = {},
		UserIds = {},
	})
	local p = load(s, store, "Player_1")
	p:Reconcile()
	T.deepEq(p.Data, { Coins = 5, New = { X = 1 } })
	p:AddUserId(1)
	p:AddUserId(2)
	p:RemoveUserId(1)
	p.RobloxMetaData.Tag = "x"
	T.eq(s:await(p.SaveAsync, p), true)
	local raw, info = Sim.peek("PlayerData", "Player_1")
	T.deepEq(raw.UserIds, { 2 })
	T.deepEq(info:GetUserIds(), { 2 })
	T.eq(raw.RobloxMetaData.Tag, "x")
	T.eq(raw.MetaData.SessionLoadCount, 4)
end)

T.test("same-server quick reload waits for a retrying release (stock loads stale data here)", function()
	local function scenario(path)
		Sim.reset()
		local s = Sim.newServer({ JobId = "A" })
		local lib = s:require(path, { name = "Lib" })
		local store = lib.New("PlayerData", TEMPLATE)
		local p = load(s, store, "Player_1")
		p.Data.Coins = 1
		p:Save()
		Sim.advance(2)
		T.eq(Sim.peek("PlayerData", "Player_1").Data.Coins, 1)
		p.Data.Coins = 2 -- changed after the last save
		Sim.injectError({ method = "UpdateAsync", key = "Player_1", count = 1 })
		p:EndSession() -- release fails once, retries after a 1 s backoff
		local again = load(s, store, "Player_1") -- player rejoins the same server at once
		Sim.advance(10)
		return again.Data.Coins, Sim.peek("PlayerData", "Player_1").Data.Coins
	end
	local anchorLoaded, anchorStored = scenario("src")
	T.eq(anchorLoaded, 2, "Anchor: new session sees the released data")
	T.eq(anchorStored, 2)
	local stockLoaded = scenario("reference/ProfileStore-1.0.3.luau")
	T.eq(stockLoaded, 1, "reference: stock 1.0.3 reloads the stale value (the bug Anchor fixes)")
end)
