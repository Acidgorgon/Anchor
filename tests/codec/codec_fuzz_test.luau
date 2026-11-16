--!strict
-- Seeded fuzz tests for src/Codec.luau.
-- Run: tests/run.sh tests/codec/codec_fuzz_test.luau
--        (env CODEC_FUZZ_SEED / CODEC_FUZZ_SCALE override the defaults)
--  or, from the repo root on a bare host:
--        luau-bench tests/codec/codec_fuzz_test.luau [seed] [scale]
--   seed  : PRNG seed (default 12345); failures print the seed and iteration
--   scale : multiplies iteration counts (default 1)
--
-- 1. valid values: random nested DataStore-acceptable values must validate,
--    encode, decode deep-equal (including -0), and re-encode stably.
-- 2. invalid values: a valid value with exactly one injected defect must be
--    rejected by validate AND encode, with the exact expected path.
-- 3. decoder: random bytes, every truncation, and random byte mutations of
--    valid blobs must either raise a "Codec.decode" error or return a value
--    that is itself valid (never a VM error, never garbage).

-- Under tests/run.sh (tests/mock/runner.luau) the harness `require` is used;
-- run directly on a bare host it loads src/Codec.luau relative to the cwd.
local function loadCodec(): any
	local req = (_G :: any).require
	if type(req) == "function" then
		return req("@root/src/Codec")
	end
	local src = (_G :: any).readfile("src/Codec.luau")
	assert(src, "cannot read src/Codec.luau (run from the repo root)")
	local fn, err = (_G :: any).loadstring(src, "@src/Codec.luau")
	assert(fn, err)
	return fn()
end

local Codec = loadCodec()

local getenv = (_G :: any).getenv
local underRunner = type((_G :: any).require) == "function"
local args = if underRunner then {} else ((_G :: any).arg or {})
local SEED = tonumber(getenv and getenv("CODEC_FUZZ_SEED")) or tonumber(args[1]) or 12345
local SCALE = tonumber(getenv and getenv("CODEC_FUZZ_SCALE")) or tonumber(args[2]) or 1

-- xorshift32 PRNG, deterministic across hosts ----------------------------------
local state = SEED % 4294967296
if state == 0 then
	state = 0x9E3779B9
end
local function rnd(): number -- [0, 2^32)
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
local function chance(p: number): boolean
	return rnd() / 4294967296 < p
end

-- path formatting (the documented format: identifiers as .key, others ["key"]
-- with control chars, quote and backslash as \ddd, array indices as [i])
local function seg(k: any): string
	if type(k) == "number" then
		return "[" .. tostring(k) .. "]"
	elseif string.find(k, "^[%a_][%w_]*$") then
		return "." .. k
	end
	local pattern = if utf8.len(k) then '[%c"\\]' else '[%c"\\\128-\255]'
	local q = string.gsub(k, pattern, function(c: string): string
		return "\\" .. string.byte(c)
	end)
	return '["' .. q .. '"]'
end

-- random value generation ----------------------------------------------------------
local KEY_POOL = { "Level", "Xp", "Rarity", "Name", "Owned", "a", "b", "_x", "Stats", "key with space", "日本", "", "1", "Ünï" }
local STR_POOL = { "Common", "Rare", "Epic", "Legendary", "", "x", "héllo", "🎉", string.rep("long", 20), "\0z" }

local function randUtf8(): string
	local n = rint(0, 40)
	local parts = table.create(n)
	for i = 1, n do
		local r = rnd() % 10
		local cp
		if r < 6 then
			cp = rint(0, 127)
		elseif r < 8 then
			cp = rint(0x80, 0x7FF)
		elseif r < 9 then
			cp = rint(0x800, 0xFFFF)
			if cp >= 0xD800 and cp <= 0xDFFF then
				cp = 0x41
			end
		else
			cp = rint(0x10000, 0x10FFFF)
		end
		parts[i] = utf8.char(cp)
	end
	return table.concat(parts)
end

local f32b = buffer.create(8)
local function randNumber(): number
	local r = rnd() % 12
	if r == 0 then
		return rint(0, 127)
	elseif r == 1 then
		return -rint(0, 1000)
	elseif r == 2 then
		return rnd() * 4096 + rnd() -- up to ~2^44
	elseif r == 3 then
		local v = rnd() * 2097152 + rnd() % 2097152 -- up to 2^53
		return if chance(0.5) then v else -v
	elseif r == 4 then
		return (rnd() - 2147483648) / 1024 -- f32-exact-ish
	elseif r == 5 then
		return (rnd() / 4294967296) * 1000 -- generally f64
	elseif r == 6 then
		buffer.writeu32(f32b, 0, rnd())
		buffer.writeu32(f32b, 4, rnd())
		local x = buffer.readf64(f32b, 0)
		if x ~= x or x == math.huge or x == -math.huge then
			return 1.25
		end
		return x
	elseif r == 7 then
		buffer.writeu32(f32b, 0, rnd())
		local x = buffer.readf32(f32b, 0)
		if x ~= x or x == math.huge or x == -math.huge then
			return 2.5
		end
		return x
	elseif r == 8 then
		return -0.0
	elseif r == 9 then
		local e = rint(50, 60)
		return (if chance(0.5) then 1 else -1) * (2 ^ e + rint(0, 3) * 2 ^ (e - 52))
	elseif r == 10 then
		if chance(0.3) then
			return 0
		end
		local sc = 10 ^ rint(1, 7) -- short decimals (DEC tag), incl. 7 places
		return (rnd() - 2147483648) / sc
	end
	return rint(128, 70000)
end

local function randString(): string
	if chance(0.6) then
		return STR_POOL[rint(1, #STR_POOL)]
	end
	return randUtf8()
end

local function randKey(): string
	if chance(0.7) then
		return KEY_POOL[rint(1, #KEY_POOL)]
	end
	return randUtf8()
end

local genValue: (depth: number) -> any
local budget = 0 -- values left for the current root; keeps trees bounded

local function genTable(depth: number): { [any]: any }
	local big = chance(0.08) and budget > 200
	if chance(0.5) then
		local n = if big then rint(16, 200) else rint(0, 15)
		local t = table.create(n)
		for i = 1, n do
			t[i] = genValue(depth + 1)
		end
		return t
	end
	local n = if big then rint(16, 120) else rint(0, 15)
	local t = {}
	for _ = 1, n do
		t[randKey()] = genValue(depth + 1)
	end
	return t
end

genValue = function(depth: number): any
	budget -= 1
	local r = rnd() % 10
	if depth < 8 and r < 4 and budget > 0 then
		return genTable(depth)
	elseif r < 6 then
		return randNumber()
	elseif r < 8 then
		return randString()
	elseif r < 9 then
		return chance(0.5)
	end
	local b = buffer.create(rint(0, 24))
	for i = 0, buffer.len(b) - 1 do
		buffer.writeu8(b, i, rint(0, 255))
	end
	return b
end

local function genRoot(): { [any]: any }
	budget = if chance(0.1) then 2000 else rint(1, 300)
	if chance(0.03) then -- deep chain up to the limit
		local root = {}
		local cur = root
		for _ = 2, rint(150, 200) do
			local nxt = {}
			if chance(0.5) then
				cur[1] = nxt
			else
				cur.n = nxt
				if chance(0.2) then
					cur.side = genValue(7)
				end
			end
			cur = nxt
		end
		return root
	end
	return genTable(0)
end

-- collect tables with their paths and parent index (for defect injection)
type Node = { t: { [any]: any }, path: string, parent: number }
local function collectTables(v: any, path: string, parent: number, outList: { Node })
	if type(v) ~= "table" then
		return
	end
	table.insert(outList, { t = v, path = path, parent = parent })
	local me = #outList
	for k, c in next, v do
		collectTables(c, path .. seg(k), me, outList)
	end
end

local passed, failed = 0, 0
local failedKinds: { string } = {}
local function failure(kind: string, iter: number, msg: string)
	failed += 1
	table.insert(failedKinds, kind)
	if failed <= 20 then
		print(string.format("FAIL [%s] seed=%d iter=%d: %s", kind, SEED, iter, msg))
	end
end

local t0 = os.clock()

-- 1. valid round trips ------------------------------------------------------------
local VALID = 4000 * SCALE
local blobs: { buffer } = {}
for iter = 1, VALID do
	local v = genRoot()
	local ok, path, reason = Codec.validate(v)
	if not ok then
		failure("valid", iter, "validate rejected: " .. tostring(path) .. " " .. tostring(reason))
		continue
	end
	local eok, b = pcall(Codec.encode, v)
	if not eok then
		failure("valid", iter, "encode failed: " .. tostring(b))
		continue
	end
	local dok, d = pcall(Codec.decode, b)
	if not dok then
		failure("valid", iter, "decode failed: " .. tostring(d))
		continue
	end
	if not Codec.equal(d, v) then
		failure("valid", iter, "round trip not deep-equal")
		continue
	end
	-- (sizes may differ by a few bytes: a decoded table can iterate in a
	-- different order, which changes string-table indices)
	local b2 = Codec.encode(d)
	if not Codec.equal(Codec.decode(b2), v) then
		failure("valid", iter, "re-encode differs in content")
		continue
	end
	local target = { junk = true }
	Codec.decodeInto(b, target)
	if not Codec.equal(target, v) then
		failure("valid", iter, "decodeInto not deep-equal")
		continue
	end
	if #blobs < 400 and buffer.len(b) <= 3000 then
		table.insert(blobs, b)
	end
	passed += 1
end
local validPassed = passed

-- 2. invalid values with one injected defect ---------------------------------------
local function injectDefect(root: { [any]: any }): (string, string)
	local list: { Node } = {}
	collectTables(root, "Data", 0, list)
	local nodeIndex = rint(1, #list)
	local node = list[nodeIndex]
	local t, p = node.t, node.path
	local isArray = rawlen(t) > 0
	local kind = rnd() % 9
	if kind == 0 or kind == 1 or kind == 2 or kind == 3 then
		local bad: any
		local reason: string
		if kind == 0 then
			bad, reason = 0 / 0, "NaN"
		elseif kind == 1 then
			bad, reason = if chance(0.5) then math.huge else -math.huge, "inf"
		elseif kind == 2 then
			bad, reason = function() end, "function"
		else
			bad, reason = "ok\255\254", "UTF%-8"
		end
		if isArray then
			local i = rint(1, rawlen(t))
			t[i] = bad
			return p .. seg(i), reason
		end
		t.zz_bad = bad
		return p .. ".zz_bad", reason
	elseif kind == 4 then -- cycle back to an ancestor (or self)
		local anc = node
		local i = node.parent
		while i > 0 do -- walk up a random number of ancestors (self-cycle allowed)
			if chance(0.5) then
				break
			end
			anc = list[i]
			i = anc.parent
		end
		if isArray then
			t[rawlen(t) + 1] = anc.t
			return p .. seg(rawlen(t)), "cycle"
		end
		t.zz_cycle = anc.t
		return p .. ".zz_cycle", "cycle"
	elseif kind == 5 then -- sparse array
		if isArray then
			t[rawlen(t) + 2] = 1
		else
			table.clear(t)
			t[2] = true
		end
		return p, "sparse"
	elseif kind == 6 then -- mixed
		if isArray then
			t.zz_mixed = 1
		else
			t.zz_mixed = 1
			t[1] = 1
		end
		return p, "mixed"
	elseif kind == 7 then -- invalid key
		table.clear(t)
		t.x = 1
		local k: any = if chance(0.5) then 2.5 else true
		t[k] = 1
		return p .. (if k == true then "[true]" else "[2.5]"), if k == true then "boolean" else "non%-integer"
	else -- invalid UTF-8 key
		table.clear(t)
		t.ok = 1
		t["\200bad"] = 1
		return p .. seg("\200bad"), "UTF%-8"
	end
end

local INVALID = 3000 * SCALE
local invalidPassed = 0
for iter = 1, INVALID do
	local v = genRoot()
	local expectPath, reasonPat = injectDefect(v)
	local ok, path, reason = Codec.validate(v)
	if ok then
		failure("invalid", iter, "validate accepted defect expected at " .. expectPath)
		continue
	end
	if path ~= expectPath or not string.find(reason :: string, reasonPat) then
		failure(
			"invalid",
			iter,
			string.format("expected %s (%s), got %s (%s)", expectPath, reasonPat, tostring(path), tostring(reason))
		)
		continue
	end
	local eok, err = pcall(Codec.encode, v)
	if eok or not string.find(tostring(err), expectPath, 1, true) then
		failure("invalid", iter, "encode did not fail with path: " .. tostring(err))
		continue
	end
	invalidPassed += 1
	passed += 1
end

-- 3. decoder fuzz -------------------------------------------------------------------
local function decodeSafely(kind: string, iter: number, b: buffer): boolean
	local ok, res = pcall(Codec.decode, b)
	if ok then
		local vok, vpath, vreason = Codec.validate(res)
		if not vok then
			failure(kind, iter, "decoder returned invalid value at " .. tostring(vpath) .. ": " .. tostring(vreason))
			return false
		end
		return true
	end
	if type(res) ~= "string" or not string.find(res, "Codec.decode", 1, true) then
		failure(kind, iter, "decoder raised a non-codec error: " .. tostring(res))
		return false
	end
	return true
end

local MUTATE = 30000 * SCALE
local mutatedAccepted = 0
local decoderPassed = 0
for iter = 1, MUTATE do
	local src = blobs[rint(1, #blobs)]
	local n = buffer.len(src)
	local b = buffer.create(n)
	buffer.copy(b, 0, src, 0, n)
	local flips = rint(1, 4)
	for _ = 1, flips do
		local at = if chance(0.3) and n > 5 then rint(5, math.min(n - 1, 12)) else rint(0, n - 1)
		buffer.writeu8(b, at, if chance(0.5) then rint(0, 255) else bit32.bxor(buffer.readu8(b, at), bit32.lshift(1, rint(0, 7))))
	end
	if decodeSafely("mutate", iter, b) then
		decoderPassed += 1
		if pcall(Codec.decode, b) then
			mutatedAccepted += 1
		end
	end
end

local RANDOM = 20000 * SCALE
for iter = 1, RANDOM do
	local n = rint(0, 64)
	local b = buffer.create(n)
	for i = 0, n - 1 do
		buffer.writeu8(b, i, rint(0, 255))
	end
	if n >= 5 and chance(0.9) then
		buffer.writestring(b, 0, "ANC\1\0")
	end
	if decodeSafely("random", iter, b) then
		decoderPassed += 1
	end
end

local truncations = 0
for iter = 1, math.min(#blobs, 150) do
	local src = blobs[iter]
	local n = buffer.len(src)
	for len = 0, n - 1 do
		local b = buffer.create(len)
		buffer.copy(b, 0, src, 0, len)
		truncations += 1
		local ok, err = pcall(Codec.decode, b)
		if ok then
			failure("truncate", iter, "truncated blob decoded (len " .. len .. " of " .. n .. ")")
		elseif not string.find(tostring(err), "Codec.decode", 1, true) then
			failure("truncate", iter, "non-codec error: " .. tostring(err))
		else
			decoderPassed += 1
		end
	end
end

print(
	string.format(
		"codec_fuzz seed=%d: valid %d/%d, invalid %d/%d, decoder %d/%d (mutations %d, %d decoded to valid values; random %d; truncations %d), %d failures, %.2fs",
		SEED,
		validPassed,
		VALID,
		invalidPassed,
		INVALID,
		decoderPassed,
		MUTATE + RANDOM + truncations,
		MUTATE,
		mutatedAccepted,
		RANDOM,
		truncations,
		failed,
		os.clock() - t0
	)
)
-- one RESULT unit per fuzz category (valid, invalid, mutate, random, truncate)
local badKinds = {}
for _, k in failedKinds do
	badKinds[k] = true
end
local nbad = 0
for _ in badKinds do
	nbad += 1
end
print(string.format("RESULT pass=%d fail=%d skip=0", 5 - nbad, nbad))
if failed > 0 then
	error("codec_fuzz failed", 0)
end
