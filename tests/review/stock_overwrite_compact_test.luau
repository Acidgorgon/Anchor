-- [review] Spec 1.4: a Compact profile must never be loadable OR overwritable by stock.
-- Stock's view-mode overwrite (store:GetAsync(key) -> edit -> profile:SetAsync(), the
-- documented admin/ban-tool pattern) does not touch SessionLoadCount, so the poison
-- survives, but it writes Data = { AnchorBlob = <blob>, ...edits }. Envelope.isCompactData
-- then requires "exactly one key", so Anchor reads that table as PLAIN data: the player's
-- real data (inside the blob) is ignored and the next save writes the template over it.
local T = require("@mock/testkit")
local Sim = require("@mock/sim")

local TEMPLATE = { Coins = 0, Items = {} }

T.test("stock admin GetAsync + Reconcile/edit + SetAsync on a Compact profile wipes the player's data", function()
	-- 1. An Anchor Compact server saves a real profile.
	local sA = Sim.newServer({ JobId = "COMPACT" })
	local A = sA:require("src", { name = "Anchor" })
	local store = A.New("PlayerData", TEMPLATE, { Format = "Compact" })
	local p = sA:await(store.StartSessionAsync, store, "Player_1")
	p.Data.Coins = 5000
	p.Data.Items = { "Legendary Sword" }
	p:EndSession()
	Sim.advance(2)
	T.eq(Sim.peek("PlayerData", "Player_1").MetaData.SessionLoadCount, "Anchor")

	-- 2. A stock server / admin tool flags the player (view-mode overwrite).
	local sS = Sim.newServer({ JobId = "STOCK-ADMIN" })
	local PS = sS:require("reference/ProfileStore-1.0.3.luau", { name = "ProfileStore" })
	local stockStore = PS.New("PlayerData", TEMPLATE)
	local view = sS:await(stockStore.GetAsync, stockStore, "Player_1")
	T.expect(view, "stock can view it")
	view:Reconcile()
	view.Data.Flagged = true
	sS:await(view.SetAsync, view)
	local raw = Sim.peek("PlayerData", "Player_1")
	T.eq(raw.MetaData.SessionLoadCount, "Anchor", "poison survives the stock overwrite")

	-- 3. Anchor loads the profile again.
	local p2 = sA:await(store.StartSessionAsync, store, "Player_1")
	T.expect(p2, "Anchor loads it")
	T.eq(p2.Data.Coins, 5000, `player's data replaced by the stock-written table: {T.show(p2.Data)}`)
end)
