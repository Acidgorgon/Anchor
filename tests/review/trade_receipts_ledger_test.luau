-- Review: the receipt ledger keeps the last 100 PurchaseIds, including ids whose save never
-- landed (NotProcessedYet). During a DataStore outage a buyer who makes 100+ purchases pushes
-- the oldest unconfirmed id out of the ledger; Roblox retries that receipt and it is granted
-- a second time (one charge, two grants).
local T = require("@mock/testkit")
local Sim = require("@mock/sim")

local TEMPLATE = { Coins = 0 }

local function anchor(server)
	return server:require("src", { name = "Anchor" })
end

local function receipt(purchaseId, userId)
	return { PurchaseId = purchaseId, PlayerId = userId, ProductId = 1, CurrencySpent = 1 }
end

local GRANTED = Sim.Enum.ProductPurchaseDecision.PurchaseGranted

T.test("101 purchases during an outage: the first is granted twice when Roblox retries it", function()
	local s = Sim.newServer({ JobId = "S1" })
	local Data = anchor(s).new("Main", TEMPLATE)
	Data:Bind()
	local player = s:addPlayer(1)
	local profile = s:await(Data.Await, Data, player)
	local grants = {}
	local function grant(data, info)
		grants[info.PurchaseId] = (grants[info.PurchaseId] or 0) + 1
		data.Coins += 1
	end
	local rule = Sim.injectError({ method = "UpdateAsync", key = "Player_1" })
	for i = 1, 101 do
		s:await(Data.ProcessReceipt, Data, receipt(`p{i}`, 1), grant) -- NotProcessedYet
	end
	rule:remove()
	-- outage over: Roblox retries every unacknowledged receipt
	for i = 1, 101 do
		T.eq(s:await(Data.ProcessReceipt, Data, receipt(`p{i}`, 1), grant), GRANTED)
	end
	T.eq(grants["p1"], 1, "p1 granted once")
	T.eq(profile.Data.Coins, 101, "101 purchases -> 101 coins")
end)
