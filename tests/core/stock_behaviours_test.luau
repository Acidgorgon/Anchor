-- "Ours passes the same": re-runs every stock ProfileStore behaviour suite in
-- tests/stock/ with the module path swapped to Anchor (src/). Test bodies are
-- untouched, so any behaviour stock has on the mock, Anchor must have too.
local T = require("@mock/testkit")
local Sim = require("@mock/sim")

local root = Sim.root
local dir = root .. "/tests/stock"
local files = {}
for _, entry in listdir(dir) or {} do
	if not entry.dir and string.match(entry.name, "_test%.luau$") then
		table.insert(files, entry.name)
	end
end
table.sort(files)

local realTest, realSkip = T.test, T.skip
for _, name in files do
	local path = dir .. "/" .. name
	local src = readfile(path) :: string
	local swapped, n = string.gsub(src, '"reference/ProfileStore%-1%.0%.3%.luau"', '"src"')
	assert(n > 0, `{name}: stock module path not found`)
	local fn, err = loadstring(swapped, "@" .. path)
	assert(fn, err)
	T.test = function(testName, body)
		realTest(`[Anchor as stock] {name}: {testName}`, body)
	end
	T.skip = function(testName, body)
		realSkip(`[Anchor as stock] {name}: {testName}`, body)
	end
	fn()
end
T.test, T.skip = realTest, realSkip
