-- Anchor core under stress: random handoffs between servers (Anchor Compat, Anchor
-- Compact, stock ProfileStore) with write conflicts, latency, injected DataStore and
-- MessagingService errors. Every change made while a server owned the profile must
-- survive the handoff (release saves retry until they land).
local T = require("@mock/testkit")
local Sim = require("@mock/sim")

local STOCK = "reference/ProfileStore-1.0.3.luau"
local TEMPLATE = { Coins = 0, Log = {} }

-- mode "release": the owner ends its session (player left), then the next server loads
--   right away (usually while the release is still in flight). Nothing may be lost.
-- mode "contest": the next server loads while the owner keeps the session (PS_ request,
--   or a steal after SESSION_STEAL when messages drop). Like stock, changes the owner had
--   not saved before a steal can be lost; what loads must still be a consistent state.
local function run(kinds, seed, steps, mode)
	Sim.reset({
		seed = seed,
		conflictRate = 0.3,
		latency = { 0.05, 1.5 },
		messageDropRate = 0.2,
	})
	Sim.injectError({ method = "UpdateAsync", rate = 0.15 })
	Sim.injectError({ method = "UpdateAsync", rate = 0.05, phase = "after" })
	local servers = {}
	for i, kind in kinds do
		local s = Sim.newServer({ JobId = `{kind}{i}` })
		local lib
		local store
		if kind == "stock" then
			lib = s:require(STOCK, { name = "ProfileStore" })
			store = lib.New("PlayerData", TEMPLATE)
		else
			lib = s:require("src", { name = "Anchor" })
			store = lib.New("PlayerData", TEMPLATE, { Format = kind })
		end
		lib.SetConstant("AUTO_SAVE_PERIOD", 15)
		servers[i] = { s = s, store = store, kind = kind }
	end
	local rng = Sim.Roblox.newRandom(seed)
	local owner = nil
	local history = {}
	local lost = 0
	for step = 1, steps do
		local srv = servers[rng:NextInteger(1, #servers)]
		if mode == "release" and owner ~= nil and owner.srv == srv and srv.kind == "stock" then
			-- stock's own same-server reload bug (fixed in Anchor) is not under test here
			srv = servers[(table.find(servers, srv) :: number) % #servers + 1]
		end
		if owner ~= nil and (mode == "release" or owner.srv == srv) then
			owner.profile:EndSession()
			if mode == "contest" then
				Sim.advance(rng:NextNumber() * 3)
			end
		end
		if srv.profile ~= nil and srv.profile:IsActive() then
			-- The player left this server long ago; it may not have noticed the steal yet.
			srv.profile:EndSession()
		end
		local profile = srv.s:await(srv.store.StartSessionAsync, srv.store, "Player_1")
		srv.profile = profile
		T.expect(profile, `step {step}: {srv.kind} failed to load`)
		local data = profile.Data
		T.eq(data.Coins, #data.Log, `step {step}: Coins and Log disagree`)
		for i, entry in data.Log do
			T.eq(entry, history[i], `step {step}: log entry {i}`)
		end
		if mode == "release" then
			T.eq(#data.Log, #history, `step {step}: {srv.kind} loaded stale data (same server: {tostring(owner ~= nil and owner.srv == srv)})`)
		else
			lost += #history - #data.Log
			table.move(data.Log, 1, #data.Log, 1, table.create(0))
			for i = #history, #data.Log + 1, -1 do
				history[i] = nil
			end
		end
		data.Coins += 1
		local entry = `{srv.kind}:{step}`
		table.insert(data.Log, entry)
		table.insert(history, entry)
		owner = { srv = srv, profile = profile }
		Sim.advance(rng:NextNumber() * 40)
	end
	owner.profile:EndSession()
	Sim.clearInjectedErrors()
	Sim.advance(60)
	local raw = Sim.peek("PlayerData", "Player_1")
	T.eq(raw.MetaData.ActiveSession, nil)
	-- read back with a fresh Anchor server (handles either format)
	local reader = Sim.newServer({ JobId = "reader" })
	local st = reader:require("src", { name = "Anchor" }).New("PlayerData", TEMPLATE)
	local view = reader:await(st.GetAsync, st, "Player_1")
	T.deepEq(view.Data.Log, history)
	T.eq(view.Data.Coins, #history)
	return lost
end

local FLEETS = {
	{ "mixed stock + Anchor Compat", { "Compat", "stock", "Compat", "stock" } },
	{ "Anchor Compact + Compat writers", { "Compact", "Compat", "Compact" } },
	-- Stock alone loses data in "release" mode (same-server quick reload while its release
	-- save is retrying, see StartSessionAsync in src/Core.luau); only the contested runs apply.
	{ "stock only (reference)", { "stock", "stock", "stock" }, true },
}

for _, fleet in FLEETS do
	for seed = 1, 4 do
		local test = if fleet[3] then T.skip else T.test
		test(`release handoffs lose nothing: {fleet[1]}, seed {seed}`, function()
			T.allowThreadErrors() -- injected errors surface in stock's unprotected PublishAsync spawns
			run(fleet[2], seed, 30, "release")
		end)
		T.test(`contested handoffs load consistent data: {fleet[1]}, seed {seed}`, function()
			T.allowThreadErrors()
			run(fleet[2], 50 + seed, 30, "contest")
		end)
	end
end
