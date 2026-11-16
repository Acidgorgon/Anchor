--!optimize 2
-- Entry point for tests and benches:
--   luau-bench [--codegen] tests/mock/runner.luau <repoRoot> <file.luau> [args...]
--
-- Installs a harness-level `require` (aliases: "@mock/x" -> tests/mock/x,
-- "@root/x" -> repo root, "@bench/x" -> bench/x; "./x" relative to the caller)
-- then runs <file>. If the file registered tests with the testkit they are run
-- and the process fails when any test failed.

local root = arg[1]
local file = arg[2]
if root == nil or file == nil then
	error("usage: runner.luau <repoRoot> <file.luau>")
end

local cache = {}
local loading = {}

local function normalize(path: string): string
	local parts = {}
	for part in string.gmatch(path, "[^/]+") do
		if part == ".." and #parts > 0 and parts[#parts] ~= ".." then
			table.remove(parts)
		elseif part ~= "." then
			table.insert(parts, part)
		end
	end
	return (if string.sub(path, 1, 1) == "/" then "/" else "") .. table.concat(parts, "/")
end

local function resolve(name: string, fromFile: string): string
	local base
	if string.sub(name, 1, 6) == "@mock/" then
		base = root .. "/tests/mock/" .. string.sub(name, 7)
	elseif string.sub(name, 1, 6) == "@root/" then
		base = root .. "/" .. string.sub(name, 7)
	elseif string.sub(name, 1, 7) == "@bench/" then
		base = root .. "/bench/" .. string.sub(name, 8)
	elseif string.sub(name, 1, 1) == "/" then
		base = name
	else
		local dir = string.match(fromFile, "^(.*)/[^/]*$") or "."
		base = dir .. "/" .. name
	end
	base = normalize(base)
	for _, candidate in { base, base .. ".luau", base .. ".lua", base .. "/init.luau" } do
		if listdir(candidate) == nil and readfile(candidate) ~= nil then
			return candidate
		end
	end
	error(`require("{name}"): no file at {base}`, 3)
end

local function harnessRequire(name: string)
	local source = debug.info(2, "s")
	local first = string.sub(source, 1, 1)
	local fromFile = if first == "@" then string.sub(source, 2) elseif first == "=" or first == "[" then root .. "/x" else source
	local path = resolve(name, fromFile)
	local cached = cache[path]
	if cached ~= nil then
		return cached
	end
	if loading[path] then
		error(`cyclic harness require of {path}`, 2)
	end
	loading[path] = true
	local fn, err = loadstring(readfile(path) :: string, "@" .. path)
	if fn == nil then
		error(`failed to compile {path}: {err}`, 2)
	end
	local result = fn()
	loading[path] = nil
	cache[path] = if result == nil then true else result
	return result
end

(_G :: any).require = harnessRequire

local Sim = harnessRequire("@mock/sim")
Sim.root = root
Sim._mainThread = coroutine.running()
Sim.world.sched.mainThread = Sim._mainThread

local path = normalize(if string.sub(file, 1, 1) == "/" then file else root .. "/" .. file)
local src = readfile(path)
if src == nil then
	error(`cannot read {path}`)
end
local main, err = loadstring(src, "@" .. path)
if main == nil then
	error(err)
end
main(table.unpack(arg, 3))

-- Run registered tests (if the file used the testkit).
local T = cache[normalize(root .. "/tests/mock/testkit.luau")]
if type(T) == "table" then
	local _, failed = T.run(getenv("ANCHOR_TEST_FILTER"))
	if failed > 0 then
		__exit(1)
	end
end
