--!optimize 2
-- Bench helpers for Anchor vs stock ProfileStore. Bench files run through the
-- same runner as tests, so they can use the Roblox mock:
--
--   local Bench = require("@bench/harness")
--   local Sim = require("@mock/sim")
--   local r = Bench.time("encode FM profile", function() Codec.encode(data) end)
--   local a = Bench.alloc("encode FM profile", function() Codec.encode(data) end)
--   Bench.report("Codec", { r, a })
--
-- Run: bench/harness.sh [bench/x_bench.luau ...]   (native codegen, -O2)
--
-- Measurements (real time, not virtual time):
--   time(name, fn, opts)     -> {name, iters, perIterUs (median of runs), minUs, runs}
--   alloc(name, fn, opts)    -> {name, allocBytes, allocCount} per call (GC stopped)
--   retained(name, build)    -> {name, retainedBytes} heap still held by build()'s result
--   sizes(name, value|buffer)-> {name, jsonBytes, bufferBytes?, base64Bytes?}
--   dumpBlob(name, data)     -> writes <results>/blobs/<name>.bin for the zstd step
--   delta(before, after)     -> numeric diff of two counter tables (server.stats)
--   report(title, rows)      -> prints rows; writes <results>/<title>.json
-- <results> = $ANCHOR_BENCH_RESULTS or bench/results (harness.sh creates it).

local JSON = require("@mock/json")

local Bench = {}

local function resultsDir(): string
	local dir = getenv("ANCHOR_BENCH_RESULTS")
	if dir and dir ~= "" then
		return dir
	end
	local Sim = require("@mock/sim")
	return Sim.root .. "/bench/results"
end

local function median(xs: { number }): number
	local s = table.clone(xs)
	table.sort(s)
	local n = #s
	if n % 2 == 1 then
		return s[(n + 1) // 2]
	end
	return (s[n // 2] + s[n // 2 + 1]) / 2
end

-- Bench.time(name, fn, {runs = 7, minTime = 0.05, iters = nil, setup = nil})
-- Calibrates iterations so one run takes >= minTime seconds.
function Bench.time(name: string, fn: () -> (), opts)
	opts = opts or {}
	local runs = opts.runs or 7
	local minTime = opts.minTime or 0.05
	if opts.setup then
		opts.setup()
	end
	fn() -- warm up
	local iters = opts.iters
	if iters == nil then
		iters = 1
		while true do
			local t0 = os.clock()
			for _ = 1, iters do
				fn()
			end
			local dt = os.clock() - t0
			if dt >= minTime or iters >= 1e7 then
				break
			end
			iters = math.max(iters * 2, math.ceil(iters * minTime / math.max(dt, 1e-9)))
		end
	end
	local samples = {}
	for r = 1, runs do
		local t0 = os.clock()
		for _ = 1, iters do
			fn()
		end
		samples[r] = (os.clock() - t0) / iters * 1e6
	end
	table.sort(samples)
	return { name = name, iters = iters, perIterUs = median(samples), minUs = samples[1], runs = runs }
end

-- Allocations of one call (average over `iters` calls), with the GC stopped so
-- collections do not interleave.
function Bench.alloc(name: string, fn: () -> (), opts)
	opts = opts or {}
	local iters = opts.iters or 10
	fn()
	__gc("collect")
	__gc("stop")
	local b0, c0 = __alloc_bytes(), __alloc_count()
	for _ = 1, iters do
		fn()
	end
	local b1, c1 = __alloc_bytes(), __alloc_count()
	__gc("restart")
	__gc("collect")
	return { name = name, allocBytes = (b1 - b0) / iters, allocCount = (c1 - c0) / iters }
end

-- Heap bytes retained by whatever build() returns (kept alive until measured).
function Bench.retained(name: string, build: () -> any)
	__gc("collect")
	__gc("collect")
	local before = __live_bytes()
	local keep = build()
	__gc("collect")
	__gc("collect")
	local after = __live_bytes()
	local _ = keep
	return { name = name, retainedBytes = after - before }
end

-- Saved size of a value: JSON text length as the DataStore counts it; for a
-- buffer also raw bytes and base64 length (Roblox may zstd-compress buffers
-- in JSON: Studio-only, see dumpBlob + harness.sh).
function Bench.sizes(name: string, value: any)
	local row = { name = name, jsonBytes = #JSON.encode(value) }
	if type(value) == "buffer" then
		row.bufferBytes = buffer.len(value)
		row.base64Bytes = 4 * math.ceil(buffer.len(value) / 3)
	end
	return row
end

function Bench.dumpBlob(name: string, data: buffer | string)
	local dir = resultsDir() .. "/blobs"
	local text = if type(data) == "buffer" then buffer.tostring(data) else data
	if not writefile(`{dir}/{name}.bin`, text) then
		print(`(bench) could not write {dir}/{name}.bin - create the directory first`)
	end
end

function Bench.delta(before, after)
	local out = {}
	for k, v in after do
		if type(v) == "number" then
			out[k] = v - ((before and before[k]) or 0)
		elseif type(v) == "table" then
			out[k] = Bench.delta(before and before[k], v)
		end
	end
	return out
end

-- Deep snapshot of a counter table (e.g. server.stats) for later delta().
function Bench.snapshot(t)
	local out = {}
	for k, v in t do
		out[k] = if type(v) == "table" then Bench.snapshot(v) else v
	end
	return out
end

local function fmt(v: any): string
	if type(v) == "number" then
		if v == math.floor(v) and math.abs(v) < 1e15 then
			return string.format("%d", v)
		end
		return string.format("%.3f", v)
	end
	return tostring(v)
end

function Bench.report(title: string, rows: { { [string]: any } })
	local columns = { "name" }
	local seen = { name = true }
	for _, row in rows do
		local keys = {}
		for k in row do
			if not seen[k] then
				table.insert(keys, k)
			end
		end
		table.sort(keys)
		for _, k in keys do
			seen[k] = true
			table.insert(columns, k)
		end
	end
	local widths = {}
	for i, c in columns do
		widths[i] = #c
		for _, row in rows do
			widths[i] = math.max(widths[i], #fmt(row[c] or ""))
		end
	end
	print(`\n## {title}  ({if __native() then "native" else "interpreted"}, -O{__optlevel()})`)
	local function line(cells)
		local parts = {}
		for i, cell in cells do
			parts[i] = if i == 1 then string.format(`%-{widths[i]}s`, cell) else string.format(`%{widths[i]}s`, cell)
		end
		print(table.concat(parts, "  "))
	end
	line(columns)
	for _, row in rows do
		local cells = {}
		for i, c in columns do
			cells[i] = fmt(row[c] or "")
		end
		line(cells)
	end
	local file = `{resultsDir()}/{string.gsub(title, "[^%w%-_]", "_")}.json`
	writefile(file, JSON.encode({ title = title, native = __native(), rows = rows }))
end

return Bench
