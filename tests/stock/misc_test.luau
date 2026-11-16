-- Stock ProfileStore 1.0.3 on the mock: errors, Mock store, view mode, versions.
local T = require("@mock/testkit")
local Sim = require("@mock/sim")

local PS_PATH = "reference/ProfileStore-1.0.3.luau"
local TEMPLATE = { Coins = 0 }

local function boot(server)
	local PS = server:require(PS_PATH, { name = "ProfileStore" })
	return PS, PS.New("PlayerData", TEMPLATE)
end

local function saveAndWait(server, profile)
	server:await(function()
		profile:Save()
		profile.OnAfterSave:Wait()
	end)
end

T.test("a JSON-invalid value makes the save fail and fires OnError; fixing it saves again", function()
	local s = Sim.newServer()
	local PS, store = boot(s)
	local p = s:await(store.StartSessionAsync, store, "Player_1")
	local errors = {}
	PS.OnError:Connect(function(message, storeName, key)
		table.insert(errors, { message, storeName, key })
	end)

	p.Data.Coins = 5
	p.Data.Callback = function() end
	p:Save()
	Sim.advance(2)
	T.eq(#errors, 1)
	T.expect(string.find(errors[1][1], "Cannot store function", 1, true), errors[1][1])
	T.expect(string.find(errors[1][1], "Data.Callback", 1, true), "error names the path")
	T.eq(errors[1][2], "PlayerData")
	T.eq(errors[1][3], "Player_1")
	T.expect(p:IsActive(), "profile stays active")
	T.eq(Sim.peek("PlayerData", "Player_1").Data.Coins, 0, "nothing written")

	for _, bad in { 0 / 0, math.huge, { 1, 2, nil, 4 } :: any, { 1, x = 2 } :: any, { [1.5] = 1 } :: any } do
		p.Data.Bad = bad
		p.Data.Callback = nil
		p:Save()
		Sim.advance(2)
	end
	T.eq(#errors, 6, "NaN, inf, sparse, mixed and float keys all rejected")

	p.Data.Bad = nil
	saveAndWait(s, p)
	T.eq(Sim.peek("PlayerData", "Player_1").Data.Coins, 5)
end)

T.test("ProfileStore.Mock never touches the DataStore", function()
	local s = Sim.newServer()
	local _, store = boot(s)
	local p = s:await(store.Mock.StartSessionAsync, store.Mock, "Player_1")
	T.expect(p)
	p.Data.Coins = 11
	p:EndSession()
	Sim.advance(1)
	local again = s:await(store.Mock.StartSessionAsync, store.Mock, "Player_1")
	T.eq(again.Data.Coins, 11, "mock store keeps data in memory")
	T.eq(next(s.stats.calls), nil, "no DataStore/MessagingService calls")
	T.eq(Sim.peek("PlayerData", "Player_1"), nil)
	local live = s:await(store.StartSessionAsync, store, "Player_1")
	T.eq(live.Data.Coins, 0, "live store is separate")
end)

T.test("GetAsync view profile, SetAsync overwrite, RemoveAsync", function()
	local s = Sim.newServer()
	local _, store = boot(s)
	T.eq(s:await(store.GetAsync, store, "Nobody"), nil)
	local p = s:await(store.StartSessionAsync, store, "Player_1")
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
	T.eq(s:await(store.GetAsync, store, "Player_1"), nil)
end)

T.test("VersionQuery walks saved versions", function()
	Sim.configure({ listPageSize = 2 })
	local s = Sim.newServer()
	local _, store = boot(s)
	local p = s:await(store.StartSessionAsync, store, "Player_1")
	for i = 1, 4 do
		p.Data.Coins = i
		saveAndWait(s, p)
		Sim.advance(1)
	end
	T.eq(#Sim.versions("PlayerData", "Player_1"), 5) -- load + 4 saves
	local query = store:VersionQuery("Player_1", Sim.Roblox.Enum.SortDirection.Descending)
	local seen = {}
	s:await(function()
		while true do
			local v = query:NextAsync()
			if v == nil then
				break
			end
			table.insert(seen, v.Data.Coins)
		end
	end)
	T.deepEq(seen, { 4, 3, 2, 1, 0 })
	T.expect((s.stats.calls.AdvanceToNextPageAsync or 0) >= 2, "paged")
	T.eq(s.stats.calls.GetVersionAsync, 5)
end)

T.test("DataStore errors during load are retried; OnError fires each time", function()
	local s = Sim.newServer()
	local PS, store = boot(s)
	local errors = 0
	PS.OnError:Connect(function()
		errors += 1
	end)
	local rule = Sim.injectError({ method = "UpdateAsync", key = "Player_1", count = 3 })
	local p = s:await(store.StartSessionAsync, store, "Player_1")
	T.expect(p, "loaded after retries")
	T.eq(rule.hits, 3)
	T.eq(errors, 3)
	T.eq(s.stats.calls.UpdateAsync, 4)
end)

T.test("load gives up after START_SESSION_TIMEOUT when the DataStore keeps failing", function()
	local s = Sim.newServer()
	local _, store = boot(s)
	Sim.injectError({ method = "UpdateAsync" })
	local t0 = Sim.now()
	local p = s:await(store.StartSessionAsync, store, "Player_1")
	T.eq(p, nil)
	T.expect(Sim.now() - t0 >= 120, "waited for the timeout")
end)

T.test("critical state toggles after repeated errors", function()
	local s = Sim.newServer()
	local PS, store = boot(s)
	local toggles = {}
	PS.OnCriticalToggle:Connect(function(isCritical)
		table.insert(toggles, isCritical)
	end)
	local rule = Sim.injectError({ method = "UpdateAsync", count = 5 })
	s:await(store.StartSessionAsync, store, "Player_1")
	Sim.advance(1)
	T.deepEq(toggles, { true })
	T.eq(rule.hits, 5)
	Sim.advance(300)
	T.deepEq(toggles, { true, false })
end)

T.test("an error after the commit (write landed, caller saw failure) does not lose data", function()
	local s = Sim.newServer()
	local _, store = boot(s)
	local p = s:await(store.StartSessionAsync, store, "Player_1")
	p.Data.Coins = 77
	local rule = Sim.injectError({ method = "UpdateAsync", count = 1, phase = "after" })
	p:EndSession()
	Sim.advance(10)
	T.eq(rule.hits, 1)
	local raw = Sim.peek("PlayerData", "Player_1")
	T.eq(raw.Data.Coins, 77)
	T.eq(raw.MetaData.ActiveSession, nil)
end)

T.test("Studio access probe (IsStudio = true) reports Access", function()
	local s = Sim.newServer({ IsStudio = true })
	local PS, store = boot(s)
	T.eq(PS.DataStoreState, "NotReady")
	local p = s:await(store.StartSessionAsync, store, "Player_1")
	T.eq(PS.DataStoreState, "Access")
	T.expect(p)
	T.expect(Sim.peek("____PS", "____PS") ~= nil, "probe key written")
	T.eq(#s:logsMatching("API services available", "print"), 1)
end)

T.test("UpdateAsync conflicts (transform called twice) are harmless", function()
	Sim.configure({ conflictRate = 0.5 })
	local a = Sim.newServer({ JobId = "A" })
	local b = Sim.newServer({ JobId = "B" })
	local _, storeA = boot(a)
	local _, storeB = boot(b)
	for hop = 1, 6 do
		local server, store = a, storeA
		if hop % 2 == 0 then
			server, store = b, storeB
		end
		local p = server:await(store.StartSessionAsync, store, "Player_1")
		T.eq(p.Data.Coins, hop - 1)
		p.Data.Coins += 1
		p:EndSession()
		Sim.advance(1)
	end
	T.expect(Sim.stats().conflicts > 0, "conflicts happened")
	T.eq(Sim.peek("PlayerData", "Player_1").Data.Coins, 6)
end)

T.test("throttling: budgets and the 6 s same-key write cooldown", function()
	Sim.configure({ throttle = true })
	local s = Sim.newServer()
	local _, store = boot(s)
	local p = s:await(store.StartSessionAsync, store, "Player_1")
	local t0 = Sim.now()
	saveAndWait(s, p)
	T.expect(Sim.now() - t0 >= 5, "second write to the key waited for the cooldown")
	T.expect(s.stats.throttled >= 1)
	local DataStoreService = s.game:GetService("DataStoreService")
	local budget = DataStoreService:GetRequestBudgetForRequestType(Sim.Roblox.Enum.DataStoreRequestType.UpdateAsync)
	T.expect(budget > 0 and budget < 100, `budget {budget}`)
end)
