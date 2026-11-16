-- [review] Compact saves snapshot Data (the blob) BEFORE the UpdateAsync yield, but read
-- MetaData.Anchor (receipt ledger, trade Tx records), processed-message removal, UserIds
-- and RobloxMetaData LIVE inside the transform. A save that is in flight while game
-- code changes Data + bookkeeping in the same tick writes the new bookkeeping with the
-- OLD Data. Compat is immune (it writes the live Data table inside the transform), so
-- the Compat runs below are the control and pass.
local T = require("@mock/testkit")
local Sim = require("@mock/sim")

local TEMPLATE = { Coins = 0 }
local GRANTED = Sim.Enum.ProductPurchaseDecision.PurchaseGranted

local function receipt(purchaseId, userId)
	return { PurchaseId = purchaseId, PlayerId = userId, ProductId = 1, CurrencySpent = 10 }
end

local function boot(jobId, format)
	local s = Sim.newServer({ JobId = jobId })
	local Data = s:require("src", { name = "Anchor" }).new("Main", TEMPLATE, { Format = format })
	Data:Bind()
	return s, Data
end

for _, format in { "Compat", "Compact" } do
	T.test(`{format}: receipt during an in-flight save + crash -> retried receipt still pays out`, function()
		T.allowThreadErrors()
		Sim.configure({ latency = 1 }) -- commit at +0.5 s, return at +1 s
		local s, Data = boot("S1", format)
		local player = s:addPlayer(1)
		local profile = s:await(Data.Await, Data, player)
		local grants = 0
		local function grant(data)
			grants += 1
			data.Coins += 100
		end

		profile:Save() -- e.g. an autosave / message ping already in flight
		s:spawn(Data.ProcessReceipt, Data, receipt("buy-1", 1), grant)
		Sim.advance(0.75) -- the in-flight save committed; the receipt's own SaveAsync has not
		s:crash()

		local raw = Sim.peek("Main", "Player_1")
		local ledger = raw.MetaData.Anchor and raw.MetaData.Anchor.Receipts
		-- Roblox retries the receipt when the player joins another server:
		local s2, D2 = boot("S2", format)
		Sim.advance(700) -- crashed lock goes stale (ASSUME_DEAD)
		local p2 = s2:addPlayer(1)
		local prof2 = s2:await(D2.Await, D2, p2)
		T.expect(prof2, "loaded")
		local decision = s2:await(D2.ProcessReceipt, D2, receipt("buy-1", 1), grant)
		T.eq(decision, GRANTED)
		T.eq(
			prof2.Data.Coins,
			100,
			`player paid and Roblox was told PurchaseGranted, but the coins are gone (stored ledger {T.show(ledger)}, grants run {grants})`
		)
	end)
end

T.test("Compact: message processed during an in-flight save is removed from the queue without its effect", function()
	T.allowThreadErrors()
	Sim.configure({ latency = 1 })
	local s = Sim.newServer({ JobId = "S1" })
	local store = s:require("src", { name = "Anchor" }).New("Main", TEMPLATE, { Format = "Compact" })
	local profile = s:await(store.StartSessionAsync, store, "Player_1")
	local pending -- the handler finishes its work a moment later (e.g. after a yield)
	profile:MessageHandler(function(message, processed)
		pending = function()
			profile.Data.Coins += message.Gift
			processed()
		end
	end)
	-- a gift arrives from another server
	local s3 = Sim.newServer({ JobId = "S3" })
	local other = s3:require("src", { name = "Anchor" }).New("Main", TEMPLATE, { Format = "Compact" })
	T.eq(s3:await(other.MessageAsync, other, "Player_1", { Gift = 50 }), true)
	Sim.advance(3)
	T.expect(pending, "handler got the gift")
	profile:Save() -- in flight: blob already taken
	pending() -- gift applied + processed() in the same tick, before the transform runs
	Sim.advance(0.75)
	s:crash()
	local raw = Sim.peek("Main", "Player_1")
	local s2 = Sim.newServer({ JobId = "S2" })
	local st2 = s2:require("src", { name = "Anchor" }).New("Main", TEMPLATE, { Format = "Compact" })
	Sim.advance(700)
	local p2 = s2:await(st2.StartSessionAsync, st2, "Player_1")
	local redelivered = false
	p2:MessageHandler(function(_, processed)
		redelivered = true
		processed()
	end)
	T.eq(#raw.GlobalUpdates[2], 0, "message was removed from the stored queue")
	T.expect(p2.Data.Coins == 50 or redelivered, `gift lost: Coins = {p2.Data.Coins} and the message is gone`)
end)

T.test("Compact: two queued saves + an ordinary synchronous message handler lose the gift on crash", function()
	T.allowThreadErrors()
	Sim.configure({ latency = 1, messageDropRate = 1 })
	local s = Sim.newServer({ JobId = "S1" })
	local store = s:require("src", { name = "Anchor" }).New("Main", TEMPLATE, { Format = "Compact" })
	local profile = s:await(store.StartSessionAsync, store, "Player_1")
	profile:MessageHandler(function(message, processed)
		profile.Data.Coins += message.Gift
		processed()
	end)
	local s3 = Sim.newServer({ JobId = "S3" })
	local other = s3:require("src", { name = "Anchor" }).New("Main", TEMPLATE, { Format = "Compact" })
	T.eq(s3:await(other.MessageAsync, other, "Player_1", { Gift = 50 }), true)
	profile:Save() -- X: will pick up the gift and run the handler after it returns
	profile:Save() -- Y: blob taken now (no gift), waits in the update queue behind X
	Sim.advance(1.75) -- X done (handler ran: Coins = 50, processed), Y committed: message removed, old blob
	T.eq(profile.Data.Coins, 50, "gift applied in memory")
	s:crash()
	local s2 = Sim.newServer({ JobId = "S2" })
	local st2 = s2:require("src", { name = "Anchor" }).New("Main", TEMPLATE, { Format = "Compact" })
	Sim.advance(700)
	local p2 = s2:await(st2.StartSessionAsync, st2, "Player_1")
	local redelivered = false
	p2:MessageHandler(function(m, processed)
		redelivered = true
		p2.Data.Coins += m.Gift
		processed()
	end)
	T.eq(p2.Data.Coins, 50, `gift lost (redelivered = {redelivered})`)
end)

for _, format in { "Compat", "Compact" } do
	T.test(`{format}: trade while A has a save in flight + crash -> no duplicated item`, function()
		T.allowThreadErrors()
		Sim.configure({ latency = 1 })
		local TT = { Coins = 0, Items = {} }
		local s = Sim.newServer({ JobId = "S1" })
		local A = s:require("src", { name = "Anchor" })
		local store = A.New("Main", TT, { Format = format })
		local pa = s:await(store.StartSessionAsync, store, "Player_1")
		local pb = s:await(store.StartSessionAsync, store, "Player_2")
		pa.Data.Items.Gem = { Shiny = true }
		pb.Data.Coins = 100
		T.eq(s:await(pa.SaveAsync, pa), true)
		T.eq(s:await(pb.SaveAsync, pb), true)

		pa:Save() -- autosave-like save of A already in flight (blob without the trade)
		s:spawn(A.Trade, pa, pb, function(da, db)
			da.Items.Gem, db.Items.Gem = nil, da.Items.Gem
			da.Coins += 100
			db.Coins -= 100
		end)
		Sim.advance(0.75) -- the in-flight save of A committed; A's own intent save has not
		s:crash()

		-- both players come back on another server; recovery runs
		local s2 = Sim.newServer({ JobId = "S2" })
		local st2 = s2:require("src", { name = "Anchor" }).New("Main", TT, { Format = format })
		Sim.advance(700)
		local a2 = s2:await(st2.StartSessionAsync, st2, "Player_1")
		Sim.advance(30)
		local b2 = s2:await(st2.StartSessionAsync, st2, "Player_2")
		Sim.advance(60)
		local gems = (if a2.Data.Items.Gem then 1 else 0) + (if b2.Data.Items.Gem then 1 else 0)
		local coins = a2.Data.Coins + b2.Data.Coins
		T.eq(gems, 1, `gem count after recovery (A={T.show(a2.Data)}, B={T.show(b2.Data)})`)
		T.eq(coins, 100, "coin total")
	end)
end
