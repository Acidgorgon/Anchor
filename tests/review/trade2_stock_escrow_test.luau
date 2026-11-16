-- Review (held up): a stock ProfileStore 1.0.3 server loads B while B's escrow is open.
-- The stock game runs without the escrowed items (delay), keeps MetaData.Anchor, and the
-- next Anchor load resolves the trade; nothing is lost or duplicated.
local T = require("@mock/testkit")
local Sim = require("@mock/sim")

local TEMPLATE = { Coins = 0, Items = {} }

local function seed(key, data)
	Sim.poke("Main", key, {
		Data = data,
		MetaData = { ProfileCreateTime = Sim.unixTime(), SessionLoadCount = 1, LastUpdate = Sim.unixTime(), MetaTags = {} },
		GlobalUpdates = { 0, {} },
		RobloxMetaData = {},
		UserIds = {},
	})
end

T.test("stock server plays B with an open escrow; the next Anchor load refunds it", function()
	T.allowThreadErrors()
	seed("A", { Coins = 500, Items = {} })
	seed("B", { Coins = 0, Items = { Gem = { Shiny = true } } })
	local s1 = Sim.newServer({ JobId = "S1" })
	local An = s1:require("src", { name = "Anchor" })
	local st = An.New("Main", TEMPLATE)
	local A = s1:await(st.StartSessionAsync, st, "A")
	local B = s1:await(st.StartSessionAsync, st, "B")
	Sim.injectError({
		method = "UpdateAsync",
		store = "AnchorTx",
		when = function(info)
			info.server:crash() -- both escrows landed; dies before the decision
			return true
		end,
	})
	s1:spawn(An.Trade, A, B, function(da, db)
		da.Coins -= 100
		db.Coins += 100
		da.Items.Gem, db.Items.Gem = db.Items.Gem, nil
	end)
	Sim.advance(10)
	Sim.clearInjectedErrors()
	T.expect(not s1.alive)
	T.expect(Sim.peek("Main", "B").MetaData.Anchor.Tx ~= nil, "B's escrow is open")

	local sS = Sim.newServer({ JobId = "Stock" })
	local PS = sS:require("reference/ProfileStore-1.0.3.luau", { name = "ProfileStore" })
	local sst = PS.New("Main", TEMPLATE)
	local Bs = sS:awaitFor(300, sst.StartSessionAsync, sst, "B")
	T.eq(Bs.Data.Items.Gem, nil, "stock session runs without the escrowed gem")
	Bs:Reconcile()
	Bs.Data.Coins += 7
	Bs:EndSession()
	Sim.advance(10)

	local s3 = Sim.newServer({ JobId = "S3" })
	local st3 = s3:require("src", { name = "Anchor" }).New("Main", TEMPLATE)
	local A3 = s3:awaitFor(300, st3.StartSessionAsync, st3, "A")
	local B3 = s3:await(st3.StartSessionAsync, st3, "B")
	Sim.advance(30)
	T.eq(A3.Data.Coins + B3.Data.Coins, 507)
	local gems = (if A3.Data.Items.Gem then 1 else 0) + (if B3.Data.Items.Gem then 1 else 0)
	T.eq(gems, 1)
	T.eq(B3.anchor_meta.Tx, nil)
	T.eq(A3.anchor_meta.Tx, nil)
end)
