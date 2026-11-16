-- Review: a trade whose PB pushes B over the 4 MB DataStore limit. Patch.check validates
-- value types but not size, so the trade commits ("true"), A's save loses the item, B's
-- in-memory copy gets it but no save of B can ever land again, and the message fallback
-- cannot fit in B's key either. After the server shuts down the item exists nowhere
-- except in A's stuck pending record, and B's whole post-trade session is lost.
local T = require("@mock/testkit")
local Sim = require("@mock/sim")

local TEMPLATE = { Coins = 0, Items = {} }

local function anchor(server)
	return server:require("src", { name = "Anchor" })
end

local function blob(n, seed)
	local parts = table.create(n // 1000)
	local x = seed
	for i = 1, n // 1000 do
		local chunk = table.create(1000)
		for j = 1, 1000 do
			x = (x * 1103515245 + 12345) % 2147483648
			chunk[j] = string.char(97 + (x // 65536) % 26)
		end
		parts[i] = table.concat(chunk)
	end
	return table.concat(parts)
end

local function seed(key, data)
	Sim.poke("Main", key, {
		Data = data,
		MetaData = { ProfileCreateTime = Sim.unixTime(), SessionLoadCount = 1, LastUpdate = Sim.unixTime(), MetaTags = {} },
		GlobalUpdates = { 0, {} },
		RobloxMetaData = {},
		UserIds = {},
	})
end

T.test("trade pushing B over 4 MB: trade returns true, then the item is in nobody's save", function()
	T.allowThreadErrors()
	seed("A", { Coins = 0, Items = { Statue = { Pixels = blob(1500000, 1) } } })
	seed("B", { Coins = 100, Items = { Filler = blob(2800000, 2) } })
	local s = Sim.newServer({ JobId = "S1" })
	local An = anchor(s)
	local st = An.New("Main", TEMPLATE)
	local errors = {}
	An.OnError:Connect(function(msg)
		table.insert(errors, msg)
	end)
	local A = s:await(st.StartSessionAsync, st, "A")
	local B = s:await(st.StartSessionAsync, st, "B")
	local ok, why = s:await(An.Trade, A, B, function(da, db)
		db.Items.Statue, da.Items.Statue = da.Items.Statue, nil
		da.Coins += 100
		db.Coins -= 100
	end)
	print(`    Trade -> {tostring(ok)} {tostring(why)}`)
	Sim.advance(60)
	B:EndSession()
	A:EndSession()
	s:shutdown()
	print(`    OnError: {#errors} message(s); first: {tostring(errors[1])}`)
	local a, b = Sim.peek("Main", "A"), Sim.peek("Main", "B")
	local statues = (if a.Data.Items.Statue then 1 else 0) + (if b.Data.Items.Statue then 1 else 0)
	print(`    stored A coins={a.Data.Coins}, B coins={b.Data.Coins}, statues in saves={statues}`)
	if ok == true then
		T.eq(statues, 1, "trade reported done: the statue must be in exactly one save")
	else
		T.eq(statues, 1, "trade refused: the statue must still be in A's save")
	end
end)
