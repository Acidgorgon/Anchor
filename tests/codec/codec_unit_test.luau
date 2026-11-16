--!strict
-- Unit tests for src/Codec.luau.
-- Run: tests/run.sh tests/codec/codec_unit_test.luau
--  or, from the repo root on a bare host: luau-bench tests/codec/codec_unit_test.luau

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

local passed, failed = 0, 0
local failures: { string } = {}

local function test(name: string, fn: () -> ())
	local ok, err = pcall(fn)
	if ok then
		passed += 1
	else
		failed += 1
		table.insert(failures, name .. ": " .. tostring(err))
	end
end

local function check(cond: any, msg: string?)
	if not cond then
		error(msg or "check failed", 2)
	end
end

local function roundTrip(v: any): any
	local b = Codec.encode(v)
	local d = Codec.decode(b)
	check(Codec.equal(d, v), "round trip mismatch")
	return d
end

local function expectInvalid(v: any, path: string, reasonPattern: string)
	local ok, p, reason = Codec.validate(v)
	check(not ok, "validate accepted invalid value (expected " .. path .. ")")
	check(path == nil or p == path, string.format("path: expected %q got %q (%s)", path, tostring(p), tostring(reason)))
	check(
		string.find(reason :: string, reasonPattern) ~= nil,
		string.format("reason %q does not match %q", tostring(reason), reasonPattern)
	)
	local eok, err = pcall(Codec.encode, v)
	check(not eok, "encode accepted invalid value")
	check(path == nil or string.find(tostring(err), path, 1, true) ~= nil, "encode error lacks path: " .. tostring(err))
end

local function expectMalformed(b: buffer, pattern: string?)
	local ok, err = pcall(Codec.decode, b)
	check(not ok, "decode accepted malformed input")
	check(string.find(tostring(err), "Codec.decode", 1, true) ~= nil, "unexpected error: " .. tostring(err))
	if pattern then
		check(string.find(tostring(err), pattern) ~= nil, "error " .. tostring(err) .. " lacks " .. pattern)
	end
end

local function bytes(...: number): buffer
	local t = { ... }
	local b = buffer.create(#t)
	for i, v in t do
		buffer.writeu8(b, i - 1, v)
	end
	return b
end

local function withHeader(...: number): buffer
	return bytes(0x41, 0x4E, 0x43, 1, 0, ...)
end

-- header ----------------------------------------------------------------------

test("VERSION and header", function()
	check(Codec.VERSION == 1)
	local b = Codec.encode(true)
	check(buffer.len(b) == 6)
	check(buffer.readstring(b, 0, 3) == "ANC")
	check(buffer.readu8(b, 3) == Codec.VERSION)
	check(buffer.readu8(b, 4) == 0)
	check(buffer.readu8(b, 5) == 0x02)
end)

test("unknown version, flags, bad magic rejected", function()
	expectMalformed(bytes(0x41, 0x4E, 0x43, 2, 0, 0x80), "unsupported codec version 2")
	expectMalformed(bytes(0x41, 0x4E, 0x43, 0, 0, 0x80), "unsupported codec version 0")
	expectMalformed(bytes(0x41, 0x4E, 0x43, 1, 1, 0x80), "unknown flags")
	expectMalformed(bytes(0x41, 0x4E, 0x44, 1, 0, 0x80), "header")
	expectMalformed(bytes(0x41, 0x4E, 0x43, 1), "header")
	expectMalformed(buffer.create(0), "header")
	check(not pcall(Codec.decode, "ANC\1\0\128" :: any))
end)

-- scalars -------------------------------------------------------------------------

test("booleans", function()
	roundTrip(true)
	roundTrip(false)
end)

test("integers round trip and are compact", function()
	local cases = {
		0, 1, 2, 63, 64, 127, 128, 255, 256, 16383, 16384, -1, -2, -64, -65, -127, -128, -129,
		2 ^ 31 - 1, 2 ^ 31, -2 ^ 31, 2 ^ 32, 2 ^ 40 + 7, 2 ^ 52 - 1, -(2 ^ 52 - 1),
		2 ^ 52, -2 ^ 52, 2 ^ 53 - 1, -(2 ^ 53 - 1), 2 ^ 53, 2 ^ 60, -2 ^ 63, 1e300,
	}
	for _, x in cases do
		local d = roundTrip(x)
		check(d == x, "integer " .. x)
	end
	check(buffer.len(Codec.encode(127)) == 6, "fixint")
	check(buffer.len(Codec.encode(128)) == 5 + 3, "int 128")
	check(buffer.len(Codec.encode(-1)) == 5 + 2, "int -1")
	check(buffer.len(Codec.encode(1700000000)) <= 5 + 6, "timestamp")
end)

test("floats round trip exactly", function()
	local cases = {
		0.5, -0.5, 0.1, -0.1, 1 / 3, math.pi, 1e-300, 5e-324, -5e-324, 1.7976931348623157e308,
		-1.7976931348623157e308, 2.2250738585072014e-308, 123.456, 1.5, 0.25, 3.4028234663852886e38,
		1e39, 1.401298464324817e-45, 2 ^ 52 + 0.5, 2 ^ 51 + 0.5, 73.4,
	}
	for _, x in cases do
		local d = roundTrip(x)
		check(d == x, "float " .. x)
	end
	check(buffer.len(Codec.encode(0.5)) == 5 + 2, "short decimal 0.5 uses DEC")
	check(buffer.len(Codec.encode(0.0009765625)) == 5 + 5, "f32-exact float uses 4 bytes")
	check(buffer.len(Codec.encode(0.1)) == 5 + 2, "0.1 uses DEC")
	check(buffer.len(Codec.encode(73.4)) == 5 + 3, "73.4 uses DEC")
	check(buffer.len(Codec.encode(1 / 3)) == 5 + 9, "1/3 uses f64")
	check(buffer.len(Codec.encode(0.1 + 0.2)) == 5 + 9, "0.30000000000000004 uses f64")
	for _, x in { 0.1 + 0.2, 1.99, -1.99, 0.000001, -0.000001, 123456.789, 99.99, 0.07, 1e-7, 4503599627370495.5, 1234567.123456 } do
		local d = Codec.decode(Codec.encode(x))
		check(d == x, string.format("decimal %.17g decoded as %.17g", x, d))
	end
	-- every k/10^s for a sweep of k round trips bit-exactly
	for s = 1, 6 do
		local p = 10 ^ s
		for k = -2000, 2000, 7 do
			local x = k / p
			local d = Codec.decode(Codec.encode(x))
			check(d == x and (x ~= 0 or 1 / d > 0), string.format("%.17g", x))
		end
	end
end)

test("-0 round trips as -0", function()
	local d = Codec.decode(Codec.encode(-0.0))
	check(d == 0 and 1 / d < 0, "lost sign of -0")
	local t = Codec.decode(Codec.encode({ x = -0.0, y = { -0.0 } }))
	check(1 / t.x < 0 and 1 / t.y[1] < 0)
	local z = Codec.decode(Codec.encode(0))
	check(1 / z > 0)
end)

test("strings", function()
	local long = string.rep("abcdefghij", 10000)
	for _, s in { "", "a", string.rep("x", 31), string.rep("y", 32), long, "héllo wörld 🎉", "\0nul\0", "日本語" } do
		local d = roundTrip(s)
		check(d == s)
	end
end)

test("buffers pass through", function()
	local b = buffer.create(300)
	for i = 0, 299 do
		buffer.writeu8(b, i, (i * 7) % 256)
	end
	local d = roundTrip({ blob = b, empty = buffer.create(0) })
	check(type(d.blob) == "buffer" and d.blob ~= b)
	check(buffer.tostring(d.blob) == buffer.tostring(b))
	check(buffer.len(d.empty) == 0)
	local raw = roundTrip(b)
	check(buffer.tostring(raw) == buffer.tostring(b))
end)

-- tables --------------------------------------------------------------------------

test("empty tables decode to {}", function()
	local d = roundTrip({})
	check(type(d) == "table" and next(d) == nil)
	local n = roundTrip({ a = {}, b = { {}, {} } })
	check(next(n.a) == nil and #n.b == 2)
	check(buffer.len(Codec.encode({})) == 6)
end)

test("arrays of many sizes", function()
	for _, n in { 1, 2, 15, 16, 17, 127, 128, 1000, 20000 } do
		local t = table.create(n)
		for i = 1, n do
			t[i] = if i % 3 == 0 then "s" .. (i % 10) elseif i % 3 == 1 then i else i + 0.5
		end
		local d = roundTrip(t)
		check(#d == n)
	end
end)

test("maps of many sizes", function()
	for _, n in { 1, 15, 16, 17, 100, 1000, 5000 } do
		local t = {}
		for i = 1, n do
			t["k" .. i] = i
		end
		roundTrip(t)
	end
end)

test("nested structures", function()
	roundTrip({
		Coins = 100,
		Inventory = { "Sword", "Shield", "Sword", { Name = "Bow", Ammo = 30 } },
		Settings = { Music = true, Volume = 0.75, Keys = { Jump = "Space" } },
		Deep = { { { { { "x" } } } } },
		["key with spaces"] = { [""] = "empty key" },
	})
end)

test("map keys and repeated strings are interned", function()
	local owned = {}
	for i = 1, 670 do
		owned["i" .. i] = { Level = i % 50, Rarity = if i % 2 == 0 then "Legendary" else "Common", Locked = false }
	end
	local b = Codec.encode({ Owned = owned })
	local s = buffer.tostring(b)
	local function count(needle: string): number
		local c, init = 0, 1
		while true do
			local a, e = string.find(s, needle, init, true)
			if not a then
				return c
			end
			c += 1
			init = (e :: number) + 1
		end
	end
	check(count("Level") == 1, "key stored more than once")
	check(count("Rarity") == 1)
	check(count("Legendary") == 1, "repeated value stored more than once")
	check(count("Common") == 1)
	check(Codec.equal(Codec.decode(b), { Owned = owned }))
end)

test("string table beyond 32 / 64 / 16384 entries", function()
	local t = {}
	for i = 1, 20000 do
		t["key" .. i] = "val" .. (i % 5000)
	end
	roundTrip(t)
	local arr = {}
	for i = 1, 300 do
		arr[i] = "s" .. (i % 120)
	end
	roundTrip(arr)
end)

test("depth 200 ok, 201 rejected", function()
	local root = {}
	local cur = root
	for _ = 2, 200 do
		local nxt = {}
		cur.n = nxt
		cur = nxt
	end
	cur.leaf = 1
	roundTrip(root)
	cur.n = { 1 }
	local ok, path, reason = Codec.validate(root)
	check(not ok and string.find(reason :: string, "deeper than 200") ~= nil, tostring(reason))
	check(path == "Data" .. string.rep(".n", 200), tostring(path))
end)

test("metatables are ignored (raw access)", function()
	local inner = setmetatable({ a = 1 }, {
		__index = function()
			error("__index called")
		end,
		__iter = function()
			error("__iter called")
		end,
		__len = function()
			error("__len called")
		end,
	})
	local d = roundTrip({ x = inner, arr = setmetatable({ 1, 2, 3 }, { __len = function()
		return 99
	end }) })
	check(getmetatable(d.x) == nil)
	check(#d.arr == 3)
end)

test("shared (non-cyclic) subtables are encoded twice", function()
	local shared = { 1, 2 }
	local d = roundTrip({ a = shared, b = shared })
	check(d.a ~= d.b and Codec.equal(d.a, d.b))
end)

test("deterministic for the same table state", function()
	local t = { a = 1, b = { c = "x", d = { 1, 2, 3 } }, e = 0.1 }
	check(buffer.tostring(Codec.encode(t)) == buffer.tostring(Codec.encode(t)))
end)

test("large values (scratch buffer growth)", function()
	local big = string.rep("z", 5 * 1024 * 1024)
	local d = roundTrip({ big = big, n = 1 })
	check(#d.big == #big)
	-- small encode after a big one still works
	roundTrip({ 1, 2, 3 })
end)

-- invalid values ------------------------------------------------------------------

test("invalid scalars report paths", function()
	expectInvalid({ Owned = { i42 = { Level = 0 / 0 } } }, "Data.Owned.i42.Level", "NaN")
	expectInvalid({ Owned = { i42 = { Level = math.huge } } }, "Data.Owned.i42.Level", "inf")
	expectInvalid({ x = -math.huge }, "Data.x", "inf")
	expectInvalid({ f = function() end }, "Data.f", "function")
	expectInvalid({ list = { 1, 2, coroutine.create(function() end) } }, "Data.list[3]", "thread")
	expectInvalid({ u = newproxy(false) }, "Data.u", "userdata")
	expectInvalid({ v = vector.create(1, 2, 3) }, "Data.v", "vector")
	expectInvalid(nil, "Data", "nil")
	expectInvalid(0 / 0, "Data", "NaN")
	expectInvalid({ ["odd key"] = { s = "\255bad" } }, 'Data["odd key"].s', "UTF%-8")
	expectInvalid({ m = { ["\255"] = 1 } }, 'Data.m["\\255"]', "UTF%-8")
	expectInvalid({ ['a"b\n'] = { x = 0 / 0 } }, 'Data["a\\34b\\10"].x', "NaN")
	expectInvalid({ ["日本"] = { x = 0 / 0 } }, 'Data["日本"].x', "NaN")
	expectInvalid({ surrogate = "\237\160\128" }, "Data.surrogate", "UTF%-8")
end)

test("custom root name", function()
	local ok, path = Codec.validate({ a = { b = 0 / 0 } }, "Profile")
	check(not ok and path == "Profile.a.b", tostring(path))
end)

test("invalid tables report paths", function()
	expectInvalid({ a = { 1, nil, 3 } }, "Data.a", "sparse")
	expectInvalid({ a = { [1] = 1, [3] = 3 } }, "Data.a", "sparse")
	expectInvalid({ a = { [2] = "x" } }, "Data.a", "sparse")
	expectInvalid({ a = { [1000] = "x" } }, "Data.a", "sparse")
	expectInvalid({ a = { 1, 2, x = 3 } }, "Data.a", "mixed")
	expectInvalid({ a = { x = 3, [1] = 1 } }, "Data.a", "mixed")
	expectInvalid({ a = { [0] = 1 } }, "Data.a[0]", "integer key 0")
	expectInvalid({ a = { [-5] = 1 } }, "Data.a[-5]", "integer key %-5")
	expectInvalid({ a = { [1.5] = 1 } }, "Data.a[1.5]", "non%-integer")
	expectInvalid({ a = { [true] = 1 } }, "Data.a[true]", "boolean")
	expectInvalid({ a = { [{}] = 1 } }, "Data.a[<table>]", "table")
end)

test("cycles report the closing reference", function()
	local t = { a = { b = {} } }
	t.a.b.back = t.a
	expectInvalid(t, "Data.a.b.back", "cycle")
	local s = {}
	s.self = s
	expectInvalid(s, "Data.self", "cycle")
	local arr = { {} }
	arr[1][1] = arr
	expectInvalid(arr, "Data[1][1]", "cycle")
end)

-- decoder hardening -----------------------------------------------------------

test("malformed blobs error", function()
	expectMalformed(withHeader(), "end of data")
	expectMalformed(withHeader(0x80, 0x80), "trailing")
	expectMalformed(withHeader(0x00), "unknown tag 0x00")
	expectMalformed(withHeader(0x0B), "unknown tag")
	expectMalformed(withHeader(0x1F), "unknown tag")
	expectMalformed(withHeader(0x40), "reference 0 out of range")
	expectMalformed(withHeader(0x07, 0x05), "reference")
	expectMalformed(withHeader(0x25, 0x61), "exceeds remaining")
	expectMalformed(withHeader(0x06, 0xFF, 0xFF, 0xFF, 0x7F), "exceeds remaining")
	expectMalformed(withHeader(0x08, 0xFF, 0xFF, 0xFF, 0x0F), "exceeds remaining")
	expectMalformed(withHeader(0x09, 0xFF, 0xFF, 0x03), "exceeds remaining")
	expectMalformed(withHeader(0x0A, 0x05, 1, 2), "exceeds remaining")
	expectMalformed(withHeader(0x63, 0x80, 0x80), "exceeds remaining")
	expectMalformed(withHeader(0x63, 0x80, 0x80, 0x0B), "unknown tag")
	-- duplicate map key: {a=1, a=2} via new key then ref
	expectMalformed(withHeader(0x72, 0x03, 0x61, 0x81, 0x00, 0x82), "duplicate")
	-- NaN / inf floats
	expectMalformed(withHeader(0x04, 0, 0, 0, 0, 0, 0, 0xF8, 0x7F), "non%-finite")
	expectMalformed(withHeader(0x04, 0, 0, 0, 0, 0, 0, 0xF0, 0x7F), "non%-finite")
	expectMalformed(withHeader(0x05, 0, 0, 0x80, 0xFF), "non%-finite")
	expectMalformed(withHeader(0x05, 0, 0), "end of data")
	expectMalformed(withHeader(0x10, 0x01), "unknown tag 0x10")
	expectMalformed(withHeader(0x17, 0x01), "unknown tag 0x17")
	expectMalformed(withHeader(0x11), "end of data")
	-- varints
	expectMalformed(withHeader(0x03, 0x80, 0x00), "non%-canonical")
	expectMalformed(withHeader(0x03, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01), "longer than 8")
	expectMalformed(withHeader(0x03, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F), "out of range")
	expectMalformed(withHeader(0x03, 0xFF), "end of data")
	-- invalid UTF-8 string and key
	expectMalformed(withHeader(0x21, 0xFF), "UTF%-8")
	expectMalformed(withHeader(0x71, 0x03, 0xFF, 0x80), "UTF%-8")
	-- map key must reference an existing string
	expectMalformed(withHeader(0x71, 0x00, 0x80), "reference")
end)

test("decoder depth limit", function()
	local t = { 0x41, 0x4E, 0x43, 1, 0 }
	for _ = 1, 200 do
		table.insert(t, 0x61)
	end
	table.insert(t, 0x80)
	local b = bytes(table.unpack(t))
	local d = Codec.decode(b)
	local depth = 0
	while type(d) == "table" do
		depth += 1
		d = d[1]
	end
	check(depth == 200)
	table.insert(t, 6, 0x61)
	expectMalformed(bytes(table.unpack(t)), "deeper than 200")
end)

test("every truncation of a valid blob errors", function()
	local b = Codec.encode({ a = { 1, 2.5, "str", true, { x = "str" } }, b = buffer.create(3), c = -12345 })
	local n = buffer.len(b)
	for len = 0, n - 1 do
		local cut = buffer.create(len)
		buffer.copy(cut, 0, b, 0, len)
		expectMalformed(cut)
	end
end)

-- decodeInto ----------------------------------------------------------------------

test("decodeInto keeps identity and replaces contents", function()
	local target = { old = 1, 10, 20 }
	local mt = {}
	setmetatable(target, mt)
	Codec.decodeInto(Codec.encode({ a = 1, b = { 2 } }), target)
	check(getmetatable(target) == mt)
	check(target.old == nil and target[1] == nil)
	check(Codec.equal(target, { a = 1, b = { 2 } }))
	Codec.decodeInto(Codec.encode({ "x", "y" }), target)
	check(Codec.equal(target, { "x", "y" }))
	Codec.decodeInto(Codec.encode({}), target)
	check(next(target) == nil)
end)

test("decodeInto leaves target intact on malformed input or non-table root", function()
	local target = { keep = "me" }
	local good = Codec.encode({ a = 1, b = "two" })
	local cut = buffer.create(buffer.len(good) - 1)
	buffer.copy(cut, 0, good, 0, buffer.len(cut))
	check(not pcall(Codec.decodeInto, cut, target))
	check(target.keep == "me")
	check(not pcall(Codec.decodeInto, Codec.encode(5), target))
	check(target.keep == "me")
	check(not pcall(Codec.decodeInto, good, table.freeze({})))
	check(not pcall(Codec.decodeInto, good, nil :: any))
end)

-- equal -------------------------------------------------------------------------

test("equal semantics", function()
	local b1, b2 = buffer.fromstring("hello world"), buffer.fromstring("hello world")
	check(Codec.equal(b1, b2))
	check(not Codec.equal(b1, buffer.fromstring("hello worle")))
	check(not Codec.equal(b1, buffer.fromstring("hello")))
	check(Codec.equal({ a = { 1, 2, { b = b1 } } }, { a = { 1, 2, { b = b2 } } }))
	check(not Codec.equal({ a = 1 }, { a = 1, b = 2 }))
	check(not Codec.equal({ a = 1, b = 2 }, { a = 1 }))
	check(not Codec.equal({ 1, 2 }, { 1, 2, 3 }))
	check(not Codec.equal(0, -0.0))
	check(Codec.equal(-0.0, -0.0))
	check(not Codec.equal(1, "1"))
	check(not Codec.equal({}, nil))
	check(Codec.equal(nil, nil))
	check(not Codec.equal(0 / 0, 0 / 0))
	local c = {}
	c.c = c
	check(Codec.equal(c, c))
	local d = {}
	d.c = d
	check(not Codec.equal(c, d)) -- distinct cycles: bounded, returns false
end)

-- report ---------------------------------------------------------------------------

for _, f in failures do
	print("FAIL " .. f)
end
print(string.format("codec_unit: %d passed, %d failed", passed, failed))
print(string.format("RESULT pass=%d fail=%d skip=0", passed, failed))
if failed > 0 then
	error("codec_unit failed", 0)
end
