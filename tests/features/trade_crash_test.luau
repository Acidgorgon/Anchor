-- Trades under crashes (escrow + decision key): every DataStore write of the protocol is replayed with the
-- writing server crashing right BEFORE the write commits and right AFTER it commits (the
-- server dies before it sees the result). Then both profiles are loaded on fresh servers
-- (both orders) and must be in exactly one of two states: the trade never happened, or it
-- happened exactly once. No dupes, no losses, for items (map + array) and currency.
local T = require("@mock/testkit")
local Sim = require("@mock/sim")

local TEMPLATE = { Coins = 0, Items = {}, Bag = {} }

local BEFORE = {
	A = { Coins = 500, Items = { Sword = { Level = 3 } }, Bag = { "apple", "kiwi" } },
	B = { Coins = 50, Items = { Gem = { Shiny = true } }, Bag = { "pear" } },
}
local AFTER = {
	A = { Coins = 400, Items = { Gem = { Shiny = true } }, Bag = { "kiwi", "pear" } },
	B = { Coins = 150, Items = { Sword = { Level = 3 } }, Bag = { "apple" } },
}

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

local function deepCopy(t)
	if type(t) ~= "table" then
		return t
	end
	local c = {}
	for k, v in t do
		c[k] = deepCopy(v)
	end
	return c
end

local function swap(da, db)
	if da.Coins < 100 or db.Items.Gem == nil then
		return false
	end
	da.Coins -= 100
	db.Coins += 100
	da.Items.Gem, db.Items.Gem = db.Items.Gem, nil
	db.Items.Sword, da.Items.Sword = da.Items.Sword, nil
	table.remove(da.Bag, table.find(da.Bag, "apple"))
	table.insert(db.Bag, "apple")
	table.remove(db.Bag, table.find(db.Bag, "pear"))
	table.insert(da.Bag, "pear")
end

local function norm(data)
	local d = deepCopy(data)
	table.sort(d.Bag)
	return { Coins = d.Coins, Items = d.Items, Bag = d.Bag }
end

-- Arms a crash on the n-th UpdateAsync after arming. Returns control table.
local function crashPlan(n, phase)
	local plan = { armed = false, count = 0, crashed = nil, calls = {} }
	Sim.injectError({
		method = "UpdateAsync",
		phase = "before",
		when = function(info)
			if not plan.armed then
				return false
			end
			plan.count += 1
			table.insert(plan.calls, `{info.server.name}:{info.key}`)
			if n ~= nil and plan.count == n then
				plan.crashed = info.server.name
				info.server:crash()
				return phase == "before" -- before: the write never commits; after: it commits
			end
			return false
		end,
	})
	return plan
end

----- Scenarios (each runs the trade and lets it settle; servers may crash) -----

local scenarios = {}

-- A and B on one server.
scenarios.sameServer = function(plan)
	local s1 = Sim.newServer({ JobId = "S1" })
	local Anchor = anchor(s1)
	local store = Anchor.New("Main", TEMPLATE)
	local A = s1:await(store.StartSessionAsync, store, "A")
	local B = s1:await(store.StartSessionAsync, store, "B")
	plan.armed = true
	s1:spawn(Anchor.Trade, A, B, swap)
	Sim.advance(30)
	plan.armed = false
end

-- B leaves mid-trade and joins S2: B's side travels as a message.
scenarios.bLeaves = function(plan)
	local s1 = Sim.newServer({ JobId = "S1" })
	local s2 = Sim.newServer({ JobId = "S2" })
	local Anchor = anchor(s1)
	local store = Anchor.New("Main", TEMPLATE)
	local st2 = anchor(s2).New("Main", TEMPLATE)
	local A = s1:await(store.StartSessionAsync, store, "A")
	local B = s1:await(store.StartSessionAsync, store, "B")
	plan.armed = true
	s1:spawn(Anchor.Trade, A, B, swap)
	Sim.advance(0.05)
	if s1.alive then
		B:EndSession()
	end
	Sim.advance(3)
	if s2.alive then
		s2:spawn(st2.StartSessionAsync, st2, "B")
	end
	Sim.advance(60)
	plan.armed = false
end

-- S1 dies right after the commit decision landed (neither side applied it); B loads on
-- S2, then A loads on S3: every write of that recovery is crashed in turn.
scenarios.recovery = function(plan)
	local s1 = Sim.newServer({ JobId = "S1" })
	local Anchor = anchor(s1)
	local store = Anchor.New("Main", TEMPLATE)
	local A = s1:await(store.StartSessionAsync, store, "A")
	local B = s1:await(store.StartSessionAsync, store, "B")
	local first = true
	local rule = Sim.injectError({
		method = "UpdateAsync",
		store = "AnchorTx",
		when = function(info)
			if first then
				first = false
				info.server:crash() -- after the decision commits
			end
			return false
		end,
	})
	s1:spawn(Anchor.Trade, A, B, swap)
	Sim.advance(5)
	rule:remove()
	assert(not s1.alive)
	plan.armed = true
	local s2 = Sim.newServer({ JobId = "S2" })
	local st2 = anchor(s2).New("Main", TEMPLATE)
	local job = s2:spawn(st2.StartSessionAsync, st2, "B")
	Sim.runUntil(function()
		return job.done or not s2.alive
	end, 120)
	Sim.advance(10)
	local s3 = Sim.newServer({ JobId = "S3" })
	local st3 = anchor(s3).New("Main", TEMPLATE)
	s3:spawn(st3.StartSessionAsync, st3, "A")
	Sim.advance(120)
	plan.armed = false
end

----- Verification -----

local function settleAndRead(order)
	local r1 = Sim.newServer({ JobId = "R1" })
	local st = anchor(r1).New("Main", TEMPLATE)
	local loaded = {}
	for _, key in order do
		loaded[key] = r1:awaitFor(300, st.StartSessionAsync, st, key)
		assert(loaded[key], "recovery load of " .. key)
	end
	Sim.advance(60)
	for _, p in loaded do
		p:EndSession()
	end
	Sim.advance(10)
	-- Load once more: anything still queued is applied at load.
	local r2 = Sim.newServer({ JobId = "R2" })
	local st2 = anchor(r2).New("Main", TEMPLATE)
	local final = {}
	for _, key in order do
		final[key] = r2:awaitFor(300, st2.StartSessionAsync, st2, key)
	end
	Sim.advance(30)
	local out = { A = norm(final.A.Data), B = norm(final.B.Data) }
	out.txLeft = final.A.anchor_meta.Tx
	for _, p in final do
		p:EndSession()
	end
	Sim.advance(10)
	out.queueA = #Sim.peek("Main", "A").GlobalUpdates[2]
	out.queueB = #Sim.peek("Main", "B").GlobalUpdates[2]
	return out
end

local function classify(result)
	if T.diff(result.A, norm(BEFORE.A)) == nil and T.diff(result.B, norm(BEFORE.B)) == nil then
		return "not traded"
	end
	if T.diff(result.A, norm(AFTER.A)) == nil and T.diff(result.B, norm(AFTER.B)) == nil then
		return "traded once"
	end
	return nil
end

local function runOnce(name, n, phase, order)
	Sim.reset()
	seed("A", deepCopy(BEFORE.A))
	seed("B", deepCopy(BEFORE.B))
	local plan = crashPlan(n, phase)
	scenarios[name](plan)
	Sim.clearInjectedErrors()
	Sim.advance(1)
	local result = settleAndRead(order)
	return result, plan
end

local function exhaustive(name)
	-- dry run to list the protocol's writes
	local dry, dryPlan = runOnce(name, nil, nil, { "A", "B" })
	T.eq(classify(dry), "traded once", `{name}: no crash must trade ({T.show(dry)})`)
	local total = dryPlan.count
	T.expect(total >= 3, `{name}: expected at least 3 writes, saw {total}`)
	local outcomes = {}
	for n = 1, total do
		for _, phase in { "before", "after" } do
			for _, order in { { "A", "B" }, { "B", "A" } } do
				local result, plan = runOnce(name, n, phase, order)
				local kind = classify(result)
				local label = `{name} crash {phase} write {n}/{total} ({plan.calls[n] or "?"}), reload {order[1]} first`
				if kind == nil then
					error(`{label}: DUPE/LOSS {T.show(result.A)} / {T.show(result.B)}`, 0)
				end
				T.eq(result.txLeft, nil, label .. ": A's tx record left behind")
				T.eq(result.queueB, 0, label .. ": B's queue not drained")
				outcomes[kind] = (outcomes[kind] or 0) + 1
			end
		end
	end
	return outcomes, total, dryPlan.calls
end

T.test("crash before/after every write: A and B on one server", function()
	T.allowThreadErrors()
	local outcomes, total, calls = exhaustive("sameServer")
	print(`    sameServer: {total} writes [{table.concat(calls, ", ")}] -> {T.show(outcomes)}`)
	T.expect((outcomes["not traded"] or 0) > 0 and (outcomes["traded once"] or 0) > 0)
end)

T.test("crash before/after every write: B leaves mid-trade and loads on another server", function()
	T.allowThreadErrors()
	local outcomes, total, calls = exhaustive("bLeaves")
	print(`    bLeaves: {total} writes [{table.concat(calls, ", ")}] -> {T.show(outcomes)}`)
end)

T.test("crash before/after every write of recovery (A's new server and B's server)", function()
	T.allowThreadErrors()
	local outcomes, total, calls = exhaustive("recovery")
	print(`    recovery: {total} writes [{table.concat(calls, ", ")}] -> {T.show(outcomes)}`)
	T.eq(outcomes["not traded"], nil, "the intent had landed: every path must complete the trade")
end)
