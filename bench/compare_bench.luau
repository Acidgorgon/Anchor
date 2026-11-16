--!optimize 2
-- Anchor vs stock ProfileStore 1.0.3, end to end on the Roblox mock.
--
--   bench/run_compare.sh            (native + interpreted, writes bench/results/compare/)
--   COMPARE_ONLY=load,save bench/run_compare.sh   sections: load,save,memory,size,calls,server
--   COMPARE_RUNS=7 (default)        runs per timing (median reported)
--
-- Libraries: stock = reference/ProfileStore-1.0.3.luau, Anchor-Compat and
-- Anchor-Compact = src with { Format = ... }. Same stock API calls for all three.
--
-- What "library Luau CPU" means here (all real host time, not virtual time):
--   measured time of the operation
--   - time inside the mock's JSON encode/decode (Roblox does JSON + base64 in C++;
--     the mock does it in Luau, so it is metered and removed)
--   - mock DataStore plumbing per call (scheduler, coroutines, KeyInfo), calibrated
--     with a raw UpdateAsync whose transform returns its input unchanged
-- Allocations use the same subtraction (__alloc_bytes is cumulative, GC does not
-- reduce it). Tables Roblox's C++ JSON decoder creates do land in the Luau heap on
-- Roblox but are excluded here (they are the same size for stock and Compat).
-- The incremental GC is stopped for the whole bench and full collections run only
-- between timed regions, so CPU numbers exclude GC work (otherwise the mock JSON
-- parser's garbage gets collected inside whatever runs next). GC cost scales with
-- the alloc columns.

local Bench = require("@bench/harness")
local Sim = require("@mock/sim")
local JSON = require("@mock/json")

local clock = os.clock
local STOCK = "reference/ProfileStore-1.0.3.luau"
local RUNS = tonumber(getenv("COMPARE_RUNS") or "") or 7
local ONLY = getenv("COMPARE_ONLY") or ""
local RESULTS = getenv("ANCHOR_BENCH_RESULTS") or (Sim.root .. "/bench/results/compare")
local MODE = if __native() then "native" else "interp"

local function want(section: string): boolean
	return ONLY == "" or string.find("," .. ONLY .. ",", "," .. section .. ",", 1, true) ~= nil
end

local LIBS = {
	{ name = "stock" },
	{ name = "Anchor-Compat", format = "Compat" },
	{ name = "Anchor-Compact", format = "Compact" },
}

--------------------------------------------------------------------------------
-- Mock JSON metering (Roblox: C++)
--------------------------------------------------------------------------------

local J = { time = 0, alloc = 0, depth = 0 }
do
	local enc, dec = JSON.encode, JSON.decode
	local function metered(f)
		return function(v)
			if J.depth > 0 then
				return f(v)
			end
			J.depth = 1
			local a0 = __alloc_bytes()
			local t0 = clock()
			local ok, r = pcall(f, v)
			J.time += clock() - t0
			J.alloc += __alloc_bytes() - a0
			J.depth = 0
			if not ok then
				error(r, 0)
			end
			return r
		end
	end
	JSON.encode = metered(enc)
	JSON.decode = metered(dec)
end

local GC_LIMIT = 768 * 1024 * 1024
local function collect()
	__gc("collect")
	__gc("collect")
	__gc("stop")
end
local function maybeCollect()
	if __live_bytes() > GC_LIMIT then
		collect()
	end
end
collect()

-- Runs fn and returns (seconds, bytes) with mock JSON removed.
local function meter(fn: () -> ()): (number, number)
	local jt, ja = J.time, J.alloc
	local a0 = __alloc_bytes()
	local t0 = clock()
	fn()
	local dt = clock() - t0
	local da = __alloc_bytes() - a0
	return dt - (J.time - jt), da - (J.alloc - ja)
end

local function median(xs)
	local s = table.clone(xs)
	table.sort(s)
	local n = #s
	if n == 0 then
		return 0
	end
	return if n % 2 == 1 then s[(n + 1) // 2] else (s[n // 2] + s[n // 2 + 1]) / 2
end

--------------------------------------------------------------------------------
-- Datasets (deterministic)
--------------------------------------------------------------------------------

local function prng(seed: number)
	local state = seed
	local function rnd(): number
		local x = state
		x = bit32.bxor(x, bit32.lshift(x, 13))
		x = bit32.bxor(x, bit32.rshift(x, 17))
		x = bit32.bxor(x, bit32.lshift(x, 5))
		state = x
		return x
	end
	local function rint(lo: number, hi: number): number
		return lo + rnd() % (hi - lo + 1)
	end
	return rnd, rint
end

local RARITIES = { "Common", "Uncommon", "Rare", "Epic", "Legendary", "Icon" }
local POSITIONS = { "GK", "CB", "LB", "RB", "CDM", "CM", "CAM", "LW", "RW", "ST" }
local NATIONS = { "ENG", "ESP", "FRA", "GER", "BRA", "ARG", "POR", "NED", "ITA", "BEL", "USA", "JPN" }

local function makeSmall(seed: number)
	local rnd, rint = prng(20261116 + seed * 7919)
	return {
		Coins = rint(0, 50000),
		Gems = rint(0, 500),
		Level = rint(1, 80),
		Xp = rint(0, 99999),
		Rebirths = rint(0, 5),
		PlayTime = rint(0, 500000),
		LastLogin = 1763251200 - rint(0, 86400),
		FirstJoin = 1731715200 + rint(0, 86400 * 30),
		DailyStreak = rint(0, 30),
		Tutorial = rnd() % 2 == 0,
		Banned = false,
		Title = "Rookie",
		EquippedPet = "Dragon",
		Multiplier = rint(10, 30) / 10,
		Settings = { Music = true, Sfx = 0.8, Shadows = false, Language = "en" },
		Inventory = { "Sword", "Shield", "Potion", "Potion", "Bow" },
		Pets = { { Name = "Dragon", Level = rint(1, 9) }, { Name = "Cat", Level = rint(1, 9) } },
		Quests = { Q1 = true, Q2 = false, Q3 = 0.25 },
		Codes = { "WELCOME", "SUMMER" },
		Stats = { Kills = rint(0, 9999), Deaths = rint(0, 9999), Wins = rint(0, 999) },
	}
end

local function makeCard(rnd, rint)
	local attrs = table.create(6)
	for i = 1, 6 do
		attrs[i] = rint(30, 99)
	end
	return {
		Id = rint(1, 4000),
		Level = rint(1, 99),
		Xp = rint(0, 250000),
		Rating = rint(400, 990) / 10, -- 73.4: not an integer, not f32-exact
		Potential = rint(400, 990) / 10,
		Rarity = RARITIES[rint(1, #RARITIES)],
		Position = POSITIONS[rint(1, #POSITIONS)],
		Locked = rnd() % 4 == 0,
		Favorite = rnd() % 10 == 0,
		Attrs = attrs,
	}
end

local function makeFm(seed: number)
	local rnd, rint = prng(4242 + seed * 104729)
	local owned = {}
	local keys = {}
	local nextId = 1
	for _ = 1, 670 do
		nextId += rint(1, 7)
		local k = "i" .. nextId
		owned[k] = makeCard(rnd, rint)
		table.insert(keys, k)
	end
	local squad = table.create(11)
	for i = 1, 11 do
		squad[i] = keys[rint(1, #keys)]
	end
	local subs = table.create(7)
	for i = 1, 7 do
		subs[i] = keys[rint(1, #keys)]
	end
	local achievements = {}
	for i = 1, 24 do
		achievements[i] = "ach_" .. rint(1, 200)
	end
	return {
		Owned = owned,
		Cash = rint(0, 5000000),
		Gems = rint(0, 20000),
		Level = rint(1, 120),
		Xp = rint(0, 9999999),
		Stats = {
			Matches = rint(0, 5000),
			Wins = rint(0, 3000),
			Draws = rint(0, 1000),
			Losses = rint(0, 1000),
			Goals = rint(0, 15000),
			PacksOpened = rint(0, 2000),
			BestRating = rint(600, 990) / 10,
		},
		Settings = { Music = true, Sfx = 0.75, Quality = "High", Language = "en", Camera = "Broadcast" },
		Squad = squad,
		Subs = subs,
		Formation = "4-3-3",
		Achievements = achievements,
		Packs = { Gold = rint(0, 20), Silver = rint(0, 40), Bronze = rint(0, 80) },
		DailyStreak = rint(0, 60),
		LastLogin = 1763251200 - rint(0, 86400),
		Version = 7,
		NextId = nextId + 1,
	}
end

local TEMPLATES = {
	small = {
		Coins = 0, Gems = 0, Level = 1, Xp = 0, Rebirths = 0, PlayTime = 0, LastLogin = 0, FirstJoin = 0,
		DailyStreak = 0, Tutorial = false, Banned = false, Title = "", EquippedPet = "", Multiplier = 1,
		Settings = { Music = true, Sfx = 1, Shadows = true, Language = "en" }, Inventory = {}, Pets = {},
		Quests = {}, Codes = {}, Stats = { Kills = 0, Deaths = 0, Wins = 0 },
	},
	fm = {
		Owned = {}, Cash = 0, Gems = 0, Level = 1, Xp = 0,
		Stats = { Matches = 0, Wins = 0, Draws = 0, Losses = 0, Goals = 0, PacksOpened = 0, BestRating = 0 },
		Settings = { Music = true, Sfx = 1, Quality = "High", Language = "en", Camera = "Broadcast" },
		Squad = {}, Subs = {}, Formation = "4-3-3", Achievements = {}, Packs = { Gold = 0, Silver = 0, Bronze = 0 },
		DailyStreak = 0, LastLogin = 0, Version = 7, NextId = 1,
	},
}
local MAKERS = { small = makeSmall, fm = makeFm }
local DATASETS = { "small", "fm" }

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

local function fillInPlace(target, source)
	table.clear(target)
	for k, v in deepCopy(source) do
		target[k] = v
	end
end

-- A gameplay edit (the kind of change a player makes in a minute).
local function edit(dataset: string, data, rnd, rint)
	if dataset == "small" then
		data.Coins += rint(1, 100)
		data.Xp += rint(1, 50)
		if rnd() % 5 == 0 then
			table.insert(data.Inventory, "Potion")
		end
		data.Stats.Kills += 1
		return
	end
	data.Cash += rint(10, 5000)
	data.Xp += rint(1, 500)
	data.Stats.Matches += 1
	local owned = data.Owned
	local r = rnd() % 10
	if r < 2 then
		data.NextId += 1
		owned["i" .. data.NextId] = makeCard(rnd, rint)
	elseif r < 3 then
		local k = next(owned)
		if k then
			owned[k] = nil
		end
	else
		local k = data.Squad[rint(1, #data.Squad)]
		local card = owned[k]
		if card then
			card.Xp += rint(10, 1000)
			card.Level = math.min(99, card.Level + 1)
			card.Favorite = not card.Favorite
		end
	end
end

--------------------------------------------------------------------------------
-- World helpers
--------------------------------------------------------------------------------

local function newWorld(seed: number?, extra)
	local opts = { seed = seed or 1, latency = 0, maxVersions = 1 }
	for k, v in extra or {} do
		opts[k] = v
	end
	Sim.reset(opts)
end

local function boot(server, lib, storeName: string, template, opts)
	opts = opts or {}
	local L, store
	if lib.format == nil then
		L = server:require(STOCK, { name = "ProfileStore" })
		if opts.period then
			L.SetConstant("AUTO_SAVE_PERIOD", opts.period)
		end
		store = L.New(storeName, template)
	else
		L = server:require("src", { name = "Anchor" })
		if opts.period then
			L.SetConstant("AUTO_SAVE_PERIOD", opts.period)
		end
		local o = { Format = lib.format }
		for k, v in opts.anchor or {} do
			o[k] = v
		end
		store = L.New(storeName, template, o)
	end
	return L, store
end

-- Loads key with the library, puts `data` in it, releases; returns when stored.
local function seedProfile(server, store, key: string, data)
	local p = server:await(store.StartSessionAsync, store, key)
	assert(p, "seed load failed")
	fillInPlace(p.Data, data)
	p:EndSession()
	Sim.advance(0.5)
	local raw = Sim.peek(store.Name, key)
	assert(raw and raw.MetaData.ActiveSession == nil, "seed release did not land")
end

local function calls(server)
	local n = 0
	for _, v in server.stats.calls do
		n += v
	end
	return n
end

-- Mock cost of one UpdateAsync (scheduler, await, KeyInfo, validation) on a stored
-- envelope holding `data`, JSON removed, measured in its own world on a server that
-- runs no library (latency 0: the await steps ~2 frames). Median of 41.
local CALIB = {}
local function calibrateCall(ds: string, data)
	if CALIB[ds] then
		return CALIB[ds][1], CALIB[ds][2], CALIB[ds][3]
	end
	newWorld(1)
	local s = Sim.newServer({ JobId = "calib" })
	Sim.poke("Calib", "K", {
		Data = data,
		MetaData = { ProfileCreateTime = 0, SessionLoadCount = 1, LastUpdate = 0, MetaTags = {} },
		RobloxMetaData = {},
		UserIds = {},
		GlobalUpdates = { 0, {} },
	})
	local store = s.DataStoreService:GetDataStore("Calib")
	local frames = 0
	local function once()
		local f0 = Sim.frame()
		s:await(function()
			return store:UpdateAsync("K", function(v)
				return v
			end)
		end)
		frames = Sim.frame() - f0
	end
	once()
	local ts, as = {}, {}
	for i = 1, 41 do
		ts[i], as[i] = meter(once)
		maybeCollect()
	end
	CALIB[ds] = { median(ts), median(as), frames }
	return CALIB[ds][1], CALIB[ds][2], frames
end

-- Median cost of one idle frame (every alive server's Heartbeat listeners etc.).
local function idleFrame(n: number?)
	local ts, as = {}, {}
	for i = 1, n or 120 do
		ts[i], as[i] = meter(function()
			Sim.step(1)
		end)
		maybeCollect()
	end
	return median(ts), median(as)
end

--------------------------------------------------------------------------------
-- Output
--------------------------------------------------------------------------------

local OUT = {}
local function out(line: string)
	table.insert(OUT, line)
	print(line)
end
local function us(x: number): string
	return string.format("%.1f", x * 1e6)
end
local function kb(x: number): string
	return string.format("%.1f", x / 1024)
end
local RAW = { mode = MODE, runs = RUNS, sections = {} }

out(`# compare_bench ({MODE}, -O{__optlevel()}, median of {RUNS} runs)`)

--------------------------------------------------------------------------------
-- 1. Load
--------------------------------------------------------------------------------

if want("load") then
	out("\n## 1. Load: StartSessionAsync, library Luau CPU + alloc (mock JSON and mock call plumbing removed)\n")
	out("| dataset | library | CPU us (median) | min us | alloc KB | UpdateAsync calls | mock Luau JSON us (excluded) |")
	out("|---|---|---:|---:|---:|---:|---:|")
	RAW.sections.load = {}
	for _, ds in DATASETS do
		local data = MAKERS[ds](1)
		local callT, callA, callF = calibrateCall(ds, data)
		for _, lib in LIBS do
			newWorld(1)
			local s = Sim.newServer({ JobId = "bench" })
			local _, store = boot(s, lib, "Bench_" .. ds, TEMPLATES[ds])
			Sim.advance(2)
			seedProfile(s, store, "Player_1", data)
			local frameT, frameA = idleFrame()
			local iters = if ds == "fm" then 5 else 40
			local samples, allocs, jsonUs, ncalls = {}, {}, {}, 0
			local function one()
				local c0 = s.stats.calls.UpdateAsync or 0
				local f0 = Sim.frame()
				local j0 = J.time
				local p
				local t, a = meter(function()
					p = s:await(store.StartSessionAsync, store, "Player_1")
				end)
				assert(p, "load failed")
				local nc = (s.stats.calls.UpdateAsync or 0) - c0
				local nf = Sim.frame() - f0
				ncalls = nc
				table.insert(jsonUs, J.time - j0)
				p:EndSession()
				Sim.advance(0.5)
				maybeCollect()
				-- the calibrated call already includes the frames its await stepped
				local extra = math.max(0, nf - nc * callF)
				return t - nc * callT - extra * frameT, a - nc * callA - extra * frameA
			end
			one()
			for r = 1, RUNS do
				local st, sa = 0, 0
				for _ = 1, iters do
					local t, a = one()
					st += t
					sa += a
				end
				samples[r] = st / iters
				allocs[r] = sa / iters
			end
			local row = {
				dataset = ds,
				lib = lib.name,
				cpuUs = median(samples) * 1e6,
				minUs = math.min(table.unpack(samples)) * 1e6,
				allocBytes = median(allocs),
				calls = ncalls,
				jsonUs = median(jsonUs) * 1e6,
				callCalibUs = callT * 1e6,
			}
			table.insert(RAW.sections.load, row)
			out(
				`| {ds} | {lib.name} | {string.format("%.1f", row.cpuUs)} | {string.format("%.1f", row.minUs)} | {kb(row.allocBytes)} | {ncalls} | {string.format("%.0f", row.jsonUs)} |`
			)
		end
	end
end

--------------------------------------------------------------------------------
-- 2. Save: one autosave
--------------------------------------------------------------------------------

-- Steps frames until `n` autosaves of profile p happened (detected by a write or,
-- for Anchor, a skipped save); returns per-save {t, a, wrote} with idle frames removed.
local function captureAutosaves(s, p, n: number, frameT: number, frameA: number, before: () -> ())
	local results = {}
	local guard = 0
	while #results < n do
		before()
		local w0 = s.stats.bytesWritten
		local u0 = s.stats.calls.UpdateAsync or 0
		local k0 = p.skipped_saves or 0
		-- step until something happens, timing each frame
		local window = {}
		local hit = nil
		while hit == nil do
			guard += 1
			assert(guard < 2e6, "no autosave observed")
			maybeCollect()
			local t, a = meter(function()
				Sim.step(1)
			end)
			table.insert(window, { t, a })
			if #window > 4 then
				table.remove(window, 1)
			end
			if (s.stats.calls.UpdateAsync or 0) > u0 then
				hit = "write"
			elseif (p.skipped_saves or 0) > k0 then
				hit = "skip"
			end
		end
		-- the save started at most a few frames ago and finishes within a few frames
		for _ = 1, 4 do
			local t, a = meter(function()
				Sim.step(1)
			end)
			table.insert(window, { t, a })
		end
		if hit == "write" then
			assert(s.stats.bytesWritten > w0, "autosave did not complete in the window")
		end
		local st, sa = 0, 0
		for _, f in window do
			st += f[1]
			sa += f[2]
		end
		table.insert(results, { t = st - #window * frameT, a = sa - #window * frameA, kind = hit })
	end
	return results
end

if want("save") then
	out("\n## 2. Save: one autosave, library Luau CPU + alloc (transform + encode/verify; mock JSON and plumbing removed)\n")
	out("| dataset | library | autosave kind | CPU us (median) | alloc KB | DataStore call? |")
	out("|---|---|---|---:|---:|---|")
	RAW.sections.save = {}
	for _, ds in DATASETS do
		local data = MAKERS[ds](1)
		local callT, callA = calibrateCall(ds, data)
		for _, lib in LIBS do
			for _, kind in { "dirty", "clean" } do
				newWorld(1)
				local s = Sim.newServer({ JobId = "bench" })
				local _, store = boot(s, lib, "Bench_" .. ds, TEMPLATES[ds], { period = 10 })
				Sim.advance(2)
				seedProfile(s, store, "Player_1", data)
				local p = s:await(store.StartSessionAsync, store, "Player_1")
				Sim.advance(1)
				local frameT, frameA = idleFrame()
				local rnd, rint = prng(99)
				local before = if kind == "dirty"
					then function()
						edit(ds, p.Data, rnd, rint)
					end
					else function() end
				local res = captureAutosaves(s, p, RUNS + 1, frameT, frameA, before)
				table.remove(res, 1) -- warm-up
				local ts, as, kinds = {}, {}, {}
				for i, r in res do
					local isWrite = r.kind == "write"
					ts[i] = r.t - (if isWrite then callT else 0)
					as[i] = r.a - (if isWrite then callA else 0)
					kinds[r.kind] = (kinds[r.kind] or 0) + 1
				end
				local kindStr = if kinds.skip and kinds.write
					then `mixed {kinds.write}w/{kinds.skip}s`
					elseif kinds.skip then "skipped (no call)"
					else "UpdateAsync"
				local row = { dataset = ds, lib = lib.name, kind = kind, cpuUs = median(ts) * 1e6, allocBytes = median(as), calls = kindStr }
				table.insert(RAW.sections.save, row)
				out(`| {ds} | {lib.name} | {kind} | {string.format("%.1f", row.cpuUs)} | {kb(row.allocBytes)} | {kindStr} |`)
				p:EndSession()
				Sim.advance(1)
			end
		end
	end
end

--------------------------------------------------------------------------------
-- 3. Resident memory per profile
--------------------------------------------------------------------------------

local function storedJsonBytes(storeName: string, keys)
	local n = 0
	for _, k in keys do
		local j = Sim.rawJson(storeName, k)
		n += if j then #j else 0
	end
	return n
end

local function settle()
	collect()
end

if want("memory") then
	out("\n## 3. Resident heap per loaded profile (50 profiles loaded, retained heap after full GC / 50)\n")
	out("| dataset | library | after load KB/profile | after 1 save each KB/profile | after reading LastSavedData KB/profile |")
	out("|---|---|---:|---:|---:|")
	RAW.sections.memory = {}
	local N = 50
	for _, ds in DATASETS do
		for _, lib in LIBS do
			newWorld(1)
			local seeder = Sim.newServer({ JobId = "seeder" })
			local _, seedStore = boot(seeder, lib, "Bench_" .. ds, TEMPLATES[ds])
			Sim.advance(2)
			local keys = {}
			for i = 1, N do
				keys[i] = "Player_" .. i
				seedProfile(seeder, seedStore, keys[i], MAKERS[ds](i))
			end
			seeder:crash()
			seedStore = nil
			Sim.advance(1)
			local s = Sim.newServer({ JobId = "bench" })
			local _, store = boot(s, lib, "Bench_" .. ds, TEMPLATES[ds])
			Sim.advance(2)
			local profiles = {}
			settle()
			local stored0 = storedJsonBytes(store.Name, keys)
			local live0 = __live_bytes()
			for i = 1, N do
				profiles[i] = s:await(store.StartSessionAsync, store, keys[i])
			end
			Sim.advance(1)
			settle()
			local afterLoad = __live_bytes() - live0 - (storedJsonBytes(store.Name, keys) - stored0)
			for i = 1, N do
				profiles[i]:Save()
			end
			Sim.advance(2)
			settle()
			local afterSave = __live_bytes() - live0 - (storedJsonBytes(store.Name, keys) - stored0)
			for i = 1, N do
				local _ = profiles[i].LastSavedData.Level
			end
			settle()
			local afterRead = __live_bytes() - live0 - (storedJsonBytes(store.Name, keys) - stored0)
			local row = { dataset = ds, lib = lib.name, afterLoad = afterLoad / N, afterSave = afterSave / N, afterRead = afterRead / N }
			table.insert(RAW.sections.memory, row)
			out(`| {ds} | {lib.name} | {kb(row.afterLoad)} | {kb(row.afterSave)} | {kb(row.afterRead)} |`)
			for i = 1, N do
				profiles[i]:EndSession()
			end
			Sim.advance(2)
			profiles = nil
		end
	end
end

--------------------------------------------------------------------------------
-- 4. Stored bytes
--------------------------------------------------------------------------------

if want("size") then
	out("\n## 4. Stored bytes per profile (mock stores Roblox-rule JSON; buffers as uncompressed base64)\n")
	out("| dataset | library | stored JSON bytes | Data JSON bytes | blob raw bytes | blob base64 bytes |")
	out("|---|---|---:|---:|---:|---:|")
	RAW.sections.size = {}
	for _, ds in DATASETS do
		for _, lib in LIBS do
			newWorld(1)
			local s = Sim.newServer({ JobId = "bench" })
			local _, store = boot(s, lib, "Bench_" .. ds, TEMPLATES[ds])
			Sim.advance(2)
			seedProfile(s, store, "Player_1", MAKERS[ds](1))
			local json = Sim.rawJson(store.Name, "Player_1") :: string
			local raw = Sim.peek(store.Name, "Player_1")
			local dataJson = #JSON.encode(raw.Data)
			local blob = type(raw.Data) == "table" and raw.Data.AnchorBlob
			local row = { dataset = ds, lib = lib.name, json = #json, dataJson = dataJson }
			if type(blob) == "buffer" then
				row.blob = buffer.len(blob)
				row.base64 = 4 * math.ceil(buffer.len(blob) / 3)
				Bench.dumpBlob(`{ds}-compact-blob`, blob)
			else
				writefile(`{RESULTS}/blobs/{ds}-{lib.name}-data.json`, JSON.encode(raw.Data))
			end
			table.insert(RAW.sections.size, row)
			out(`| {ds} | {lib.name} | {row.json} | {dataJson} | {row.blob or "-"} | {row.base64 or "-"} |`)
		end
	end
end

--------------------------------------------------------------------------------
-- 5. DataStore calls per hour per player
--------------------------------------------------------------------------------

if want("calls") then
	out("\n## 5. DataStore calls per hour per player (steady state, 10 players, 3 virtual hours; load + release excluded)\n")
	out("| config | library | idle: calls/h | idle: KB written/h | active: calls/h | active: KB written/h |")
	out("|---|---|---:|---:|---:|---:|")
	RAW.sections.calls = {}
	local configs = {
		{ name = "defaults (AUTO_SAVE_PERIOD 300)", period = nil },
		{ name = "AUTO_SAVE_PERIOD 60", period = 60 },
		{ name = "AUTO_SAVE_PERIOD 60, LockRefresh 400", period = 60, anchor = { LockRefresh = 400 }, anchorOnly = true },
	}
	local P, HOURS = 10, 3
	for _, cfg in configs do
		for _, lib in LIBS do
			if cfg.anchorOnly and lib.format == nil then
				continue
			end
			local res = {}
			for _, activity in { "idle", "active" } do
				newWorld(1)
				local s = Sim.newServer({ JobId = "bench" })
				local _, store = boot(s, lib, "Bench_small", TEMPLATES.small, { period = cfg.period, anchor = cfg.anchor })
				Sim.advance(2)
				local profiles = {}
				for i = 1, P do
					local key = "Player_" .. i
					seedProfile(s, store, key, makeSmall(i))
				end
				for i = 1, P do
					s:spawn(function()
						profiles[i] = store:StartSessionAsync("Player_" .. i)
					end)
					Sim.advance(30 / P) -- staggered joins
				end
				Sim.advance(5)
				local rnd, rint = prng(7)
				local before = Bench.snapshot(s.stats)
				for _ = 1, HOURS * 60 do
					if activity == "active" then
						for i = 1, P do
							edit("small", profiles[i].Data, rnd, rint)
						end
					end
					Sim.advance(60)
					maybeCollect()
				end
				local d = Bench.delta(before, s.stats)
				local n = 0
				for method, v in d.calls do
					if method ~= "SubscribeAsync" and method ~= "PublishAsync" then
						n += v
					end
				end
				res[activity] = { calls = n / P / HOURS, bytes = d.bytesWritten / P / HOURS, byMethod = d.calls }
				for i = 1, P do
					profiles[i]:EndSession()
				end
				Sim.advance(2)
			end
			table.insert(RAW.sections.calls, { config = cfg.name, lib = lib.name, idle = res.idle, active = res.active })
			out(
				`| {cfg.name} | {lib.name} | {string.format("%.1f", res.idle.calls)} | {kb(res.idle.bytes)} | {string.format("%.1f", res.active.calls)} | {kb(res.active.bytes)} |`
			)
		end
	end
end

--------------------------------------------------------------------------------
-- 6. 50-player server
--------------------------------------------------------------------------------

-- One run: 50 players join over 60 s, each plays 30 virtual minutes (an edit every
-- 10-60 s), leaves; then 60 s for releases. lib == nil runs the same script without
-- any library (mock + players only) to measure the simulation's own cost.
local function serverRun(ds: string, lib, seed: number)
	newWorld(seed, { latency = { 0.1, 0.3 } })
	local N, JOIN, PLAY = 50, 60, 30 * 60
	local storeName = "Server_" .. ds
	local keys = {}
	for i = 1, N do
		keys[i] = "Player_" .. i
	end
	if lib then
		local seeder = Sim.newServer({ JobId = "seeder" })
		local _, seedStore = boot(seeder, lib, storeName, TEMPLATES[ds])
		Sim.advance(2)
		for i = 1, N do
			seedProfile(seeder, seedStore, keys[i], MAKERS[ds](i))
		end
		seeder:crash()
	end
	local s = Sim.newServer({ JobId = "game" })
	local store
	if lib then
		_, store = boot(s, lib, storeName, TEMPLATES[ds])
	end
	local t0 = Sim.now()
	local cpu, alloc = meter(function()
		Sim.advance(2)
	end)
	local profiles, players, nextEdit, joinAt = {}, {}, {}, {}
	for i = 1, N do
		joinAt[i] = t0 + 2 + (i - 1) * JOIN / N
	end
	local rnd, rint = prng(seed * 31 + 5)
	local before = Bench.snapshot(s.stats)
	local endAt = t0 + 2 + JOIN + PLAY + 60
	local edits = 0
	while Sim.now() < endAt do
		local now = Sim.now()
		for i = 1, N do
			if players[i] == nil and joinAt[i] and now >= joinAt[i] then
				joinAt[i] = nil
				local player = s:addPlayer(1000 + i)
				players[i] = player
				nextEdit[i] = now + rint(10, 60)
				if store then
					s:spawn(function()
						local profile = store:StartSessionAsync(keys[i], {
							Cancel = function()
								return player.Parent ~= s.Players
							end,
						})
						if profile == nil then
							return
						end
						profile:AddUserId(player.UserId)
						profile:Reconcile()
						profile.OnSessionEnd:Connect(function()
							profiles[i] = nil
						end)
						if player.Parent == s.Players then
							profiles[i] = profile
						else
							profile:EndSession()
						end
					end)
				end
			elseif players[i] and players[i] ~= true then
				if now >= t0 + 2 + (i - 1) * JOIN / N + PLAY then
					s:removePlayer(players[i])
					if profiles[i] then
						profiles[i]:EndSession()
					end
					players[i] = true
				elseif now >= nextEdit[i] then
					nextEdit[i] = now + rint(10, 60)
					edits += 1
					if profiles[i] then
						edit(ds, profiles[i].Data, rnd, rint)
					end
				end
			end
		end
		local t, a = meter(function()
			Sim.advance(1)
		end)
		cpu += t
		alloc += a
		maybeCollect()
	end
	local d = Bench.delta(before, s.stats)
	local n, msg = 0, 0
	for method, v in d.calls do
		if method == "SubscribeAsync" or method == "PublishAsync" then
			msg += v
		else
			n += v
		end
	end
	local released = 0
	if lib then
		for i = 1, N do
			local raw = Sim.peek(storeName, keys[i])
			if raw and raw.MetaData.ActiveSession == nil then
				released += 1
			end
		end
	end
	return { cpu = cpu, alloc = alloc, calls = n, msgCalls = msg, byMethod = d.calls, bytesWritten = d.bytesWritten, bytesRead = d.bytesRead, released = released, edits = edits }
end

if want("server") then
	local SRUNS = tonumber(getenv("COMPARE_SERVER_RUNS") or "") or RUNS
	out(`\n## 6. 50-player server, 30 virtual minutes (median of {SRUNS} runs; library CPU = run - same run without a library - mock per-call plumbing)\n`)
	out("| dataset | library | library CPU ms | library alloc MB | DataStore calls | of which UpdateAsync | Messaging calls | bytes written MB | released |")
	out("|---|---|---:|---:|---:|---:|---:|---:|---:|")
	RAW.sections.server = {}
	local notes = {}
	for _, ds in DATASETS do
		local callT, callA = calibrateCall(ds, MAKERS[ds](1))
		local baseT, baseA = {}, {}
		for r = 1, SRUNS do
			local b = serverRun(ds, nil, r)
			baseT[r], baseA[r] = b.cpu, b.alloc
		end
		local bT, bA = median(baseT), median(baseA)
		for _, lib in LIBS do
			local ts, as, last = {}, {}, nil
			for r = 1, SRUNS do
				local res = serverRun(ds, lib, r)
				ts[r] = res.cpu - bT - res.calls * callT
				as[r] = res.alloc - bA - res.calls * callA
				last = res
			end
			local row = {
				dataset = ds,
				lib = lib.name,
				cpuMs = median(ts) * 1e3,
				allocMB = median(as) / 1048576,
				calls = last.calls,
				msgCalls = last.msgCalls,
				update = last.byMethod.UpdateAsync or 0,
				writtenMB = last.bytesWritten / 1048576,
				released = last.released,
				baselineMs = bT * 1e3,
			}
			table.insert(RAW.sections.server, row)
			out(
				`| {ds} | {lib.name} | {string.format("%.1f", row.cpuMs)} | {string.format("%.2f", row.allocMB)} | {row.calls} | {row.update} | {row.msgCalls} | {string.format("%.2f", row.writtenMB)} | {row.released}/50 |`
			)
		end
		table.insert(notes, `sim-only baseline for {ds}: {string.format("%.1f", bT * 1e3)} ms CPU; mock per-call plumbing {us(callT)} us/call; both removed above`)
	end
	out("")
	for _, note in notes do
		out(`- {note}`)
	end
end

local suffix = if ONLY == "" then "" else "-" .. string.gsub(ONLY, "[^%w]+", "-")
writefile(`{RESULTS}/compare-{MODE}{suffix}.json`, JSON.encode(RAW))
writefile(`{RESULTS}/compare-{MODE}{suffix}.md`, table.concat(OUT, "\n") .. "\n")
