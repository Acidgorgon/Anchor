-- Review of the escrow protocol: Patch.split puts every "Set" in INCOMING. A Set that
-- overwrites an existing value (slot inventories {Slot1 = "Sword"}, a single Pet field,
-- an equipped item...) is therefore never escrowed: the giver keeps the item until the
-- decision. When the decision is delayed ("Pending", decision key unreachable) the giver
-- can sell/trade it, and the later commit hands it to the other side as well.
-- Also: a refund/incoming "Set" onto a key that was refilled meanwhile overwrites it.
-- (Two assertions were adjusted after the fix; see the "Adjusted" comments.)
local T = require("@mock/testkit")
local Sim = require("@mock/sim")

local TEMPLATE = { Coins = 0, Slots = {}, Items = {} }

local function anchor(server)
	return server:require("src", { name = "Anchor" })
end

local function seed(key, data)
	Sim.poke("Main", key, {
		Data = data,
		MetaData = { ProfileCreateTime = Sim.unixTime(), SessionLoadCount = 1, LastUpdate = Sim.unixTime(), MetaTags = {} },
		GlobalUpdates = { 0, {} },
		RobloxMetaData = {},
		UserIds = {},
	})
end

local function setup(a, b, onError)
	seed("A", a)
	seed("B", b)
	local s = Sim.newServer({ JobId = "S1" })
	local An = anchor(s)
	if onError ~= nil then
		An.OnError:Connect(onError)
	end
	local st = An.New("Main", TEMPLATE)
	local A = s:await(st.StartSessionAsync, st, "A")
	local B = s:await(st.StartSessionAsync, st, "B")
	return s, An, st, A, B
end

T.test("slot swap goes Pending; A sells its (unescrowed) sword; commit gives B the sword too", function()
	local s, An, _, A, B = setup(
		{ Coins = 0, Slots = { S1 = "Sword" }, Items = {} },
		{ Coins = 0, Slots = { S1 = "Gem" }, Items = {} }
	)
	local rule = Sim.injectError({ method = "UpdateAsync", store = "AnchorTx" })
	local ok, why = s:await(An.Trade, A, B, function(da, db)
		da.Slots.S1, db.Slots.S1 = db.Slots.S1, da.Slots.S1
	end)
	T.eq(ok, false)
	T.eq(why, "Pending")
	-- Adjusted after the fix: an overwritten Set is escrowed (outgoing Remove), so the Sword
	-- is gone from A while pending and can't be sold.
	T.eq(A.Data.Slots.S1, nil, "the overwritten Sword is escrowed while pending")
	-- A sells the sword to the shop for 500 coins if it still has it (ordinary game write)
	if A.Data.Slots.S1 == "Sword" then
		A.Data.Slots.S1 = nil
		A.Data.Coins += 500
	end
	rule:remove()
	Sim.advance(300)
	A:EndSession()
	B:EndSession()
	Sim.advance(10)
	local a, b = Sim.peek("Main", "A").Data, Sim.peek("Main", "B").Data
	print(`    A={T.show(a)} B={T.show(b)}`)
	local swords = (if a.Slots.S1 == "Sword" then 1 else 0) + (if b.Slots.S1 == "Sword" then 1 else 0)
	T.eq(swords + (if a.Coins >= 500 then 1 else 0), 1, "the sword was either sold or traded, not both")
end)

T.test("abort refund Set overwrites an item the player obtained while the trade was pending", function()
	local errors = {}
	local s, An, st, A, B = setup(
		{ Coins = 0, Slots = {}, Items = { Sword = { Level = 9 } } },
		{ Coins = 100, Slots = {}, Items = {} },
		function(m)
			table.insert(errors, m)
		end
	)
	-- B's escrow save fails both tries -> abort, and the decision key is down -> Pending.
	local r1 = Sim.injectError({ method = "UpdateAsync", store = "Main", key = "B", count = 2 })
	local r2 = Sim.injectError({ method = "UpdateAsync", store = "AnchorTx" })
	local ok, why = s:await(An.Trade, A, B, function(da, db)
		db.Items.Sword, da.Items.Sword = da.Items.Sword, nil
		da.Coins += 100
		db.Coins -= 100
	end)
	T.eq(ok, false)
	T.eq(why, "Pending")
	T.eq(A.Data.Items.Sword, nil, "escrowed")
	-- meanwhile A finds a new (weaker) sword in the world
	A.Data.Items.Sword = { Level = 1 }
	r1:remove()
	r2:remove()
	Sim.advance(300)
	print(`    A={T.show(A.Data)}`)
	-- Refund restores the Level 9 sword; the Level 1 one A found must not vanish.
	local n = 0
	for _, v in A.Data.Items do
		if type(v) == "table" and v.Level ~= nil then
			n += 1
		end
	end
	-- Adjusted after the fix: a refund Set onto a different, non-nil value never overwrites.
	-- Both swords can't live at Items.Sword, so the found one stays in Data and the Level 9
	-- one stays held in the kept trade record (NEEDS MANUAL REVIEW): neither is lost.
	T.eq(A.Data.Items.Sword and A.Data.Items.Sword.Level, 1, "the found sword is not overwritten")
	T.eq(n, 1)
	local pending = st:PendingTrades(A)
	T.eq(#pending, 1, "the record is kept")
	T.eq(pending[1].Status, "NeedsReview")
	local held = 0
	for _, op in pending[1].Refund do
		if op[1] == "Set" and type(op[3]) == "table" and op[3].Level == 9 then
			held += 1
		end
	end
	T.eq(held, 1, "the Level 9 sword is still held in the record's refund")
	local flagged = false
	for _, m in errors do
		flagged = flagged or string.find(m, "NEEDS MANUAL REVIEW", 1, true) ~= nil
	end
	T.expect(flagged, "OnError says NEEDS MANUAL REVIEW")
end)
