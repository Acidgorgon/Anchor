-- Self-tests for the Roblox mock (JSON rules, scheduler, DataStore, messaging,
-- servers, module loading). The stock ProfileStore suites in tests/stock prove
-- the mock end to end; these pin down the mock's own contract.
local T = require("@mock/testkit")
local Sim = require("@mock/sim")
local JSON = Sim.JSON

--------------------------------------------------------------------------------
-- JSON
--------------------------------------------------------------------------------

T.test("JSON: arrays, dicts, empty table, numbers, strings round-trip", function()
	local v = { list = { 1, 2.5, -3, "x" }, map = { a = true, b = false }, empty = {}, big = 2 ^ 52, s = 'q"\n\\é' }
	local text = JSON.encode(v)
	T.deepEq(JSON.decode(text), v)
	T.eq(JSON.encode({}), "[]")
	T.eq(JSON.encode({ 1, 2, 3 }), "[1,2,3]")
	T.eq(JSON.encode(0.1), "0.1")
	T.eq(JSON.encode(1 / 3), tostring(1 / 3) == "0.3333333333333333" and "0.3333333333333333" or JSON.encode(1 / 3))
	T.eq(JSON.decode(JSON.encode(1 / 3)), 1 / 3)
	T.eq(JSON.decode('"\\u00e9\\ud83d\\ude00"'), "é😀")
end)

T.test("JSON: buffers use the Roblox {m,t,base64} object and decode back", function()
	local b = buffer.create(5)
	for i = 0, 4 do
		buffer.writeu8(b, i, i * 50)
	end
	local text = JSON.encode({ blob = b })
	T.expect(string.find(text, '{"m":null,"t":"buffer","base64":"ADJkls',1, true), text)
	local back = JSON.decode(text).blob
	T.eq(typeof(back), "buffer")
	T.eq(buffer.tostring(back), buffer.tostring(b))
	for len = 0, 7 do
		local x = buffer.create(len)
		for i = 0, len - 1 do
			buffer.writeu8(x, i, 255 - i)
		end
		T.eq(buffer.tostring(JSON.base64Decode(JSON.base64Encode(x))), buffer.tostring(x))
	end
end)

T.test("JSON: invalid values raise errors naming the path", function()
	local cases = {
		{ { a = { b = function() end } }, "a.b" },
		{ { a = 0 / 0 }, "number nan" },
		{ { a = -math.huge }, "number %-inf" },
		{ { 1, nil, 3 } :: any, "sparse" },
		{ { 1, x = 1 } :: any, "mixed" },
		{ { [true] = 1 } :: any, "key of type boolean" },
		{ { s = "\255\254" }, "UTF%-8" },
		{ { v = vector.create(1, 2, 3) }, "vector" },
		{ { co = coroutine.create(print) }, "thread" },
		{ { e = Sim.Enum.SortDirection.Ascending }, "EnumItem" },
	}
	for _, case in cases do
		local ok, err = pcall(JSON.encode, case[1])
		T.expect(not ok, "should fail: " .. case[2])
		T.expect(string.find(err, case[2]), `{err} ~ {case[2]}`)
	end
	local cyc = {}
	cyc.self = cyc
	T.throws(function()
		JSON.encode(cyc)
	end, "cyclic")
end)

--------------------------------------------------------------------------------
-- Scheduler
--------------------------------------------------------------------------------

T.test("scheduler: task.wait/delay/defer/cancel in virtual time; Heartbeat 60/s", function()
	local s = Sim.newServer()
	local log = {}
	local beats = 0
	s.RunService.Heartbeat:Connect(function(dt)
		beats += 1
		T.near(dt, 1 / 60, 1e-9)
	end)
	s:spawn(function()
		local elapsed = s.task.wait(1.5)
		table.insert(log, string.format("wait %.2f", elapsed))
	end)
	s.task.delay(0.5, function(x)
		table.insert(log, "delay " .. x)
	end, "arg")
	local cancelled = s.task.delay(1, function()
		table.insert(log, "never")
	end)
	s.task.cancel(cancelled)
	s.task.defer(function()
		table.insert(log, "defer")
	end)
	Sim.advance(2)
	T.deepEq(log, { "defer", "delay arg", "wait 1.50" })
	T.eq(beats, 120)
	T.near(Sim.now(), 2, 1e-9)
	T.throws(function()
		s.task.wait(1)
	end, "cannot yield here")
end)

T.test("scheduler: uncaught thread errors are recorded and fail the test unless allowed", function()
	T.allowThreadErrors()
	local s = Sim.newServer()
	s.task.spawn(function()
		error("boom")
	end)
	T.eq(#Sim.threadErrors(), 1)
	T.expect(string.find(Sim.threadErrors()[1].message, "boom"))
end)

T.test("clocks: os.clock/os.time/tick/DateTime follow virtual time per server", function()
	local a = Sim.newServer()
	local b = Sim.newServer({ timeSkew = 3 })
	local env = a.env
	local c0, t0 = env.os.clock(), env.os.time()
	T.expect(c0 > 100, "os.clock starts high like a real process")
	Sim.advance(10)
	T.near(env.os.clock() - c0, 10, 1e-9)
	T.eq(env.os.time() - t0, 10)
	T.eq(b.env.os.time() - env.os.time(), 3)
	T.eq(env.typeof(env.DateTime.now()), "DateTime")
	T.eq(env.DateTime.now().UnixTimestamp, env.os.time())
	T.near(env.tick(), Sim.unixTime(), 1e-6)
end)

--------------------------------------------------------------------------------
-- DataStore
--------------------------------------------------------------------------------

T.test("DataStore: UpdateAsync deep copies, keyInfo, userIds/metadata, nil cancels", function()
	local s = Sim.newServer()
	local ds = s.game:GetService("DataStoreService"):GetDataStore("Store")
	local held
	s:await(function()
		local value, info = ds:UpdateAsync("k", function(old, keyInfo)
			T.eq(old, nil)
			T.eq(keyInfo, nil)
			held = { n = 1, list = { "a" } }
			return held, { 7 }, { tag = "x" }
		end)
		T.deepEq(value, { n = 1, list = { "a" } })
		T.expect(value ~= held, "returned value is a copy")
		T.eq(s.env.typeof(info), "DataStoreKeyInfo")
		T.deepEq(info:GetUserIds(), { 7 })
		T.deepEq(info:GetMetadata(), { tag = "x" })
		T.eq(info.CreatedTime, info.UpdatedTime)
		held.n = 999 -- mutating the caller's table must not change the store
		local v2, info2 = ds:UpdateAsync("k", function(old, keyInfo)
			T.eq(old.n, 1)
			T.eq(keyInfo.Version, info.Version)
			old.n = 2
			return old
		end)
		T.eq(v2.n, 2)
		T.neq(info2.Version, info.Version)
		T.deepEq(info2:GetUserIds(), {}, "userIds replaced when omitted")
		local v3, info3 = ds:UpdateAsync("k", function()
			return nil
		end)
		T.eq(v3, nil)
		T.eq(info3, nil)
		local got, gotInfo = ds:GetAsync("k")
		T.eq(got.n, 2)
		T.eq(gotInfo.Version, info2.Version)
	end)
	T.eq(s.stats.calls.UpdateAsync, 3)
	T.eq(s.stats.calls.GetAsync, 1)
	T.eq(s.stats.bytesWritten, #JSON.encode({ n = 1, list = { "a" } }) + #JSON.encode({ n = 2, list = { "a" } }))
	T.eq(#Sim.versions("Store", "k"), 2)
end)

T.test("DataStore: transform may not yield; invalid values and oversize values error", function()
	local s = Sim.newServer()
	local ds = s.game:GetService("DataStoreService"):GetDataStore("Store")
	s:await(function()
		T.throws(function()
			ds:UpdateAsync("k", function()
				s.task.wait(1)
				return 1
			end)
		end, "cannot yield")
		T.throws(function()
			ds:UpdateAsync("k", function()
				return { f = print }
			end)
		end, "Cannot store function")
		T.throws(function()
			ds:SetAsync("k", string.rep("x", 4194304))
		end, "exceeds max size")
		T.throws(function()
			ds:GetAsync(string.rep("k", 51))
		end, "50 character")
	end)
	T.eq(Sim.peek("Store", "k"), nil)
end)

T.test("DataStore: latency is virtual and within the configured range", function()
	Sim.configure({ latency = { 0.1, 0.3 } })
	local s = Sim.newServer()
	local ds = s.game:GetService("DataStoreService"):GetDataStore("Store")
	for _ = 1, 20 do
		local t0 = Sim.now()
		s:await(ds.SetAsync, ds, "k", 1)
		local took = Sim.now() - t0
		T.expect(took >= 0.1 - 1 / 30 and took <= 0.3 + 1 / 30, `latency {took}`)
	end
end)

T.test("DataStore: crash mid-request: first half never writes, second half commits", function()
	Sim.configure({ latency = 1 })
	local a = Sim.newServer()
	local ds = a.game:GetService("DataStoreService"):GetDataStore("Store")
	a:spawn(ds.SetAsync, ds, "early", 1)
	Sim.advance(0.25)
	a:crash()
	Sim.advance(5)
	T.eq(Sim.peek("Store", "early"), nil)

	local b = Sim.newServer()
	local ds2 = b.game:GetService("DataStoreService"):GetDataStore("Store")
	local job = b:spawn(ds2.SetAsync, ds2, "late", 2)
	Sim.advance(0.75)
	b:crash()
	Sim.advance(5)
	T.eq(Sim.peek("Store", "late"), 2)
	T.expect(not job.done, "caller never saw the result")
end)

T.test("DataStore: error injection by key, call number, probability, server", function()
	local a = Sim.newServer()
	local b = Sim.newServer()
	local dsA = a.game:GetService("DataStoreService"):GetDataStore("S")
	local dsB = b.game:GetService("DataStoreService"):GetDataStore("S")
	Sim.injectError({ key = "bad", message = "nope" })
	Sim.injectError({ callNumber = Sim.callCount() + 3, message = "third" })
	local onlyB = Sim.injectError({ server = b, method = "GetAsync", count = 1 })
	a:await(function()
		T.throws(function()
			dsA:SetAsync("bad", 1)
		end, "nope")
		dsA:SetAsync("ok", 1)
		T.throws(function()
			dsA:SetAsync("ok", 2)
		end, "third")
		dsA:GetAsync("ok")
	end)
	b:await(function()
		T.throws(function()
			dsB:GetAsync("ok")
		end, "502")
		T.eq(dsB:GetAsync("ok"), 1)
	end)
	T.eq(onlyB.hits, 1)
	Sim.clearInjectedErrors()
	local flaky = Sim.injectError({ rate = 0.5 })
	local failures = 0
	a:await(function()
		for _ = 1, 200 do
			if not pcall(dsA.SetAsync, dsA, "x", 1) then
				failures += 1
			end
		end
	end)
	T.eq(failures, flaky.hits)
	T.expect(failures > 60 and failures < 140, `{failures} failures at 50%`)
end)

T.test("DataStore: RemoveAsync tombstones, versions, GetVersionAsync, ListVersionsAsync paging", function()
	local s = Sim.newServer()
	local ds = s.game:GetService("DataStoreService"):GetDataStore("S")
	s:await(function()
		ds:SetAsync("k", "v1")
		s.task.wait(1)
		ds:SetAsync("k", "v2")
		local old = ds:RemoveAsync("k")
		T.eq(old, "v2")
		T.eq(ds:GetAsync("k"), nil)
		local pages = ds:ListVersionsAsync("k", Sim.Enum.SortDirection.Ascending, nil, nil, 2)
		local items = pages:GetCurrentPage()
		T.eq(#items, 2)
		T.eq(pages.IsFinished, false)
		pages:AdvanceToNextPageAsync()
		local last = pages:GetCurrentPage()
		T.eq(#last, 1)
		T.eq(last[1].IsDeleted, true)
		T.eq(pages.IsFinished, true)
		T.eq(ds:GetVersionAsync("k", items[1].Version), "v1")
		T.eq(ds:GetVersionAsync("k", last[1].Version), nil)
		T.throws(function()
			ds:GetVersionAsync("k", "nope")
		end, "not valid")
	end)
end)

--------------------------------------------------------------------------------
-- Messaging, servers, players
--------------------------------------------------------------------------------

T.test("MessagingService: delivered to every live subscriber with Data and Sent", function()
	local a = Sim.newServer()
	local b = Sim.newServer()
	local c = Sim.newServer()
	local got = {}
	for _, s in { a, b, c } do
		s:await(function()
			s.game:GetService("MessagingService"):SubscribeAsync("topic", function(message)
				table.insert(got, { s.name, message.Data.x, type(message.Sent) })
			end)
		end)
	end
	c:crash()
	a:await(function()
		a.game:GetService("MessagingService"):PublishAsync("topic", { x = 1 })
	end)
	Sim.advance(1)
	table.sort(got, function(p, q)
		return p[1] < q[1]
	end)
	T.deepEq(got, { { a.name, 1, "number" }, { b.name, 1, "number" } })
	a:await(function()
		T.throws(function()
			a.game:GetService("MessagingService"):PublishAsync("topic", string.rep("x", 2000))
		end, "1kB")
	end)
end)

T.test("shutdown: PlayerRemoving fires, BindToClose gets 30 s, then the server dies", function()
	local s = Sim.newServer()
	local removed = {}
	s.Players.PlayerRemoving:Connect(function(p)
		table.insert(removed, p.UserId)
	end)
	s.game:BindToClose(function()
		s.task.wait(100) -- longer than the budget
	end)
	s:addPlayer(1)
	s:addPlayer(2)
	local r = s:shutdown()
	T.deepEq(removed, { 1, 2 })
	T.eq(r.timedOut, true)
	T.near(r.elapsed, 30, 0.1)
	T.expect(not s.alive)
end)

T.test("players: Kick removes and records; GetPlayers; GetPlayerByUserId", function()
	local s = Sim.newServer()
	local p = s:addPlayer(55, { Name = "Bob" })
	T.eq(p.Parent, s.Players)
	T.eq(s.env.typeof(p), "Instance")
	T.expect(p:IsA("Player"))
	T.eq(s.Players:GetPlayerByUserId(55), p)
	p:Kick("bye")
	T.eq(p.Parent, nil)
	T.eq(#s.Players:GetPlayers(), 0)
	local kicked, msg = s:wasKicked(55)
	T.expect(kicked)
	T.eq(msg, "bye")
end)

T.test("modules: per-server fresh state, script tree, string requires, yielding module", function()
	local a = Sim.newServer({ JobId = "A" })
	local b = Sim.newServer({ JobId = "B" })
	local libA = a:require("tests/mock/fixtures/Lib")
	local libA2 = a:require("tests/mock/fixtures/Lib")
	local libB = b:require("tests/mock/fixtures/Lib")
	T.eq(libA, libA2, "cached per server")
	T.neq(libA, libB, "fresh per server")
	T.eq(libA.jobId, "A")
	T.eq(libB.jobId, "B")
	T.eq(libA.counter(), 1)
	T.eq(libB.counter(), 1, "module globals are per module instance")
	T.eq(rawget(_G, "counter"), nil, "no leak into the harness globals")
	T.eq(libA.child.name, "Child")
	T.eq(libA.child.parent, "Lib")
	T.eq(libA.deep.up, "Child")
	T.eq(libA.same, true)
	T.eq(libA.scriptName, "Lib")
	T.eq(libA.parentName, "ServerScriptService")
	T.eq(libA.typeofDate, "DateTime")
	local y = a:require("tests/mock/fixtures/Yielding.luau")
	T.expect(y.loadedAt - a.clockBase >= 2, "module yielded 2 virtual seconds")
end)
