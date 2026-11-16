-- Easy API additions: 3-line quick start, Leaving, Send / OnMessage, UseRipple + Update,
-- and trades between Bind-managed players writing through their Ripple states.
local T = require("@mock/testkit")
local Sim = require("@mock/sim")

local TEMPLATE = { Coins = 0, Items = {} }

local function anchor(server)
	return server:require("src", { name = "Anchor" })
end

T.test("quick start: new + Bind + Update is all a game needs", function()
	local s = Sim.newServer()
	anchor(s) -- mounts the module at ServerScriptService.Anchor
	local job = s:runScript([[
		local Data = require(game.ServerScriptService.Anchor).new("Main", { Coins = 0 })
		Data:Bind()
		game.Players.PlayerAdded:Connect(function(player)
			Data:Await(player)
			Data:Update(player, function(data) data.Coins += 10 end)
		end)
	]])
	T.expect(job.done and job.ok, "script ran")
	local player = s:addPlayer(1)
	Sim.advance(3)
	s:removePlayer(player)
	Sim.advance(3)
	T.eq(Sim.peek("Main", "Player_1").Data.Coins, 10)
end)

T.test("Leaving fires before the session ends, and its writes are saved", function()
	local s = Sim.newServer()
	local Data = anchor(s).new("Main", TEMPLATE)
	local left = {}
	Data.Leaving:Connect(function(player, profile)
		table.insert(left, player.UserId)
		profile.Data.Coins = 77 -- last-moment write
	end)
	Data:Bind()
	local player = s:addPlayer(1)
	s:await(Data.Await, Data, player)
	s:removePlayer(player)
	Sim.advance(3)
	T.deepEq(left, { 1 })
	T.eq(Sim.peek("Main", "Player_1").Data.Coins, 77)
end)

T.test("Send / OnMessage: other server, offline, and kept until a handler accepts it", function()
	local s1 = Sim.newServer({ JobId = "S1" })
	local s2 = Sim.newServer({ JobId = "S2" })
	local D1 = anchor(s1).new("Main", TEMPLATE)
	local D2 = anchor(s2).new("Main", TEMPLATE)
	local got = {}
	local accept = true
	D2:OnMessage("Gift", function(player, payload)
		table.insert(got, { player.UserId, payload.Amount })
		if not accept then
			return false
		end
		D2:Update(player, function(data)
			data.Coins += payload.Amount
		end)
	end)
	D2:Bind()
	local player = s2:addPlayer(1)
	local profile = s2:await(D2.Await, D2, player)

	T.eq(s1:await(D1.Send, D1, 1, "Gift", { Amount = 5 }), true)
	T.expect(Sim.runUntil(function()
		return #got == 1
	end, 30), "delivered to the other server")
	T.eq(profile.Data.Coins, 5)
	T.eq(s2:await(profile.SaveAsync, profile), true)
	T.eq(#Sim.peek("Main", "Player_1").GlobalUpdates[2], 0, "processed message dropped")

	-- offline: delivered on join
	s2:removePlayer(player)
	Sim.advance(3)
	T.eq(s1:await(D1.Send, D1, 1, "Gift", { Amount = 7 }), true)
	accept = false
	local p2 = s2:addPlayer(1)
	local prof2 = s2:await(D2.Await, D2, p2)
	Sim.advance(1)
	T.eq(#got, 2)
	T.eq(prof2.Data.Coins, 5, "handler said keep it")
	s2:removePlayer(p2)
	Sim.advance(3)
	T.eq(#Sim.peek("Main", "Player_1").GlobalUpdates[2], 1, "kept in the queue")
	accept = true
	local p3 = s2:addPlayer(1)
	local prof3 = s2:await(D2.Await, D2, p3)
	Sim.advance(1)
	T.eq(prof3.Data.Coins, 12)
end)

local function fakeRipple(log, rejectKey)
	local function wrap(plain, path)
		return setmetatable({}, {
			__index = function(_, k)
				local v = plain[k]
				if type(v) == "table" then
					return wrap(v, path .. "." .. tostring(k))
				end
				return v
			end,
			__newindex = function(_, k, v)
				if k == rejectKey then
					error("schema rejects " .. tostring(k))
				end
				table.insert(log, path .. "." .. tostring(k))
				plain[k] = v
			end,
		})
	end
	return wrap
end

T.test("UseRipple: Update hands fn the state; trades between Bind players write through both states", function()
	local s = Sim.newServer()
	local A = anchor(s)
	local Data = A.new("Main", TEMPLATE)
	local log = {}
	local wrap = fakeRipple(log, "Banned")
	Data:Bind()
	local pa = s:addPlayer(1)
	local profA = s:await(Data.Await, Data, pa)
	Data:UseRipple(function(player, profile) -- attached to players already in, too
		return wrap(profile.Data, "P" .. player.UserId)
	end)
	local pb = s:addPlayer(2)
	local profB = s:await(Data.Await, Data, pb)

	Data:Update(pa, function(data)
		data.Coins += 100
		data.Items.Sword = true
	end)
	T.eq(profA.Data.Coins, 100)
	T.expect(table.find(log, "P1.Coins"), "Update wrote through the state")

	local errors = {}
	A.OnError:Connect(function(m)
		table.insert(errors, m)
	end)
	table.clear(log)
	local ok = s:await(A.Trade, Data:Get(pa), Data:Get(pb), function(da, db)
		da.Coins -= 40
		db.Coins += 40
		db.Items.Sword, da.Items.Sword = true, nil
		db.Banned = true -- this field's live write errors -> plain fallback
	end)
	T.eq(ok, true)
	T.eq(profA.Data.Coins, 60)
	T.eq(profB.Data.Coins, 40)
	T.eq(profB.Data.Items.Sword, true)
	T.eq(profB.Data.Banned, true, "fallback kept the data correct")
	T.expect(table.find(log, "P1.Coins") and table.find(log, "P2.Coins") and table.find(log, "P2.Items.Sword"))
	T.expect(#errors == 1 and string.find(errors[1], "Data.Banned", 1, true), T.show(errors))
	Sim.advance(5)
	T.eq(Sim.peek("Main", "Player_2").Data.Banned, true)
end)
