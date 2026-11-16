-- Stock ProfileStore 1.0.3 on the mock: several servers sharing one DataStore.
local T = require("@mock/testkit")
local Sim = require("@mock/sim")

local PS_PATH = "reference/ProfileStore-1.0.3.luau"
local TEMPLATE = { Coins = 0, Items = {} }

local function boot(server)
	local PS = server:require(PS_PATH, { name = "ProfileStore" })
	return PS, PS.New("PlayerData", TEMPLATE)
end

T.test("each server gets its own fresh copy of the module", function()
	local a = Sim.newServer({ JobId = "A" })
	local b = Sim.newServer({ JobId = "B" })
	local PSa = boot(a)
	local PSb = boot(b)
	T.expect(PSa ~= PSb)
	PSa.SetConstant("AUTO_SAVE_PERIOD", 5)
	PSa.IsClosing = true
	T.eq(PSb.IsClosing, false)
	T.eq(a.game.JobId, "A")
	T.eq(b.game.JobId, "B")
end)

T.test("second server waits, sends PS_ message, first releases, second loads intact", function()
	local a = Sim.newServer({ PlaceId = 1, JobId = "A" })
	local b = Sim.newServer({ PlaceId = 1, JobId = "B" })
	local _, storeA = boot(a)
	local _, storeB = boot(b)

	local pa = a:await(storeA.StartSessionAsync, storeA, "Player_1")
	pa.Data.Coins = 500 -- not saved yet: must travel with the release save
	table.insert(pa.Data.Items, "Shield")
	local endedOnA, lastReason = false, nil
	pa.OnSessionEnd:Connect(function()
		endedOnA = true
	end)
	pa.OnLastSave:Connect(function(reason)
		lastReason = reason
	end)

	local t0 = Sim.now()
	local job = b:spawn(storeB.StartSessionAsync, storeB, "Player_1")
	T.expect(Sim.runUntil(function()
		return job.done
	end, 60), "B finished")
	local pb = job:result()
	T.expect(pb, "B got the profile")
	T.expect(Sim.now() - t0 < 10, `handoff took {Sim.now() - t0} s`)
	T.expect(endedOnA, "A's session ended")
	T.eq(lastReason, "External")
	T.expect(not pa:IsActive())
	T.eq(pb.Data.Coins, 500)
	T.deepEq(pb.Data.Items, { "Shield" })
	T.eq(pb.SessionLoadCount, 2)
	T.expect(b.stats.publishes >= 1, "B published the end-session request")
	T.expect(a.stats.messagesReceived >= 1, "A received it")
	local raw = Sim.peek("PlayerData", "Player_1")
	T.eq(raw.MetaData.ActiveSession[2], "B")
	T.eq(raw.MetaData.ForceLoadSession, nil)
end)

T.test("handoff still works when MessagingService drops everything (autosave path)", function()
	Sim.configure({ messageDropRate = 1 })
	local a = Sim.newServer({ JobId = "A" })
	local b = Sim.newServer({ JobId = "B" })
	local PSa, storeA = boot(a)
	local _, storeB = boot(b)
	PSa.SetConstant("AUTO_SAVE_PERIOD", 20)
	local pa = a:await(storeA.StartSessionAsync, storeA, "Player_1")
	pa.Data.Coins = 9
	local pb = b:await(storeB.StartSessionAsync, storeB, "Player_1")
	T.expect(pb)
	T.eq(pb.Data.Coins, 9)
	T.expect(not pa:IsActive())
end)

T.test("owner crashes: waiting server steals after SESSION_STEAL, last saved data intact", function()
	local a = Sim.newServer({ JobId = "A" })
	local b = Sim.newServer({ JobId = "B" })
	local _, storeA = boot(a)
	local _, storeB = boot(b)
	local pa = a:await(storeA.StartSessionAsync, storeA, "Player_1")
	pa.Data.Coins = 70
	a:await(function()
		pa:Save()
		pa.OnAfterSave:Wait()
	end)
	pa.Data.Coins = 71 -- lost with the crash
	a:crash()

	local t0 = Sim.now()
	local pb = b:await(storeB.StartSessionAsync, storeB, "Player_1")
	local took = Sim.now() - t0
	T.expect(pb, "stolen")
	T.expect(took >= 40 and took < 60, `steal took {took} s`)
	T.eq(pb.Data.Coins, 70)
	T.eq(Sim.peek("PlayerData", "Player_1").MetaData.ActiveSession[2], "B")
end)

T.test("owner crashed long ago: ASSUME_DEAD lets the next server load at once", function()
	local a = Sim.newServer({ JobId = "A" })
	local b = Sim.newServer({ JobId = "B" })
	local _, storeA = boot(a)
	local _, storeB = boot(b)
	local pa = a:await(storeA.StartSessionAsync, storeA, "Player_1")
	pa.Data.Coins = 3
	a:await(function()
		pa:Save()
		pa.OnAfterSave:Wait()
	end)
	a:crash()
	Sim.advance(640) -- > ASSUME_DEAD (630) since LastUpdate
	local t0 = Sim.now()
	local pb = b:await(storeB.StartSessionAsync, storeB, "Player_1")
	T.expect(pb)
	T.expect(Sim.now() - t0 < 2, "loaded in one call")
	T.eq(pb.Data.Coins, 3)
	T.eq(b.stats.calls.UpdateAsync, 1)
end)

T.test("Steal = true takes the session immediately", function()
	local a = Sim.newServer({ JobId = "A" })
	local b = Sim.newServer({ JobId = "B" })
	local _, storeA = boot(a)
	local _, storeB = boot(b)
	local pa = a:await(storeA.StartSessionAsync, storeA, "Player_1")
	local pb = b:await(storeB.StartSessionAsync, storeB, "Player_1", { Steal = true })
	T.expect(pb)
	T.eq(b.stats.calls.UpdateAsync, 1)
	-- A notices on its next save and ends its session without overwriting B.
	pa.Data.Coins = 1234
	a:await(function()
		pa:Save()
		pa.OnAfterSave:Wait()
	end)
	T.expect(not pa:IsActive(), "A lost the session")
	T.eq(Sim.peek("PlayerData", "Player_1").Data.Coins, 0)
end)

T.test("MessageAsync from another server reaches the owner through MessagingService", function()
	local a = Sim.newServer({ JobId = "A" })
	local b = Sim.newServer({ JobId = "B" })
	local _, storeA = boot(a)
	local _, storeB = boot(b)
	local pa = a:await(storeA.StartSessionAsync, storeA, "Player_1")
	local received = {}
	pa:MessageHandler(function(message, processed)
		table.insert(received, message)
		pa.Data.Coins += message.Gift
		processed()
	end)
	local t0 = Sim.now()
	T.eq(b:await(storeB.MessageAsync, storeB, "Player_1", { Gift = 25 }), true)
	T.expect(Sim.runUntil(function()
		return #received == 1
	end, 30), "message delivered")
	T.expect(Sim.now() - t0 < 5, `delivery took {Sim.now() - t0} s`)
	T.deepEq(received[1], { Gift = 25 })
	T.eq(pa.Data.Coins, 25)
	-- Processed messages are cleared from the stored profile on the next save.
	a:await(function()
		pa:Save()
		pa.OnAfterSave:Wait()
	end)
	local raw = Sim.peek("PlayerData", "Player_1")
	T.eq(#raw.GlobalUpdates[2], 0)
	T.eq(raw.Data.Coins, 25)
end)

T.test("MessageAsync to an offline profile is delivered on next load", function()
	local a = Sim.newServer({ JobId = "A" })
	local b = Sim.newServer({ JobId = "B" })
	local _, storeA = boot(a)
	local _, storeB = boot(b)
	T.eq(b:await(storeB.MessageAsync, storeB, "Player_9", { Gift = 1 }), true)
	T.eq(b:await(storeB.MessageAsync, storeB, "Player_9", { Gift = 2 }), true)
	local pa = a:await(storeA.StartSessionAsync, storeA, "Player_9")
	local got = {}
	pa:MessageHandler(function(message, processed)
		table.insert(got, message.Gift)
		processed()
	end)
	Sim.advance(0.1)
	T.deepEq(got, { 1, 2 })
end)

T.test("profile hops across three servers with no loss", function()
	local servers, stores = {}, {}
	for i = 1, 3 do
		servers[i] = Sim.newServer({ JobId = "S" .. i })
		local _, store = boot(servers[i])
		stores[i] = store
	end
	local current = nil
	for hop = 1, 9 do
		local i = (hop - 1) % 3 + 1
		local p = servers[i]:await(stores[i].StartSessionAsync, stores[i], "Player_1")
		T.expect(p, `hop {hop}`)
		T.eq(p.Data.Coins, hop - 1, `coins at hop {hop}`)
		p.Data.Coins += 1
		if current then
			T.expect(not current:IsActive())
		end
		current = p
	end
	current:EndSession()
	Sim.advance(2)
	T.eq(Sim.peek("PlayerData", "Player_1").Data.Coins, 9)
end)
