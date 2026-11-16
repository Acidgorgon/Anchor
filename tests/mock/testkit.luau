--!optimize 2
-- Tiny test API.
--
--   local T = require("@mock/testkit")
--   local Sim = require("@mock/sim")
--   T.test("name", function()
--       T.eq(1 + 1, 2)
--   end)
--
-- Every test starts with a fresh Sim world (Sim.reset()). A test fails if its
-- function errors, an assertion fails, or any simulated thread raised an
-- uncaught error during the test (call T.allowThreadErrors() to permit them).
-- The runner calls T.run() after loading the file.

local Sim = require("./sim")

local T = {}

local tests = {}
local allowThreadErrors = false

function T.test(name: string, fn: () -> ())
	table.insert(tests, { name = name, fn = fn })
end

function T.skip(name: string, _fn: () -> ())
	table.insert(tests, { name = name, skip = true })
end

function T.allowThreadErrors()
	allowThreadErrors = true
end

local function show(v: any, depth: number?): string
	depth = depth or 0
	if type(v) == "string" then
		return string.format("%q", v)
	elseif type(v) ~= "table" then
		return tostring(v)
	elseif (depth :: number) > 3 then
		return "{...}"
	end
	local keys = {}
	for k in v do
		table.insert(keys, k)
	end
	table.sort(keys, function(a, b)
		return tostring(a) < tostring(b)
	end)
	local parts = {}
	for i, k in keys do
		if i > 12 then
			table.insert(parts, "...")
			break
		end
		table.insert(parts, `[{show(k)}] = {show(v[k], (depth :: number) + 1)}`)
	end
	return "{" .. table.concat(parts, ", ") .. "}"
end

T.show = show

local function fail(msg: string, level: number?)
	error(msg, (level or 1) + 2)
end

function T.expect(cond: any, msg: string?)
	if not cond then
		fail("expectation failed" .. (if msg then ": " .. msg else ""))
	end
	return cond
end

function T.eq(actual: any, expected: any, msg: string?)
	if actual ~= expected then
		fail(`expected {show(expected)}, got {show(actual)}` .. (if msg then " (" .. msg .. ")" else ""))
	end
end

function T.neq(actual: any, unexpected: any, msg: string?)
	if actual == unexpected then
		fail(`expected anything but {show(unexpected)}` .. (if msg then " (" .. msg .. ")" else ""))
	end
end

-- Deep equality (tables by structure; buffers by content). Returns path of first difference.
local function diff(a: any, b: any, path: string): string?
	if a == b then
		return nil
	end
	local ta, tb = type(a), type(b)
	if ta ~= tb then
		return `{path}: {show(a)} vs {show(b)}`
	end
	if ta == "buffer" then
		if buffer.tostring(a) == buffer.tostring(b) then
			return nil
		end
		return `{path}: buffers differ`
	end
	if ta ~= "table" then
		if ta == "number" and a ~= a and b ~= b then
			return nil
		end
		return `{path}: {show(a)} vs {show(b)}`
	end
	for k, v in a do
		local d = diff(v, b[k], `{path}.{tostring(k)}`)
		if d then
			return d
		end
	end
	for k, v in b do
		if a[k] == nil then
			return `{path}.{tostring(k)}: nil vs {show(v)}`
		end
	end
	return nil
end

T.diff = function(a, b)
	return diff(a, b, "value")
end

function T.deepEq(actual: any, expected: any, msg: string?)
	local d = diff(actual, expected, "value")
	if d then
		fail(`not deep-equal: {d}` .. (if msg then " (" .. msg .. ")" else ""))
	end
end

-- T.throws(fn, pattern?) -> error message
function T.throws(fn: () -> (), pattern: string?): string
	local ok, err = pcall(fn)
	if ok then
		fail("expected an error")
	end
	local msg = tostring(err)
	if pattern and not string.find(msg, pattern) then
		fail(`error {show(msg)} does not match {show(pattern)}`)
	end
	return msg
end

function T.near(actual: number, expected: number, tolerance: number, msg: string?)
	if math.abs(actual - expected) > tolerance then
		fail(`expected {expected} +- {tolerance}, got {actual}` .. (if msg then " (" .. msg .. ")" else ""))
	end
end

-- Runs every registered test; returns passed, failed.
function T.run(filter: string?): (number, number)
	local passed, failed, skipped = 0, 0, 0
	for _, t in tests do
		if t.skip then
			skipped += 1
			print(`  SKIP  {t.name}`)
			continue
		end
		if filter and filter ~= "" and not string.find(t.name, filter, 1, true) then
			continue
		end
		Sim.reset()
		allowThreadErrors = false
		local started = os.clock()
		local ok, err = xpcall(t.fn, function(e)
			return debug.traceback(tostring(e), 2)
		end)
		local real = (os.clock() - started) * 1000
		if ok and not allowThreadErrors and #Sim.threadErrors() > 0 then
			ok = false
			local first = Sim.threadErrors()[1]
			err = `{#Sim.threadErrors()} uncaught simulated-thread error(s); first:\n{first.traceback}`
		end
		local timing = string.format("(virtual %.1fs, %.0fms)", Sim.now(), real)
		if ok then
			passed += 1
			print(`  PASS  {t.name} {timing}`)
		else
			failed += 1
			print(`  FAIL  {t.name} {timing}`)
			for line in string.gmatch(tostring(err), "[^\n]+") do
				print("        " .. line)
			end
		end
	end
	print(`RESULT pass={passed} fail={failed} skip={skipped}`)
	return passed, failed
end

return T
