--!optimize 2
-- Virtual-time scheduler shared by every simulated server of one Sim world.
--
-- Time advances in frames of exactly 1/60 s (frame counter is an integer, so
-- no float drift). Each frame:
--   1. resume threads / run callbacks whose wake frame has come (task.wait,
--      task.delay, DataStore latency, MessagingService delivery), in order of
--      (frame, sequence)
--   2. fire RunService.Stepped, Heartbeat, PostSimulation on every live server
--   3. drain task.defer queues (also drained after every resumption point)
--
-- Every thread the scheduler resumes belongs to a server; when that server is
-- dead (crashed or shut down) its threads are never resumed again.

local Scheduler = {}
Scheduler.__index = Scheduler

export type Server = any

local FRAME = 1 / 60

function Scheduler.new()
	local self = setmetatable({
		frame = 0,
		now = 0,
		seq = 0,
		heap = {},
		heapSize = 0,
		waiting = setmetatable({}, { __mode = "k" }), -- [thread] = entry (only the latest)
		deferred = {},
		deferredHead = 1,
		deferredTail = 0,
		servers = {}, -- live + dead servers, in creation order
		errors = {}, -- uncaught thread errors {server, message}
		mainThread = nil,
		depth = 0, -- >0 while the scheduler is resuming something
		onError = nil, -- optional callback(server, message)
	}, Scheduler)
	return self
end

Scheduler.FRAME = FRAME

--------------------------------------------------------------------------------
-- Binary heap of entries {frame, seq, thread?, fn?, server, args}
--------------------------------------------------------------------------------

local function less(a, b)
	if a.frame ~= b.frame then
		return a.frame < b.frame
	end
	return a.seq < b.seq
end

function Scheduler:_push(entry)
	local heap = self.heap
	local n = self.heapSize + 1
	self.heapSize = n
	heap[n] = entry
	while n > 1 do
		local parent = n // 2
		if less(heap[n], heap[parent]) then
			heap[n], heap[parent] = heap[parent], heap[n]
			n = parent
		else
			break
		end
	end
end

function Scheduler:_pop()
	local heap = self.heap
	local n = self.heapSize
	local top = heap[1]
	heap[1] = heap[n]
	heap[n] = nil
	n -= 1
	self.heapSize = n
	local i = 1
	while true do
		local l = i * 2
		local r = l + 1
		local smallest = i
		if l <= n and less(heap[l], heap[smallest]) then
			smallest = l
		end
		if r <= n and less(heap[r], heap[smallest]) then
			smallest = r
		end
		if smallest == i then
			break
		end
		heap[i], heap[smallest] = heap[smallest], heap[i]
		i = smallest
	end
	return top
end

function Scheduler:framesFor(seconds: number?): number
	local t = seconds or 0
	if t ~= t or t <= 0 then
		return 1
	end
	return math.max(1, math.ceil(t * 60 - 1e-7))
end

--------------------------------------------------------------------------------
-- Resumption
--------------------------------------------------------------------------------

function Scheduler:_recordError(server, co, err)
	local msg = tostring(err)
	local trace = if co then debug.traceback(co, msg) else msg
	table.insert(self.errors, { server = server, message = msg, traceback = trace })
	if server and server.logs then
		table.insert(server.logs, { level = "error", time = self.now, message = trace })
	end
	if self.onError then
		self.onError(server, trace)
	end
end

-- Forget any pending wake-up of `co` (it is being resumed by someone else).
function Scheduler:unwait(co: thread)
	local entry = self.waiting[co]
	if entry then
		entry.cancelled = true
		self.waiting[co] = nil
	end
end

-- Resumes `co` now on behalf of `server`. Returns false if it could not run.
function Scheduler:resume(server, co: thread, ...): boolean
	if server and not server.alive then
		return false
	end
	if coroutine.status(co) ~= "suspended" then
		return false
	end
	self:unwait(co)
	self.depth += 1
	local ok, err = coroutine.resume(co, ...)
	self.depth -= 1
	if not ok then
		self:_recordError(server, co, err)
	end
	return true
end

-- Calls fn(...) directly (scheduler callbacks such as message delivery).
function Scheduler:_call(server, fn, ...)
	self.depth += 1
	local ok, err = pcall(fn, ...)
	self.depth -= 1
	if not ok then
		self:_recordError(server, nil, err)
	end
end

function Scheduler:runDeferred()
	while self.deferredHead <= self.deferredTail do
		local i = self.deferredHead
		local rec = self.deferred[i]
		self.deferred[i] = nil
		self.deferredHead = i + 1
		if not rec.cancelled then
			self:resume(rec.server, rec.thread, table.unpack(rec.args, 1, rec.args.n))
		end
	end
	self.deferredHead = 1
	self.deferredTail = 0
end

--------------------------------------------------------------------------------
-- Primitives used by the per-server task library
--------------------------------------------------------------------------------

function Scheduler:assertCanYield(what: string)
	local co = coroutine.running()
	if co == self.mainThread or not coroutine.isyieldable() then
		error(`{what}: cannot yield here (call it inside a server thread, e.g. server:await(fn) or server:spawn(fn))`, 3)
	end
	return co
end

-- Schedules `co` (owned by server) to resume after `seconds`. Does not yield.
function Scheduler:wakeAfter(server, co: thread, seconds: number?, ...)
	self.seq += 1
	local entry = {
		frame = self.frame + self:framesFor(seconds),
		seq = self.seq,
		thread = co,
		server = server,
		args = if select("#", ...) > 0 then table.pack(...) else nil,
		cancelled = false,
	}
	self.waiting[co] = entry
	self:_push(entry)
	return entry
end

-- Runs fn(...) (not in a thread) after `seconds`, unless `server` died.
function Scheduler:callAfter(server, seconds: number?, fn, ...)
	self.seq += 1
	self:_push({
		frame = self.frame + self:framesFor(seconds),
		seq = self.seq,
		fn = fn,
		server = server,
		args = table.pack(...),
		cancelled = false,
	})
end

-- Yields the running thread for `seconds` of virtual time; returns elapsed.
function Scheduler:wait(server, seconds: number?): number
	local co = self:assertCanYield("task.wait")
	local start = self.now
	self:wakeAfter(server, co, seconds)
	coroutine.yield()
	return self.now - start
end

function Scheduler:defer(server, co: thread, ...)
	local tail = self.deferredTail + 1
	self.deferredTail = tail
	self.deferred[tail] = { server = server, thread = co, args = table.pack(...), cancelled = false }
end

function Scheduler:cancel(co: thread)
	self:unwait(co)
	for i = self.deferredHead, self.deferredTail do
		local rec = self.deferred[i]
		if rec and rec.thread == co then
			rec.cancelled = true
		end
	end
	local status = coroutine.status(co)
	if status == "running" then
		error("task.cancel: cannot cancel the running thread", 3)
	elseif status == "suspended" then
		coroutine.close(co)
	end
end

--------------------------------------------------------------------------------
-- Frames
--------------------------------------------------------------------------------

function Scheduler:step()
	self.frame += 1
	local frame = self.frame
	self.now = frame * FRAME
	-- 1. timed wake-ups
	while self.heapSize > 0 and self.heap[1].frame <= frame do
		local e = self:_pop()
		if not e.cancelled and (e.server == nil or e.server.alive) then
			if e.fn then
				self:_call(e.server, e.fn, table.unpack(e.args, 1, e.args.n))
			elseif self.waiting[e.thread] == e then
				self.waiting[e.thread] = nil
				if e.args then
					self:resume(e.server, e.thread, table.unpack(e.args, 1, e.args.n))
				else
					self:resume(e.server, e.thread)
				end
			end
			self:runDeferred()
		end
	end
	-- 2. per-frame signals
	for _, server in self.servers do
		if server.alive then
			server:_frame(FRAME)
		end
	end
	self:runDeferred()
end

function Scheduler:advance(seconds: number)
	if self.depth > 0 then
		error("Sim.advance called from inside a simulated thread", 2)
	end
	local frames = math.floor(seconds * 60 + 0.5)
	self:runDeferred()
	for _ = 1, frames do
		self:step()
	end
end

-- Steps frames until pred() is true; returns true, or false after maxSeconds.
function Scheduler:runUntil(pred: () -> boolean, maxSeconds: number?): boolean
	if self.depth > 0 then
		error("Sim.runUntil called from inside a simulated thread", 2)
	end
	self:runDeferred()
	local limit = self.frame + math.floor((maxSeconds or 600) * 60 + 0.5)
	while not pred() do
		if self.frame >= limit then
			return false
		end
		self:step()
	end
	return true
end

--------------------------------------------------------------------------------
-- Signals (RBXScriptSignal / RBXScriptConnection)
--------------------------------------------------------------------------------

local ConnectionMT = { __robloxtype = "RBXScriptConnection" }
ConnectionMT.__index = ConnectionMT

function ConnectionMT.Disconnect(self)
	if not self.Connected then
		return
	end
	self.Connected = false
	local list = self._signal._connections
	local i = table.find(list, self)
	if i then
		table.remove(list, i)
	end
end

local SignalMT = { __robloxtype = "RBXScriptSignal" }
SignalMT.__index = SignalMT

-- Handlers run in fresh-ish threads owned by `server` (runner threads are
-- reused while handlers do not yield, like a GoodSignal).
function Scheduler:newSignal(server, name: string?)
	return setmetatable({ _sched = self, _server = server, _connections = {}, _name = name }, SignalMT)
end

function SignalMT.Connect(self, fn)
	if type(fn) ~= "function" then
		error(`Attempt to connect failed: Passed value is not a function`, 2)
	end
	local c = setmetatable({ Connected = true, _signal = self, _fn = fn }, ConnectionMT)
	table.insert(self._connections, c)
	return c
end

function SignalMT.Once(self, fn)
	local c
	c = self:Connect(function(...)
		c:Disconnect()
		fn(...)
	end)
	return c
end

function SignalMT.Wait(self)
	local sched = self._sched
	local co = sched:assertCanYield("Signal:Wait")
	local c
	c = self:Connect(function(...)
		c:Disconnect()
		sched:resume(self._server, co, ...)
	end)
	return coroutine.yield()
end

local function acquireAndCall(server, fn, ...)
	local runner = server._freeRunner
	server._freeRunner = nil
	fn(...)
	server._freeRunner = runner
end

local function runnerMain(server, fn, ...)
	acquireAndCall(server, fn, ...)
	while true do
		acquireAndCall(coroutine.yield())
	end
end

function Scheduler:spawnHandler(server, fn, ...)
	if server and not server.alive then
		return
	end
	if server == nil then
		self:resume(nil, coroutine.create(fn), ...)
		return
	end
	if server._freeRunner == nil then
		server._freeRunner = coroutine.create(runnerMain)
	end
	local runner = server._freeRunner
	self:resume(server, runner, server, fn, ...)
end

-- Fires the signal (each handler on its own thread, started immediately).
function SignalMT.Fire(self, ...)
	local list = self._connections
	if #list == 0 then
		return
	end
	local snapshot = table.clone(list)
	for _, c in snapshot do
		if c.Connected then
			self._sched:spawnHandler(self._server, c._fn, ...)
		end
	end
end

function SignalMT.GetListenerCount(self)
	return #self._connections
end

function SignalMT.__tostring(self)
	return "Signal " .. tostring(self._name)
end

Scheduler.SignalMT = SignalMT

--------------------------------------------------------------------------------
-- task library for one server
--------------------------------------------------------------------------------

function Scheduler:taskLib(server)
	local sched = self
	local lib = {}

	local function toThread(fnOrThread)
		if type(fnOrThread) == "thread" then
			return fnOrThread
		elseif type(fnOrThread) == "function" then
			return coroutine.create(fnOrThread)
		end
		error(`invalid argument #1 to 'spawn' (function or thread expected, got {typeof(fnOrThread)})`, 3)
	end

	function lib.spawn(fnOrThread, ...)
		local co = toThread(fnOrThread)
		sched:resume(server, co, ...)
		return co
	end

	function lib.defer(fnOrThread, ...)
		local co = toThread(fnOrThread)
		sched:defer(server, co, ...)
		return co
	end

	function lib.delay(seconds, fnOrThread, ...)
		local co = toThread(fnOrThread)
		sched:wakeAfter(server, co, seconds, ...)
		return co
	end

	function lib.wait(seconds)
		return sched:wait(server, seconds)
	end

	function lib.cancel(co)
		sched:cancel(co)
	end

	function lib.synchronize() end
	function lib.desynchronize() end

	return table.freeze(lib)
end

return Scheduler
