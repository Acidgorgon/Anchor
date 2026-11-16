--!strict
-- Codec benchmark: encode/decode time and output size on two datasets.
-- Run from the repo root:
--   <luau host> [--codegen] bench/codec_bench.luau [outdir]
-- With `outdir`, writes <name>.bin (codec blob) and <name>.json (JSON text)
-- for bench/codec_zstd.py, which reports zstd sizes.
--
-- Datasets (deterministic, seeded):
--   small : ~20 fields of typical player data
--   fm    : { Owned = { i<N> = card(10 fields) x 670 }, Coins, Gems, Version }
--
-- JSON length uses a compact Roblox-like encoder (no whitespace, integers
-- printed as integers, other numbers in the shortest form that round trips,
-- which can only make JSON look smaller than Roblox's own output).
-- Studio-only facts (Roblox's real JSONEncode output, its zbase64 buffer
-- compression) cannot be measured here.

local function loadModule(path: string): any
	local rf = (_G :: any).readfile
	local ls = (_G :: any).loadstring
	if rf and ls then
		local src = rf(path)
		assert(src, "cannot read " .. path)
		local fn, err = ls(src, "@" .. path)
		assert(fn, err)
		return fn()
	end
	return (require :: any)("../src/Codec")
end

local Codec = loadModule("src/Codec.luau")
local args = (_G :: any).arg or {}
local OUTDIR: string? = args[1]

-- PRNG ----------------------------------------------------------------------------
local state = 20261116
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

-- datasets ---------------------------------------------------------------------------
local function makeSmall(): any
	return {
		Coins = 15230,
		Gems = 42,
		Level = 17,
		Xp = 48213,
		Rebirths = 2,
		PlayTime = 183245,
		LastLogin = 1763251200,
		FirstJoin = 1731715200,
		DailyStreak = 6,
		Tutorial = true,
		Banned = false,
		Title = "Rookie",
		EquippedPet = "Dragon",
		Multiplier = 1.5,
		Settings = { Music = true, Sfx = 0.8, Shadows = false, Language = "en" },
		Inventory = { "Sword", "Shield", "Potion", "Potion", "Bow" },
		Pets = { { Name = "Dragon", Level = 5 }, { Name = "Cat", Level = 2 } },
		Quests = { Q1 = true, Q2 = false, Q3 = 0.25 },
		Codes = { "WELCOME", "SUMMER" },
		Stats = { Kills = 1205, Deaths = 371, Wins = 88 },
	}
end

local RARITIES = { "Common", "Uncommon", "Rare", "Epic", "Legendary" }
local POSITIONS = { "GK", "CB", "LB", "RB", "CDM", "CM", "CAM", "LW", "RW", "ST" }
local NATIONS = { "ENG", "ESP", "FRA", "GER", "BRA", "ARG", "POR", "NED", "ITA", "BEL", "USA", "JPN" }

local function makeFm(): any
	local owned = {}
	for n = 1, 670 do
		local npos = rint(1, 3)
		local positions = table.create(npos)
		for i = 1, npos do
			positions[i] = POSITIONS[rint(1, #POSITIONS)]
		end
		owned["i" .. (n * 7 + rint(0, 6))] = {
			Id = rint(1, 4000), -- card template id
			Level = rint(1, 99),
			Xp = rint(0, 250000),
			Rating = rint(400, 990) / 10, -- e.g. 73.4 (not f32 exact)
			Rarity = RARITIES[rint(1, #RARITIES)],
			Nation = NATIONS[rint(1, #NATIONS)],
			Locked = rnd() % 4 == 0,
			Favorite = rnd() % 10 == 0,
			Acquired = 1735689600 + rint(0, 30000000),
			Positions = positions,
		}
	end
	return {
		Owned = owned,
		Coins = 1250340,
		Gems = 3210,
		Version = 3,
		NextId = 4700,
	}
end

-- Roblox-like compact JSON ---------------------------------------------------------
local function jsonNumber(x: number): string
	if x // 1 == x and math.abs(x) < 2 ^ 53 then
		return string.format("%d", x)
	end
	for _, p in { "%.14g", "%.15g", "%.16g", "%.17g" } do
		local s = string.format(p, x)
		if tonumber(s) == x then
			return s
		end
	end
	return string.format("%.17g", x)
end

local ESC: { [string]: string } = {
	['"'] = '\\"',
	["\\"] = "\\\\",
	["\b"] = "\\b",
	["\f"] = "\\f",
	["\n"] = "\\n",
	["\r"] = "\\r",
	["\t"] = "\\t",
}
local function jsonString(s: string): string
	return '"'
		.. string.gsub(s, '[%c"\\]', function(c: string): string
			return ESC[c] or string.format("\\u%04x", string.byte(c))
		end)
		.. '"'
end

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function base64Len(n: number): number
	return 4 * math.ceil(n / 3)
end
local function base64(b: buffer): string
	local parts = {}
	local n = buffer.len(b)
	for i = 0, n - 1, 3 do
		local a = buffer.readu8(b, i)
		local c1 = if i + 1 < n then buffer.readu8(b, i + 1) else 0
		local c2 = if i + 2 < n then buffer.readu8(b, i + 2) else 0
		local v = a * 65536 + c1 * 256 + c2
		local s = string.sub(B64, v // 262144 + 1, v // 262144 + 1)
			.. string.sub(B64, v // 4096 % 64 + 1, v // 4096 % 64 + 1)
			.. (if i + 1 < n then string.sub(B64, v // 64 % 64 + 1, v // 64 % 64 + 1) else "=")
			.. (if i + 2 < n then string.sub(B64, v % 64 + 1, v % 64 + 1) else "=")
		table.insert(parts, s)
	end
	return table.concat(parts)
end

local function toJson(v: any, parts: { string })
	local t = type(v)
	if t == "number" then
		table.insert(parts, jsonNumber(v))
	elseif t == "string" then
		table.insert(parts, jsonString(v))
	elseif t == "boolean" then
		table.insert(parts, if v then "true" else "false")
	elseif t == "buffer" then
		table.insert(parts, '{"m":null,"t":"buffer","base64":"' .. base64(v) .. '"}')
	elseif t == "table" then
		if rawlen(v) > 0 or next(v) == nil then
			table.insert(parts, "[")
			for i = 1, rawlen(v) do
				if i > 1 then
					table.insert(parts, ",")
				end
				toJson(v[i], parts)
			end
			table.insert(parts, "]")
		else
			table.insert(parts, "{")
			local first = true
			for k, c in next, v do
				if not first then
					table.insert(parts, ",")
				end
				first = false
				table.insert(parts, jsonString(k))
				table.insert(parts, ":")
				toJson(c, parts)
			end
			table.insert(parts, "}")
		end
	end
end
local function jsonEncode(v: any): string
	local parts = {}
	toJson(v, parts)
	return table.concat(parts)
end

-- timing ---------------------------------------------------------------------------
local function timeit(fn: () -> ()): number -- microseconds per call
	local iters = 1
	while true do
		local t0 = os.clock()
		for _ = 1, iters do
			fn()
		end
		local dt = os.clock() - t0
		if dt >= 0.3 then
			-- best of 3 runs of this size
			local best = dt
			for _ = 1, 2 do
				t0 = os.clock()
				for _ = 1, iters do
					fn()
				end
				best = math.min(best, os.clock() - t0)
			end
			return best / iters * 1e6
		end
		iters *= 2
	end
end

local native = (_G :: any).__native and (_G :: any).__native() or false
print(string.format("codec bench (Codec v%d, %s)", Codec.VERSION, if native then "native codegen" else "interpreter"))
print(
	string.format(
		"%-6s %9s %9s %11s %9s %9s | %8s %8s %8s %8s",
		"data",
		"enc us",
		"dec us",
		"decInto us",
		"valid us",
		"equal us",
		"blob B",
		"b64 B",
		"json B",
		"blob/js"
	)
)

for _, ds in { { "small", makeSmall() }, { "fm", makeFm() } } do
	local name: string, value = ds[1], ds[2]
	local blob = Codec.encode(value)
	assert(Codec.equal(Codec.decode(blob), value), "round trip failed for " .. name)
	local json = jsonEncode(value)
	local target = {}
	local decoded = Codec.decode(blob)
	local encUs = timeit(function()
		Codec.encode(value)
	end)
	local decUs = timeit(function()
		Codec.decode(blob)
	end)
	local intoUs = timeit(function()
		Codec.decodeInto(blob, target)
	end)
	local valUs = timeit(function()
		Codec.validate(value)
	end)
	local eqUs = timeit(function()
		Codec.equal(decoded, value)
	end)
	local blen = buffer.len(blob)
	print(
		string.format(
			"%-6s %9.1f %9.1f %11.1f %9.1f %9.1f | %8d %8d %8d %7.1f%%",
			name,
			encUs,
			decUs,
			intoUs,
			valUs,
			eqUs,
			blen,
			base64Len(blen),
			#json,
			blen / #json * 100
		)
	)
	if OUTDIR then
		local wf = (_G :: any).writefile
		wf(OUTDIR .. "/" .. name .. ".bin", buffer.tostring(blob))
		wf(OUTDIR .. "/" .. name .. ".json", json)
	end
end
