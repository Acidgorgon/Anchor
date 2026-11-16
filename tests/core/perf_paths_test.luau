-- SPEC section 9 cost contract, checked by counting Codec calls: Compat does no Codec
-- work on the happy path; Compact pays one encode + one verify per transform run and
-- reuses that blob (skip baseline, LastSavedData); Codec.validate runs only after a failed write, to name the bad path.
local T = require("@mock/testkit")
local Sim = require("@mock/sim")

local TEMPLATE = { Coins = 0, Items = {}, Settings = { Music = true } }

-- Boots Anchor on `s` with a counting wrapper in place of src/Codec.luau (the server's
-- module cache is keyed by path, so Core and Envelope get the wrapper).
local function bootCounted(s)
	local real = s:require("src/Codec.luau")
	local counts = { encode = 0, decode = 0, decodeInto = 0, validate = 0, equal = 0, dataEncode = 0 }
	local watched = {}
	local wrapper = {}
	for name, fn in real do
		if type(fn) == "function" then
			wrapper[name] = function(value, ...)
				counts[name] = (counts[name] or 0) + 1
				if name == "encode" and watched[value] then
					counts.dataEncode += 1
				end
				return fn(value, ...)
			end
		else
			wrapper[name] = fn
		end
	end
	local replaced = false
	for path, mod in s.modules do
		if mod == real then
			s.modules[path] = wrapper
			replaced = true
		end
	end
	assert(replaced, "Codec module not found in the server cache")
	local A = s:require("src", { name = "Anchor" })
	local function reset()
		for k in counts do
			counts[k] = 0
		end
	end
	local function watch(t)
		watched[t] = true
	end
	return A, counts, reset, watch
end

local function load(s, store, key)
	return s:await(store.StartSessionAsync, store, key)
end

local function total(counts)
	return counts.encode + counts.decode + counts.decodeInto + counts.validate + counts.equal
end

T.test("Compat at default constants: load, autosaves, Save, SaveAsync, messages, release make zero Codec calls", function()
	local s = Sim.newServer({ JobId = "A" })
	local A, counts, reset = bootCounted(s)
	local store = A.New("PlayerData", TEMPLATE)
	reset()
	local p = load(s, store, "Player_1")
	p:Reconcile()
	p:AddUserId(1)
	for i = 1, 3 do
		p.Data.Coins = i
		Sim.advance(310) -- dirty autosave
	end
	Sim.advance(310) -- clean autosave (written anyway: skip can't trigger at defaults)
	p.Data.Coins = 50
	p:Save()
	Sim.advance(2)
	T.eq(s:await(p.SaveAsync, p), true)
	s:await(store.MessageAsync, store, "Player_1", { Gift = 1 })
	Sim.advance(2)
	p:EndSession()
	Sim.advance(2)
	T.eq(Sim.peek("PlayerData", "Player_1").Data.Coins, 50)
	T.eq(total(counts), 0, `Codec calls: {T.show(counts)}`)
	local _ = A
end)

T.test("Compat GetAsync view and failed-free saves never validate", function()
	local s = Sim.newServer()
	local A, counts, reset = bootCounted(s)
	local store = A.New("PlayerData", TEMPLATE)
	local p = load(s, store, "Player_1")
	p:EndSession()
	Sim.advance(2)
	reset()
	local view = s:await(store.GetAsync, store, "Player_1")
	view.Data.Coins = 4
	s:await(view.SetAsync, view)
	T.eq(total(counts), 0, T.show(counts))
end)

T.test("validate runs only after a failed write, and names the bad path in that call's OnError", function()
	local s = Sim.newServer()
	local A, counts, reset = bootCounted(s)
	local store = A.New("PlayerData", TEMPLATE)
	local p = load(s, store, "Player_1")
	local errors = {}
	A.OnError:Connect(function(m)
		table.insert(errors, m)
	end)
	reset()
	p.Data.Settings.Bad = { 1, 2, Mixed = true }
	T.eq(s:await(p.SaveAsync, p), false)
	T.eq(counts.validate, 1, "validated once, after the failure")
	T.eq(#errors, 1)
	T.expect(string.find(errors[1], "Data.Settings.Bad", 1, true), errors[1])

	-- A transient DataStore error with valid data: validate runs, finds nothing, message unchanged.
	p.Data.Settings.Bad = nil
	Sim.injectError({ method = "UpdateAsync", count = 1, message = "502: transient" })
	T.eq(s:await(p.SaveAsync, p), false)
	T.eq(errors[2], "502: transient")
	reset()
	T.eq(s:await(p.SaveAsync, p), true)
	T.eq(counts.validate, 0, "no validate on success")
end)

T.test("LastSavedData = false: no load copy, nil after saves, data still saved", function()
	local s = Sim.newServer()
	local A = s:require("src", { name = "Anchor" })
	for _, format in { "Compat", "Compact" } do
		local name = "PlayerData_" .. format
		local store = A.New(name, TEMPLATE, { Format = format, LastSavedData = false })
		local p = load(s, store, "Player_1")
		T.eq(rawget(p, "LastSavedData"), nil)
		T.eq(p.LastSavedData, nil)
		p.Data.Coins = 7
		local received = "unset"
		p.OnAfterSave:Connect(function(lsd)
			received = lsd
		end)
		T.eq(s:await(p.SaveAsync, p), true)
		T.eq(p.LastSavedData, nil, format)
		T.eq(received, nil, "OnAfterSave gets nil")
		p:EndSession()
		Sim.advance(2)
		local again = load(s, store, "Player_1")
		T.eq(again.Data.Coins, 7)
		T.eq(again.LastSavedData, nil, format .. " reload")
		again:EndSession()
		Sim.advance(2)
	end
end)

T.test("Compact save: one encode, one decode, one equal; load: one decode, no encode or verify", function()
	local s = Sim.newServer()
	local A, counts, reset, watch = bootCounted(s)
	local store = A.New("PlayerData", TEMPLATE, { Format = "Compact" })
	local p = load(s, store, "Player_1")
	watch(p.Data)
	reset()
	p.Data.Coins = 1
	T.eq(s:await(p.SaveAsync, p), true)
	T.deepEq(counts, { encode = 1, decode = 1, decodeInto = 0, validate = 0, equal = 1, dataEncode = 1 })
	reset()
	p.Data.Coins = 2
	Sim.advance(310) -- dirty autosave at default constants (skip can't trigger)
	T.deepEq(counts, { encode = 1, decode = 1, decodeInto = 0, validate = 0, equal = 1, dataEncode = 1 })
	p:EndSession()
	Sim.advance(2)

	reset()
	local again = load(s, store, "Player_1")
	T.eq(counts.encode, 0)
	T.eq(counts.equal, 0)
	T.eq(counts.decode + counts.decodeInto, 1, "Data decoded once")
	T.eq(again.Data.Coins, 2)
	T.eq(again.LastSavedData.Coins, 2) -- lazily decoded from the stored buffer
	T.eq(counts.decode + counts.decodeInto, 2)
end)

T.test("Compact with a skip-capable period: one compare encode, then one encode + verify inside the write", function()
	local s = Sim.newServer()
	local A, counts, reset, watch = bootCounted(s)
	A.SetConstant("AUTO_SAVE_PERIOD", 30)
	local store = A.New("PlayerData", TEMPLATE, { Format = "Compact" })
	local p = load(s, store, "Player_1")
	watch(p.Data)
	T.eq(s:await(p.SaveAsync, p), true) -- baseline blob
	reset()
	p.Data.Coins = 5
	Sim.advance(32) -- dirty autosave: the skip check encodes once; the write takes its own
	-- snapshot inside the transform (Data may change while the call is in flight)
	T.eq(Sim.peek("PlayerData", "Player_1").MetaData.Anchor ~= nil, true)
	T.eq(counts.dataEncode, 2, T.show(counts))
	T.eq(counts.decode, 1)
	T.eq(counts.equal, 1)
	reset()
	local skippedBefore = p.skipped_saves
	Sim.advance(30) -- clean autosave: one compare encode, skipped
	T.eq(p.skipped_saves, skippedBefore + 1)
	T.eq(counts.dataEncode, 1)
	T.eq(counts.decode, 0)
	-- the written blob decodes to the data
	T.eq(p.LastSavedData.Coins, 5)
end)

T.test("Compat with an IsDirty hook: clean autosaves skipped with no Data encode at all", function()
	local s = Sim.newServer()
	local A, counts, reset, watch = bootCounted(s)
	A.SetConstant("AUTO_SAVE_PERIOD", 30)
	local dirty = false
	local store = A.New("PlayerData", TEMPLATE, {
		IsDirty = function()
			return dirty
		end,
		ClearDirty = function()
			dirty = false
		end,
	})
	local p = load(s, store, "Player_1")
	watch(p.Data)
	reset()
	Sim.advance(200)
	T.expect(p.skipped_saves >= 4, `skipped {p.skipped_saves}`)
	dirty = true
	p.Data.Coins = 3
	Sim.advance(31)
	T.eq(Sim.peek("PlayerData", "Player_1").Data.Coins, 3)
	T.eq(counts.dataEncode, 0, T.show(counts))
	T.eq(counts.decode + counts.validate + counts.equal, 0)
end)

T.test("Compat with a skip-capable period: at most one Data encode per autosave, skips still happen", function()
	local s = Sim.newServer()
	local A, counts, reset, watch = bootCounted(s)
	A.SetConstant("AUTO_SAVE_PERIOD", 30)
	local store = A.New("PlayerData", TEMPLATE)
	local p = load(s, store, "Player_1")
	watch(p.Data)
	local perSave = {}
	p.OnSave:Connect(function()
		table.insert(perSave, counts.dataEncode)
	end)
	for i = 1, 4 do -- active: a change every period
		p.Data.Coins = i
		Sim.advance(30)
	end
	for _ = 1, 4 do -- then idle
		Sim.advance(30)
	end
	table.insert(perSave, counts.dataEncode)
	for i = 2, #perSave do
		T.expect(perSave[i] - perSave[i - 1] <= 1, `autosave {i - 1} encoded Data {perSave[i] - perSave[i - 1]} times`)
	end
	T.expect(p.skipped_saves >= 2, `skipped {p.skipped_saves}`)
	T.eq(Sim.peek("PlayerData", "Player_1").Data.Coins, 4)
	T.eq(counts.validate + counts.decode + counts.equal, 0)
end)
