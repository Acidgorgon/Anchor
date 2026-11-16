-- Review: patches redone onto data whose shape changed since the patch was diffed.
-- An "Inc" (or "Set") below a key that was removed in the meantime recreates the missing
-- parents, so a sold/deleted item comes back as a partial stub. An "Inc" onto a value that
-- is no longer a number silently replaces it.
local T = require("@mock/testkit")
local Sim = require("@mock/sim")

local TEMPLATE = { Coins = 0, Pets = {} }

local function anchor(server)
	return server:require("src", { name = "Anchor" })
end

T.test("Gift levels up a pet the player sold meanwhile: a stub pet {Level=1} appears", function()
	local s1 = Sim.newServer({ JobId = "S1" })
	local s2 = Sim.newServer({ JobId = "S2" })
	local D1 = anchor(s1).new("Main", TEMPLATE)
	local D2 = anchor(s2).new("Main", TEMPLATE)
	D2:Bind()
	local p = s2:addPlayer(5)
	local prof = s2:await(D2.Await, D2, p)
	prof.Data.Pets.Dog = { Name = "Rex", Level = 4 }
	T.eq(s2:await(prof.SaveAsync, prof), true)

	-- S1 gifts +1 level to the dog (diffed against the saved data)...
	T.eq(s1:await(D1.Gift, D1, 5, function(data)
		if data.Pets.Dog then
			data.Pets.Dog.Level += 1
		end
	end), true)
	-- ...while on S2 the player sells the dog before the message is picked up.
	prof.Data.Pets.Dog = nil
	prof.Data.Coins += 50
	Sim.advance(400)
	print(`    after gift: {T.show(prof.Data)}`)
	T.eq(prof.Data.Pets.Dog, nil, "a sold pet must not come back as a stub")
end)

T.test("Patch.apply: Inc onto a value that became a table replaces the table", function()
	local s = Sim.newServer({ JobId = "S1" })
	local Anchor = anchor(s)
	local data = { Coins = { Amount = 70, Locked = true } } -- migrated shape
	Anchor.Patch.apply(data, { { "Inc", { "Coins" }, 5 } })
	print(`    after Inc: {T.show(data)}`)
	T.eq(type(data.Coins), "table", "a stale Inc must not destroy the migrated table")
end)
