-- [review] Compact + IsDirty/ClearDirty (the Ripple seam, spec 3/7) with a skip-capable
-- AUTO_SAVE_PERIOD: the Compact blob is encoded before the UpdateAsync yield, but
-- ClearDirty runs inside the transform (after the yield). A change made while the save
-- is in flight is not in the written blob, yet its dirty flag is cleared, so every
-- following autosave is skipped as "clean" until the lock-refresh write. The game asked
-- for a save every 30 s; the change stays unsaved for ~LockRefresh (300 s) and a crash
-- in that window loses it. Compat (live Data written in the transform) is the control.
local T = require("@mock/testkit")
local Sim = require("@mock/sim")

local TEMPLATE = { Coins = 0 }

for _, format in { "Compat", "Compact" } do
	T.test(`{format}: change made during an in-flight save is autosaved within AUTO_SAVE_PERIOD (IsDirty hook)`, function()
		T.allowThreadErrors()
		Sim.configure({ latency = 1 })
		local s = Sim.newServer({ JobId = "S1" })
		local A = s:require("src", { name = "Anchor" })
		A.SetConstant("AUTO_SAVE_PERIOD", 30)
		local dirty = false
		local store = A.New("PlayerData", TEMPLATE, {
			Format = format,
			IsDirty = function()
				return dirty
			end,
			ClearDirty = function()
				dirty = false
			end,
		})
		local p = s:await(store.StartSessionAsync, store, "Player_1")
		Sim.advance(40)
		p:Save() -- in flight
		dirty = true -- a tracked write (Ripple marks the root dirty) in the same tick
		p.Data.Coins = 777
		Sim.advance(4 * 30) -- four autosave periods
		T.eq(
			Sim.peek("PlayerData", "Player_1").Data.Coins
				or (Sim.peek("PlayerData", "Player_1").Data.AnchorBlob and s:require("src/Codec.luau").decode(
					Sim.peek("PlayerData", "Player_1").Data.AnchorBlob
				).Coins),
			777,
			`still unsaved after 4 autosave periods (skipped_saves = {p.skipped_saves}, dirty flag = {tostring(dirty)})`
		)
	end)
end
