-- Compact format safety: poison without a blob refuses to load, keys beside the blob are
-- ignored and reported, and ClearDirty never marks clean data that didn't land.
local T = require("@mock/testkit")
local Sim = require("@mock/sim")

local TEMPLATE = { Coins = 0, Items = {} }

local function compactSave(coins)
	local s = Sim.newServer({ JobId = "SEED" })
	local store = s:require("src", { name = "Anchor" }).New("PlayerData", TEMPLATE, { Format = "Compact" })
	local p = s:await(store.StartSessionAsync, store, "Player_1")
	p.Data.Coins = coins
	p:EndSession()
	Sim.advance(2)
	local raw = Sim.peek("PlayerData", "Player_1")
	T.eq(raw.MetaData.SessionLoadCount, "Anchor")
	T.eq(typeof(raw.Data.AnchorBlob), "buffer")
	return raw
end

local function errorsOf(A)
	local errors = {}
	A.OnError:Connect(function(message)
		table.insert(errors, message)
	end)
	return errors
end

for _, format in { "Compat", "Compact" } do
	T.test(`{format} store: poisoned counter with plain Data (no blob) refuses to load and leaves the key untouched`, function()
		local raw = compactSave(5000)
		raw.Data = { Coins = 0, Items = {} } -- e.g. a tool replaced Data wholesale
		Sim.poke("PlayerData", "Player_1", raw)
		local versions = #Sim.versions("PlayerData", "Player_1")

		local s = Sim.newServer({ JobId = "LOAD" })
		local A = s:require("src", { name = "Anchor" })
		local errors = errorsOf(A)
		local store = A.New("PlayerData", TEMPLATE, { Format = format })
		local p = s:await(store.StartSessionAsync, store, "Player_1")
		T.eq(p, nil, "session refused")
		T.expect(#errors >= 1, "OnError fired")
		T.expect(string.find(errors[1], "AnchorBlob", 1, true), errors[1])
		T.eq(s:await(store.GetAsync, store, "Player_1"), nil, "view refused too")
		Sim.advance(5)
		local after = Sim.peek("PlayerData", "Player_1")
		T.eq(after.MetaData.SessionLoadCount, "Anchor", "still poisoned")
		T.eq(after.MetaData.ActiveSession, nil, "lock released")
		T.deepEq(after.Data, { Coins = 0, Items = {} }, "Data not rewritten")
		T.expect(#Sim.versions("PlayerData", "Player_1") <= versions + 2, "only lock writes")
	end)
end

T.test("Bind kicks when the stored profile is poisoned without a blob", function()
	local raw = compactSave(10)
	raw.Data = { Coins = 0 }
	Sim.poke("PlayerData", "Player_1", raw)
	local s = Sim.newServer({ JobId = "BIND" })
	local A = s:require("src", { name = "Anchor" })
	local Data = A.new("PlayerData", TEMPLATE, { Format = "Compact" })
	Data:Bind()
	s:addPlayer(1)
	Sim.advance(5)
	T.eq((s:wasKicked(1)), true)
end)

T.test("keys beside the blob: the blob is loaded, the keys ignored, OnError names them, next save drops them", function()
	local raw = compactSave(5000)
	raw.Data.Flagged = true
	raw.Data.Coins = 0
	Sim.poke("PlayerData", "Player_1", raw)

	local s = Sim.newServer({ JobId = "LOAD" })
	local A = s:require("src", { name = "Anchor" })
	local errors = errorsOf(A)
	local store = A.New("PlayerData", TEMPLATE, { Format = "Compact" })
	local view = s:await(store.GetAsync, store, "Player_1")
	T.eq(view.Data.Coins, 5000)
	local p = s:await(store.StartSessionAsync, store, "Player_1")
	T.eq(p.Data.Coins, 5000)
	T.eq(p.Data.Flagged, nil)
	T.expect(#errors >= 2, T.show(errors))
	T.expect(string.find(errors[#errors], "Coins, Flagged", 1, true), errors[#errors])
	T.eq(s:await(p.SaveAsync, p), true)
	local stored = Sim.peek("PlayerData", "Player_1").Data
	T.eq(stored.Flagged, nil)
	T.eq(stored.Coins, nil)
	T.eq(s:require("src/Codec.luau").decode(stored.AnchorBlob).Coins, 5000)
end)

for _, format in { "Compat", "Compact" } do
	T.test(`{format}: ClearDirty ran but the write failed -> the profile stays dirty until a write lands`, function()
		T.allowThreadErrors()
		local s = Sim.newServer()
		local A = s:require("src", { name = "Anchor" })
		A.SetConstant("AUTO_SAVE_PERIOD", 30)
		local dirty = false
		local clears = 0
		local store = A.New("PlayerData", TEMPLATE, {
			Format = format,
			IsDirty = function()
				return dirty
			end,
			ClearDirty = function()
				clears += 1
				dirty = false
			end,
		})
		local p = s:await(store.StartSessionAsync, store, "Player_1")
		Sim.advance(40)
		dirty = true
		p.Data.Coins = 5
		p.Data.Items.Bad = { 1, 2, Mixed = true } -- the DataStore rejects this write
		Sim.advance(30)
		T.expect(clears >= 1, "ClearDirty ran inside the failed write")
		T.eq(dirty, false)
		p.Data.Items.Bad = nil -- fixed without the hook seeing a change
		Sim.advance(31)
		local stored = Sim.peek("PlayerData", "Player_1").Data
		if stored.AnchorBlob then
			stored = s:require("src/Codec.luau").decode(stored.AnchorBlob)
		end
		T.eq(stored.Coins, 5, `change lost after a failed write (skipped_saves = {p.skipped_saves})`)
		-- and once a write landed, the hook is trusted again
		local skipped = p.skipped_saves
		Sim.advance(60)
		T.expect(p.skipped_saves > skipped, "clean autosaves skipped again")
	end)
end
