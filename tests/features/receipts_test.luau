-- store:ProcessReceipt / store:HandleReceipts: grant exactly once, PurchaseGranted only
-- after a save containing the PurchaseId succeeded.
local T = require("@mock/testkit")
local Sim = require("@mock/sim")

local TEMPLATE = { Coins = 0 }

local function anchor(server)
	return server:require("src", { name = "Anchor" })
end

local function addMarketplace(server)
	local mps = Sim.Roblox.newInstance("MarketplaceService", "MarketplaceService")
	rawset(mps, "_server", server)
	mps.Parent = server.game
	return mps
end

local function receipt(purchaseId, userId, productId)
	return { PurchaseId = purchaseId, PlayerId = userId, ProductId = productId or 1, CurrencySpent = 10 }
end

local function boot(jobId)
	local s = Sim.newServer({ JobId = jobId or "S1" })
	local Data = anchor(s).new("Main", TEMPLATE)
	Data:Bind()
	return s, Data
end

local GRANTED = Sim.Enum.ProductPurchaseDecision.PurchaseGranted
local NOT_YET = Sim.Enum.ProductPurchaseDecision.NotProcessedYet

T.test("grant once, PurchaseGranted after the save; duplicate delivery is not granted again", function()
	local s, Data = boot()
	local player = s:addPlayer(1)
	local profile = s:await(Data.Await, Data, player)
	local grants = 0
	local function grant(data)
		grants += 1
		data.Coins += 100
	end
	T.eq(s:await(Data.ProcessReceipt, Data, receipt("p1", 1), grant), GRANTED)
	T.eq(Sim.peek("Main", "Player_1").Data.Coins, 100, "saved before PurchaseGranted")
	T.deepEq(Sim.peek("Main", "Player_1").MetaData.Anchor.Receipts, { "p1" })
	local writes = Sim.stats().calls.UpdateAsync
	T.eq(s:await(Data.ProcessReceipt, Data, receipt("p1", 1), grant), GRANTED)
	T.eq(Sim.stats().calls.UpdateAsync, writes, "known-saved duplicate needs no write")
	T.eq(grants, 1)
	T.eq(profile.Data.Coins, 100)

	-- after a rejoin on another server the ledger still dedups
	s:removePlayer(player)
	Sim.advance(3)
	local s2, D2 = boot("S2")
	local p2 = s2:addPlayer(1)
	local prof2 = s2:await(D2.Await, D2, p2)
	T.eq(s2:await(D2.ProcessReceipt, D2, receipt("p1", 1), grant), GRANTED)
	T.eq(grants, 1)
	T.eq(prof2.Data.Coins, 100)
end)

T.test("save failure -> NotProcessedYet; the retry grants nothing new and returns PurchaseGranted", function()
	local s, Data = boot()
	local player = s:addPlayer(1)
	local profile = s:await(Data.Await, Data, player)
	local grants = 0
	local function grant(data)
		grants += 1
		data.Coins += 100
	end
	local rule = Sim.injectError({ method = "UpdateAsync", key = "Player_1" })
	T.eq(s:await(Data.ProcessReceipt, Data, receipt("p2", 1), grant), NOT_YET)
	T.eq(Sim.peek("Main", "Player_1").Data.Coins, 0)
	T.eq(profile.Data.Coins, 100, "granted in memory with its ledger entry")
	rule:remove()
	T.eq(s:await(Data.ProcessReceipt, Data, receipt("p2", 1), grant), GRANTED)
	T.eq(grants, 1)
	T.eq(Sim.peek("Main", "Player_1").Data.Coins, 100)
end)

T.test("grant errors or returns false -> NotProcessedYet and nothing changes; player not here -> NotProcessedYet", function()
	local s, Data = boot()
	local player = s:addPlayer(1)
	local profile = s:await(Data.Await, Data, player)
	T.eq(s:await(Data.ProcessReceipt, Data, receipt("p3", 1), function(data)
		data.Coins += 5
		error("oops")
	end), NOT_YET)
	T.eq(s:await(Data.ProcessReceipt, Data, receipt("p3", 1), function(data)
		data.Coins += 5
		return false
	end), NOT_YET)
	T.eq(profile.Data.Coins, 0)
	T.eq(profile.anchor_meta.Receipts, nil)
	T.eq(s:await(Data.ProcessReceipt, Data, receipt("p4", 99), function() end), NOT_YET)
end)

for _, phase in { "before", "after" } do
	T.test(`crash {phase} the receipt save commits, then retry elsewhere grants exactly once`, function()
		T.allowThreadErrors()
		local s, Data = boot()
		local player = s:addPlayer(1)
		s:await(Data.Await, Data, player)
		local grants = 0
		local function grant(data)
			grants += 1
			data.Coins += 100
		end
		local armed = true
		Sim.injectError({
			method = "UpdateAsync",
			key = "Player_1",
			when = function(info)
				if armed then
					armed = false
					info.server:crash()
					return phase == "before"
				end
				return false
			end,
		})
		local job = s:spawn(Data.ProcessReceipt, Data, receipt("p5", 1), grant)
		Sim.advance(5)
		T.expect(not s.alive)
		T.expect(not job.done or job:result() ~= GRANTED, "never told Roblox it was granted")
		T.eq(grants, 1)

		-- Roblox retries the receipt when the player joins another server
		local s2, D2 = boot("S2")
		local p2 = s2:addPlayer(1)
		local prof2 = s2:await(D2.Await, D2, p2)
		T.eq(s2:await(D2.ProcessReceipt, D2, receipt("p5", 1), grant), GRANTED)
		T.eq(prof2.Data.Coins, 100)
		T.eq(grants, if phase == "before" then 2 else 1, "grant ran again only if the first never saved")
		s2:removePlayer(p2)
		Sim.advance(3)
		T.eq(Sim.peek("Main", "Player_1").Data.Coins, 100)
	end)
end

T.test("HandleReceipts: one line wires MarketplaceService.ProcessReceipt with per-product grants", function()
	local s, Data = boot()
	local mps = addMarketplace(s)
	Data:HandleReceipts({
		[111] = function(data)
			data.Coins += 100
		end,
		[222] = function(data, info, player)
			data.Coins += info.CurrencySpent + player.UserId
		end,
	})
	local player = s:addPlayer(7)
	local profile = s:await(Data.Await, Data, player)
	local callback = mps.ProcessReceipt
	T.eq(s:await(callback, receipt("a", 7, 111)), GRANTED)
	T.eq(s:await(callback, receipt("b", 7, 222)), GRANTED)
	T.eq(s:await(callback, receipt("a", 7, 111)), GRANTED)
	T.eq(s:await(callback, receipt("c", 7, 333)), NOT_YET, "unknown product")
	T.eq(profile.Data.Coins, 117)
end)

T.test("receipts write through the Ripple state when UseRipple is on", function()
	local s, Data = boot()
	local writes = {}
	Data:UseRipple(function(_, profile)
		return setmetatable({}, {
			__index = profile.Data,
			__newindex = function(_, k, v)
				table.insert(writes, k)
				profile.Data[k] = v
			end,
		})
	end)
	local player = s:addPlayer(1)
	local profile = s:await(Data.Await, Data, player)
	T.eq(s:await(Data.ProcessReceipt, Data, receipt("r", 1), function(data)
		data.Coins += 3
	end), GRANTED)
	T.eq(profile.Data.Coins, 3)
	T.deepEq(writes, { "Coins" })
end)
