-- Dev options (Mock / Reset / PlayAs / View / NoSave / KeyPrefix), ModuleScript attributes,
-- and the Studio-only guard.
local T = require("@mock/testkit")
local Sim = require("@mock/sim")

local TEMPLATE = { Coins = 0, Items = {} }

local function anchor(server)
	return server:require("src", { name = "Anchor" })
end

local function seed(key, data, userIds)
	Sim.poke("Main", key, {
		Data = data,
		MetaData = { ProfileCreateTime = Sim.unixTime(), SessionLoadCount = 1, LastUpdate = Sim.unixTime(), MetaTags = {} },
		GlobalUpdates = { 0, {} },
		RobloxMetaData = {},
		UserIds = userIds or {},
	})
end

local function studio()
	return Sim.newServer({ JobId = "STUDIO", IsStudio = true })
end

local function join(s, Data, userId)
	local player = s:addPlayer(userId)
	return player, s:await(Data.Await, Data, player)
end

T.test("Mock: nothing touches the DataStore; data lives for the server's lifetime", function()
	local s = studio()
	local Data = anchor(s).new("Main", TEMPLATE, { Mock = true })
	Data:Bind()
	local player, profile = join(s, Data, 1)
	T.expect(profile.is_mock, "mock profile")
	profile.Data.Coins = 5
	s:removePlayer(player)
	Sim.advance(3)
	T.deepEq(Sim.keys("Main"), {}, "no live key written")
	local _, again = join(s, Data, 1)
	T.eq(again.Data.Coins, 5, "kept in the in-memory store")
	T.eq(s:await(Data.Send, Data, 1, "Hello", { x = 1 }), true, "messages go to the mock too")
	T.deepEq(Sim.keys("Main"), {})
end)

T.test("Reset: fresh template every join, old save kept in version history, no RemoveAsync", function()
	seed("Player_1", { Coins = 999, Items = { Sword = true } })
	local s = studio()
	local Data = anchor(s).new("Main", TEMPLATE, { Reset = true })
	Data:Bind()
	local player, profile = join(s, Data, 1)
	T.deepEq(profile.Data, { Coins = 0, Items = {} })
	profile.Data.Coins = 3
	s:removePlayer(player)
	Sim.advance(3)
	T.eq(Sim.peek("Main", "Player_1").Data.Coins, 3)
	T.eq(Sim.stats().calls.RemoveAsync, nil, "never RemoveAsync")
	local found = false
	for _, v in Sim.versions("Main", "Player_1") do
		if v.value and v.value.Data.Coins == 999 then
			found = true
		end
	end
	T.expect(found, "old save still in ListVersions")
	-- Data:Reset(player) mid-session (Studio)
	local p2, prof2 = join(s, Data, 1)
	prof2.Data.Coins = 50
	T.eq(Data:Reset(p2), true)
	T.deepEq(prof2.Data, { Coins = 0, Items = {} })
end)

T.test("PlayAs: the first player plays on that user's save; their UserIds aren't touched", function()
	seed("Player_2", { Coins = 42, Items = {} }, { 2 })
	local s = studio()
	local Data = anchor(s).new("Main", TEMPLATE, { PlayAs = 2 })
	Data:Bind()
	local player, profile = join(s, Data, 1)
	T.eq(profile.Key, "Player_2")
	T.eq(profile.Data.Coins, 42)
	profile.Data.Coins = 43
	local _, other = join(s, Data, 3)
	T.eq(other.Key, "Player_3", "only one player plays as the target")
	s:removePlayer(player)
	Sim.advance(3)
	local raw = Sim.peek("Main", "Player_2")
	T.eq(raw.Data.Coins, 43)
	T.deepEq(raw.UserIds, { 2 })
	T.eq(Sim.peek("Main", "Player_1"), nil)
end)

T.test("View: read-only look at another save, never written, no session lock", function()
	seed("Player_2", { Coins = 42, Items = {} })
	local s = studio()
	local Data = anchor(s).new("Main", TEMPLATE, { View = 2 })
	Data:Bind()
	local versions = #Sim.versions("Main", "Player_2")
	local player, profile = join(s, Data, 1)
	T.eq(profile.Data.Coins, 42)
	T.eq(Data:Get(player), profile)
	T.eq(Data:Update(player, function(d)
		d.Coins = 1
	end), true)
	Sim.advance(700) -- autosaves
	s:removePlayer(player)
	Sim.advance(5)
	T.eq(#Sim.versions("Main", "Player_2"), versions, "nothing written")
	T.eq(Sim.peek("Main", "Player_2").Data.Coins, 42)
	T.eq(Sim.peek("Main", "Player_1"), nil)
end)

T.test("NoSave: your own save, never written (existing and brand-new players)", function()
	seed("Player_1", { Coins = 5, Items = {} })
	local s = studio()
	local Data = anchor(s).new("Main", TEMPLATE, { NoSave = true })
	Data:Bind()
	local versions = #Sim.versions("Main", "Player_1")
	local player, profile = join(s, Data, 1)
	T.eq(profile.Data.Coins, 5)
	profile.Data.Coins = 500
	local p9, fresh = join(s, Data, 9)
	T.deepEq(fresh.Data, { Coins = 0, Items = {} }, "template for a player with no save")
	Sim.advance(700)
	s:removePlayer(player)
	s:removePlayer(p9)
	Sim.advance(5)
	T.eq(#Sim.versions("Main", "Player_1"), versions)
	T.eq(Sim.peek("Main", "Player_1").Data.Coins, 5)
	T.eq(Sim.peek("Main", "Player_9"), nil)
end)

T.test("attributes on the ModuleScript toggle dev options; code options win", function()
	seed("Player_1", { Coins = 5, Items = {} })
	local s = studio()
	local Anchor = anchor(s)
	local module = s.ServerScriptService:FindFirstChild("Anchor")
	module:SetAttribute("Reset", true)
	local Data = Anchor.new("Main", TEMPLATE)
	Data:Bind()
	local _, profile = join(s, Data, 1)
	T.eq(profile.Data.Coins, 0, "attribute Reset applied")

	local Other = Anchor.new("Other", TEMPLATE, { Reset = false })
	T.eq(Other.dev.Reset, nil, "code option wins over the attribute")
	module:SetAttribute("PlayAs", 77)
	local Third = Anchor.new("Third", TEMPLATE)
	T.eq(Third.dev.PlayAs, 77)
end)

T.test("live server: every dev option and attribute is ignored with one warning; Reset(player) refuses", function()
	seed("Player_1", { Coins = 5, Items = {} })
	local s = Sim.newServer({ JobId = "LIVE" }) -- RunService:IsStudio() == false
	local Anchor = anchor(s)
	s.ServerScriptService:FindFirstChild("Anchor"):SetAttribute("NoSave", true)
	local Data = Anchor.new("Main", TEMPLATE, { Mock = true, Reset = true, PlayAs = 2, View = 3 })
	T.deepEq(Data.dev, {})
	T.eq(#s:logsMatching("IGNORED on this live server", "warn"), 1)
	Data:Bind()
	local player, profile = join(s, Data, 1)
	T.eq(profile.Key, "Player_1")
	T.eq(profile.Data.Coins, 5, "not reset")
	T.expect(not profile.is_mock)
	T.eq(Data:Reset(player), false)
	T.eq(profile.Data.Coins, 5)
	profile.Data.Coins = 6
	s:removePlayer(player)
	Sim.advance(3)
	T.eq(Sim.peek("Main", "Player_1").Data.Coins, 6, "saved normally")
end)

T.test("AllowDevOptionsLive = true honours dev options on a live server", function()
	seed("Player_1", { Coins = 5, Items = {} })
	local s = Sim.newServer({ JobId = "TESTPLACE" })
	local Data = anchor(s).new("Main", TEMPLATE, { Reset = true, AllowDevOptionsLive = true })
	Data:Bind()
	local player, profile = join(s, Data, 1)
	T.eq(profile.Data.Coins, 0)
	profile.Data.Coins = 9
	T.eq(Data:Reset(player), true)
	T.eq(profile.Data.Coins, 0)
end)

T.test("KeyPrefix sets Bind's key, Send and Gift targets", function()
	local s = Sim.newServer()
	local Data = anchor(s).new("Main", TEMPLATE, { KeyPrefix = "PLAYER_" })
	Data:Bind()
	local _, profile = join(s, Data, 4)
	T.eq(profile.Key, "PLAYER_4")
	T.eq(s:await(Data.Gift, Data, 5, function(d)
		d.Coins += 1
	end), true)
	T.expect(Sim.peek("Main", "PLAYER_5") ~= nil)
end)

T.test("PlayAs and View build the target's key with Bind's custom Key function", function()
	local function key(player)
		return "u:" .. player.UserId
	end
	seed("u:2", { Coins = 42, Items = {} }, { 2 })
	local s = studio()
	local Data = anchor(s).new("Main", TEMPLATE, { PlayAs = 2 })
	Data:Bind({ Key = key })
	local player, profile = join(s, Data, 1)
	T.eq(profile.Key, "u:2")
	T.eq(profile.Data.Coins, 42)
	local _, other = join(s, Data, 3)
	T.eq(other.Key, "u:3")
	s:removePlayer(player)
	Sim.advance(3)
	T.eq(Sim.peek("Main", "Player_2"), nil, "KeyPrefix key never touched")

	local s2 = studio()
	local Viewer = anchor(s2).new("Main", TEMPLATE, { View = 2 })
	Viewer:Bind({ Key = key })
	local _, view = join(s2, Viewer, 5)
	T.eq(view.Key, "u:2")
	T.eq(view.Data.Coins, 42)
end)

T.test("PlayAs with a Key function that can't build the target's key kicks instead of using another key", function()
	local s = studio()
	local A = anchor(s)
	local errors = {}
	A.OnError:Connect(function(message)
		table.insert(errors, message)
	end)
	local Data = A.new("Main", TEMPLATE, { PlayAs = 2 })
	Data:Bind({
		Key = function(player)
			if player.UserId == 2 then
				error("no key for 2")
			end
			return "u:" .. player.UserId
		end,
	})
	s:addPlayer(1)
	Sim.advance(3)
	T.eq((s:wasKicked(1)), true)
	T.expect(#errors == 1 and string.find(errors[1], "no key for 2", 1, true), T.show(errors))
	T.eq(Sim.peek("Main", "Player_2"), nil)
	T.eq(Sim.peek("Main", "u:1"), nil)
end)
