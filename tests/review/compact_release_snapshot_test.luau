-- [review] Compact release saves encode Data the moment EndSession is called (inside the
-- task.spawn, before the first yield). Stock and Compat write the LIVE Data table in the
-- transform, i.e. after the network yield, so writes made by other PlayerRemoving
-- handlers in the same frame (connection order is not something games control) are
-- saved. In Compact they are silently dropped. Compat run is the control.
local T = require("@mock/testkit")
local Sim = require("@mock/sim")

local TEMPLATE = { Coins = 0, PlayTime = 0 }

for _, format in { "Compat", "Compact" } do
	T.test(`{format}: a PlayerRemoving handler that runs after Bind's still gets its write saved`, function()
		local s = Sim.newServer({ JobId = "S1" })
		local Data = s:require("src", { name = "Anchor" }).new("Main", TEMPLATE, { Format = format })
		Data:Bind()
		local cache = {}
		Data.Loaded:Connect(function(player, profile)
			cache[player] = profile
		end)
		-- the game's own leave handler (connected after Bind, as most games would)
		s.Players.PlayerRemoving:Connect(function(player)
			local profile = cache[player]
			if profile then
				profile.Data.PlayTime += 3600
			end
		end)
		local player = s:addPlayer(1)
		s:await(Data.Await, Data, player)
		s:removePlayer(player)
		Sim.advance(3)
		local raw = Sim.peek("Main", "Player_1")
		local data = raw.Data
		if typeof(data.AnchorBlob) == "buffer" then
			data = s:require("src/Codec.luau").decode(data.AnchorBlob)
		end
		T.eq(raw.MetaData.ActiveSession, nil, "released")
		T.eq(data.PlayTime, 3600, "last-frame write from another PlayerRemoving handler was dropped")
	end)

	T.test(`{format}: stock API - write right after EndSession in the same frame is saved`, function()
		local s = Sim.newServer({ JobId = "S1" })
		local store = s:require("src", { name = "Anchor" }).New("Main", TEMPLATE, { Format = format })
		local profile = s:await(store.StartSessionAsync, store, "Player_1")
		profile:EndSession()
		profile.Data.Coins = 42 -- e.g. another handler, same frame (stock saves this)
		Sim.advance(3)
		local raw = Sim.peek("Main", "Player_1")
		local data = raw.Data
		if typeof(data.AnchorBlob) == "buffer" then
			data = s:require("src/Codec.luau").decode(data.AnchorBlob)
		end
		T.eq(data.Coins, 42)
	end)
end
