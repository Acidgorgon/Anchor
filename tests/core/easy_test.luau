-- Anchor easy API: Anchor.new + store:Bind / Get / Await / Update / Loaded, and the
-- hook seam feature modules (trades, receipts) plug into.
local T = require("@mock/testkit")
local Sim = require("@mock/sim")

local TEMPLATE = { Coins = 0, Items = {} }

local function anchor(server)
	return server:require("src", { name = "Anchor" })
end

T.test("Bind loads on join, Get/Await/Update work, leaving saves and releases", function()
	local s = Sim.newServer({ JobId = "A" })
	local A = anchor(s)
	local Data = A.new("Main", TEMPLATE)
	local loadedEvents = {}
	Data.Loaded:Connect(function(player, profile)
		table.insert(loadedEvents, { player, profile })
	end)
	local onLoaded = 0
	Data:Bind({
		OnLoaded = function()
			onLoaded += 1
		end,
	})

	local player = s:addPlayer(42)
	T.eq(Data:Get(player), nil, "not loaded yet")
	local profile = s:await(Data.Await, Data, player)
	T.expect(profile, "Await returned the profile")
	T.eq(Data:Get(player), profile)
	T.eq(#loadedEvents, 1)
	T.eq(loadedEvents[1][1], player)
	T.eq(onLoaded, 1)
	T.eq(profile.Key, "Player_42")
	T.deepEq(profile.UserIds, { 42 })

	T.eq(Data:Update(player, function(data)
		data.Coins += 10
	end), true)
	T.eq(profile.Data.Coins, 10)

	s:removePlayer(player)
	T.eq(Data:Get(player), nil)
	Sim.advance(2)
	local raw = Sim.peek("Main", "Player_42")
	T.eq(raw.Data.Coins, 10)
	T.eq(raw.MetaData.ActiveSession, nil)
	T.eq(Data:Update(player, function() end), false)
end)

T.test("Bind: custom key, Await returns nil when the player leaves while loading", function()
	local s = Sim.newServer({ JobId = "A" })
	local Data = anchor(s).new("Main", TEMPLATE)
	Data:Bind({
		Key = function(player)
			return "PLAYER_" .. player.UserId
		end,
	})
	Sim.configure({ latency = { 2, 2 } }) -- slow DataStore
	local player = s:addPlayer(7)
	local job = s:spawn(Data.Await, Data, player)
	Sim.advance(0.5)
	s:removePlayer(player)
	Sim.advance(10)
	T.expect(job.done)
	T.eq(job:result(), nil)
	local raw = Sim.peek("Main", "PLAYER_7")
	T.expect(raw ~= nil, "custom key used")
	T.eq(raw.MetaData.ActiveSession, nil, "released after the player left mid-load")
end)

T.test("Bind kicks when the profile can't be loaded or the session is taken elsewhere", function()
	local s1 = Sim.newServer({ JobId = "A" })
	local s2 = Sim.newServer({ JobId = "B" })
	local D1 = anchor(s1).new("Main", TEMPLATE)
	local D2 = anchor(s2).new("Main", TEMPLATE)
	D1:Bind({ KickMessage = "bye" })
	D2:Bind()
	local p1 = s1:addPlayer(1)
	local profile = s1:await(D1.Await, D1, p1)
	T.expect(profile)
	-- The player joins another server before the first one noticed they left:
	local p2 = s2:addPlayer(1)
	local profile2 = s2:await(D2.Await, D2, p2)
	T.expect(profile2, "second server got it")
	T.expect(s1:wasKicked(1), "first server kicked the stale player")
	local _, message = s1:wasKicked(1)
	T.eq(message, "bye")

	-- DataStore down for longer than START_SESSION_TIMEOUT -> kick
	Sim.injectError({ method = "UpdateAsync", key = "Player_3" })
	local p3 = s2:addPlayer(3)
	T.eq(s2:await(D2.Await, D2, p3), nil)
	T.expect(s2:wasKicked(3))
end)

T.test("players already in game when Bind is called are loaded; shutdown saves them", function()
	local s = Sim.newServer({ JobId = "A" })
	local Data = anchor(s).new("Main", TEMPLATE)
	local a = s:addPlayer(1)
	local b = s:addPlayer(2)
	Data:Bind()
	local pa = s:await(Data.Await, Data, a)
	local pb = s:await(Data.Await, Data, b)
	pa.Data.Coins = 1
	pb.Data.Coins = 2
	s:shutdown()
	T.eq(Sim.peek("Main", "Player_1").Data.Coins, 1)
	T.eq(Sim.peek("Main", "Player_2").Data.Coins, 2)
	T.eq(Sim.peek("Main", "Player_2").MetaData.ActiveSession, nil)
end)

T.test("hooks: message hook claims messages before user handlers; anchor_meta persists", function()
	local s = Sim.newServer({ JobId = "A" })
	local A = anchor(s)
	local Core = A._Core
	local claimed = {}
	Core.AddHook("Message", function(profile, message, processed)
		if message.AnchorTx ~= nil then
			table.insert(claimed, message.AnchorTx)
			profile.Data.Coins += message.Patch
			profile.anchor_meta.Applied = profile.anchor_meta.Applied or {}
			profile.anchor_meta.Applied[message.AnchorTx] = 1
			profile:MarkMetaDirty()
			processed()
			return true
		end
		return false
	end)
	local afterSaves = 0
	Core.AddHook("AfterSave", function(_, wrote)
		if wrote then
			afterSaves += 1
		end
	end)
	local store = A.New("Main", TEMPLATE)
	-- one tx message waiting before load, one user message
	s:await(store.MessageAsync, store, "K", { AnchorTx = "tx1", Patch = 5 })
	s:await(store.MessageAsync, store, "K", { Gift = 1 })
	local p = s:await(store.StartSessionAsync, store, "K")
	T.deepEq(claimed, { "tx1" }, "claimed at load")
	T.eq(p.Data.Coins, 5)
	local userSaw = {}
	p:MessageHandler(function(m, processed)
		table.insert(userSaw, m)
		processed()
	end)
	T.eq(#userSaw, 1, "user handler never sees the tx message")
	T.eq(userSaw[1].Gift, 1)

	-- a tx message arriving mid-session
	local s2 = Sim.newServer({ JobId = "B" })
	local st2 = anchor(s2).New("Main", TEMPLATE)
	s2:await(st2.MessageAsync, st2, "K", { AnchorTx = "tx2", Patch = 7 })
	T.expect(Sim.runUntil(function()
		return #claimed == 2
	end, 15))
	T.eq(#userSaw, 1)
	T.eq(s:await(p.SaveAsync, p), true)
	T.expect(afterSaves >= 1)
	local raw = Sim.peek("Main", "K")
	T.eq(raw.Data.Coins, 12)
	T.deepEq(raw.MetaData.Anchor, { Applied = { tx1 = 1, tx2 = 1 } })
	T.eq(#raw.GlobalUpdates[2], 0)

	-- anchor_meta comes back on the next session
	p:EndSession()
	Sim.advance(2)
	local again = s:await(store.StartSessionAsync, store, "K")
	T.deepEq(again.anchor_meta, { Applied = { tx1 = 1, tx2 = 1 } })
end)
