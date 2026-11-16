-- Stock ProfileStore 1.0.3 on the mock: single-server session lifecycle.
local T = require("@mock/testkit")
local Sim = require("@mock/sim")

local PS_PATH = "reference/ProfileStore-1.0.3.luau"
local TEMPLATE = { Coins = 0, Items = {}, Settings = { Music = true } }

local function boot(server)
	return server:require(PS_PATH, { name = "ProfileStore" })
end

T.test("load creates profile from template, Save writes it, EndSession releases", function()
	local s = Sim.newServer({ PlaceId = 10, JobId = "A" })
	local PS = boot(s)
	T.eq(PS.DataStoreState, "Access")
	local store = PS.New("PlayerData", TEMPLATE)

	local profile = s:await(store.StartSessionAsync, store, "Player_1")
	T.expect(profile, "profile loaded")
	T.deepEq(profile.Data, TEMPLATE)
	T.expect(profile:IsActive())
	T.eq(profile.SessionLoadCount, 1)

	local raw = Sim.peek("PlayerData", "Player_1")
	T.eq(raw.MetaData.ActiveSession[1], 10)
	T.eq(raw.MetaData.ActiveSession[2], "A")
	T.eq(type(raw.MetaData.ActiveSession[3]), "string")

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

	-- Load again on the same server: data intact, load count increments.
	local again = s:await(store.StartSessionAsync, store, "Player_1")
	T.eq(again.Data.Coins, 43)
	T.eq(again.SessionLoadCount, 2)
	T.expect(s.stats.bytesWritten > 0)
	T.eq(s.stats.calls.UpdateAsync, 4) -- load, save, release, load
end)

T.test("autosave fires about 300 virtual seconds after load", function()
	local s = Sim.newServer()
	local store = boot(s).New("PlayerData", TEMPLATE)
	local profile = s:await(store.StartSessionAsync, store, "Player_1")
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

	-- 30 virtual minutes => one save every 300 s
	local real = os.clock()
	Sim.advance(1800)
	real = os.clock() - real
	T.eq(#saves, 7)
	T.expect(real < 5, `30 virtual minutes took {real} s of real time`)
end)

T.test("BindToClose releases every active profile on shutdown", function()
	local s = Sim.newServer({ JobId = "A" })
	local store = boot(s).New("PlayerData", TEMPLATE)
	local p1 = s:await(store.StartSessionAsync, store, "Player_1")
	local p2 = s:await(store.StartSessionAsync, store, "Player_2")
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
	local p = s:await(store.StartSessionAsync, store, "Player_1")
	p.Data.Coins = 99
	s:crash()
	Sim.advance(1000) -- autosave would have run if the server were alive
	local raw = Sim.peek("PlayerData", "Player_1")
	T.expect(raw.MetaData.ActiveSession ~= nil, "still locked by the dead server")
	T.eq(raw.Data.Coins, 0)
	T.eq(s.stats.calls.UpdateAsync, 1)
end)

T.test("PlayerAdded/PlayerRemoving flow with a game script", function()
	local s = Sim.newServer()
	local PS = boot(s)
	local store = PS.New("PlayerData", TEMPLATE)
	local Players = s.game:GetService("Players")
	local profiles = {}
	Players.PlayerAdded:Connect(function(player)
		local profile = store:StartSessionAsync(`Player_{player.UserId}`, {
			Cancel = function()
				return player.Parent ~= Players
			end,
		})
		if profile == nil then
			player:Kick("load failed")
			return
		end
		profile:AddUserId(player.UserId)
		profile:Reconcile()
		profile.OnSessionEnd:Connect(function()
			profiles[player] = nil
			player:Kick("session ended")
		end)
		if player.Parent == Players then
			profiles[player] = profile
		else
			profile:EndSession()
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		local profile = profiles[player]
		if profile then
			profile:EndSession()
		end
	end)

	local player = s:addPlayer(123)
	T.expect(Sim.runUntil(function()
		return profiles[player] ~= nil
	end, 10))
	profiles[player].Data.Coins = 5
	s:removePlayer(player)
	Sim.advance(2)
	local raw, keyInfo = Sim.peek("PlayerData", "Player_123")
	T.eq(raw.Data.Coins, 5)
	T.eq(raw.MetaData.ActiveSession, nil)
	T.deepEq(keyInfo:GetUserIds(), { 123 })
	T.deepEq(raw.UserIds, { 123 })
end)
