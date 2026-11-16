-- Review: the ledger now trims only "confirmed" ids, but confirmed means "a save containing
-- it landed" (savedSet, also filled from the ledger at load), not "PurchaseGranted was
-- returned to Roblox". An id answered NotProcessedYet whose ledger entry later lands in an
-- autosave can be trimmed by 100 newer purchases; Roblox's retry then grants it again.
local T = require("@mock/testkit")
local Sim = require("@mock/sim")

local TEMPLATE = { Coins = 0 }

local function receipt(purchaseId)
	return { PurchaseId = purchaseId, PlayerId = 1, ProductId = 1, CurrencySpent = 1 }
end

T.test("NotProcessedYet receipt saved by a later autosave, then 100 purchases: retry grants twice", function()
	local s = Sim.newServer({ JobId = "S1" })
	local Data = s:require("src", { name = "Anchor" }).new("Main", TEMPLATE)
	Data:Bind()
	local player = s:addPlayer(1)
	local profile = s:await(Data.Await, Data, player)
	local grants = {}
	local function grant(data, info)
		grants[info.PurchaseId] = (grants[info.PurchaseId] or 0) + 1
		data.Coins += 1
	end
	local rule = Sim.injectError({ method = "UpdateAsync", key = "Player_1", count = 1 })
	T.eq(s:await(Data.ProcessReceipt, Data, receipt("p0"), grant), Sim.Enum.ProductPurchaseDecision.NotProcessedYet)
	T.eq(rule.hits, 1)
	T.eq(s:await(profile.SaveAsync, profile), true) -- any later save (autosave, leave) carries p0
	for i = 1, 100 do
		s:await(Data.ProcessReceipt, Data, receipt(`p{i}`), grant)
	end
	s:await(Data.ProcessReceipt, Data, receipt("p0"), grant) -- Roblox retries p0
	T.eq(grants.p0, 1, "p0 granted once")
	T.eq(profile.Data.Coins, 101)
end)
