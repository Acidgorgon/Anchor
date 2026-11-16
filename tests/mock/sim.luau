--!optimize 2
-- Sim: a multi-server Roblox simulation with virtual time.
--
--   local Sim = require("@mock/sim")
--   Sim.reset({ latency = {0.1, 0.3} })         -- fresh world (testkit does this per test)
--   local s1 = Sim.newServer({ PlaceId = 1, JobId = "A" })
--   local PS = s1:require("reference/ProfileStore-1.0.3.luau", { name = "ProfileStore" })
--   local store = PS.New("Main", { Coins = 0 })
--   local profile = s1:await(store.StartSessionAsync, store, "Player_1")
--   Sim.advance(300)                            -- 5 virtual minutes, milliseconds of real time
--
-- Every server has its own `game` (services, PlaceId, JobId, BindToClose),
-- Players, task scheduler view, clocks, `_G`/`shared`, and its own fresh copy
-- of every module it requires (per-module global environment, like Roblox
-- scripts). All servers share one DataStore backend and MessagingService bus.
-- See tests/README section in run.sh --help for the full API list.

local Scheduler = require("./scheduler")
local Roblox = require("./roblox")
local JSON = require("./json")
local DS = require("./datastore")
local MS = require("./messaging")

local Sim = {}

Sim.JSON = JSON
Sim.Roblox = Roblox
Sim.Enum = Roblox.Enum
Sim.EPOCH = 1763251200 -- 2025-11-16T00:00:00Z: virtual unix time at t = 0
Sim.defaultTimeout = 600 -- virtual seconds server:await waits before failing
Sim.verbose = (getenv and getenv("ANCHOR_TEST_VERBOSE") or "") ~= ""
Sim.root = "." -- repo root, set by the runner

local NIL_RESULT = newproxy()

-- Standard Luau globals copied into every module environment.
local STD_NAMES = {
	"assert", "error", "getmetatable", "setmetatable", "ipairs", "pairs", "next", "newproxy", "pcall",
	"xpcall", "rawequal", "rawget", "rawset", "rawlen", "select", "tonumber", "tostring", "type", "unpack",
	"gcinfo", "_VERSION", "math", "string", "table", "bit32", "utf8", "buffer", "vector", "getfenv", "setfenv",
}
local STD = {}
for _, name in STD_NAMES do
	STD[name] = (_G :: any)[name]
end
local realPrint = print
local realOs = os
local realCoroutine = coroutine
local realDebug = debug

--------------------------------------------------------------------------------
-- World
--------------------------------------------------------------------------------

local World = {}
World.__index = World

local W -- current world

local function newWorld(options)
	options = options or {}
	local world = setmetatable({}, World)
	world.sched = Scheduler.new()
	world.sched.mainThread = Sim._mainThread
	world.rng = Roblox.newRandom(options.seed or 12345)
	world.ds = DS.newBackend(world)
	world.bus = MS.newBus(world)
	world.servers = world.sched.servers
	world.serverCount = 0
	world.sched.onError = function(server, trace)
		if not Sim.verbose then
			return -- testkit reports them; -v prints them as they happen
		end
		local name = if server then server.name else "world"
		realPrint(`[sim] uncaught error in {name} thread at t={string.format("%.2f", world.sched.now)}:\n{trace}`)
	end
	return world
end

function World:unixMillis(server): number
	return math.floor((Sim.EPOCH + self.sched.now + (if server then server.timeSkew else 0)) * 1000)
end

--------------------------------------------------------------------------------
-- Module loading (shared bytecode, per-module environment)
--------------------------------------------------------------------------------

local bytecodeCache = {}

local function compileFile(path: string): string
	local bc = bytecodeCache[path]
	if bc then
		return bc
	end
	local src = readfile(path)
	if src == nil then
		error(`cannot read module {path}`, 0)
	end
	local compiled, err = __compile(src)
	if compiled == nil then
		error(`failed to compile {path}: {err}`, 0)
	end
	bytecodeCache[path] = compiled
	return compiled
end

local function dirname(path: string): string
	return string.match(path, "^(.*)/[^/]*$") or "."
end

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

local function isFile(path: string): boolean
	return listdir(path) == nil and readfile(path) ~= nil
end

local function isDir(path: string): boolean
	return listdir(path) ~= nil
end

local function resolveFile(target: string): string?
	for _, candidate in { target, target .. ".luau", target .. ".lua", target .. "/init.luau", target .. "/init.lua" } do
		if isFile(candidate) then
			return candidate
		end
	end
	return nil
end

local function resolveStringRequire(fromPath: string, name: string): string
	local base = dirname(fromPath)
	local rel = name
	if string.sub(name, 1, 6) == "@self/" then
		rel = string.sub(name, 7)
	elseif string.match(fromPath, "/init%.luau?$") then
		base = dirname(base)
	end
	local target = normalize(base .. "/" .. rel)
	local file = resolveFile(target)
	if file == nil then
		error(`require("{name}") from {fromPath}: no module at {target}`, 0)
	end
	return file
end

local function absPath(path: string): string
	if string.sub(path, 1, 1) == "/" then
		return normalize(path)
	end
	return normalize(Sim.root .. "/" .. path)
end

local function displayPath(path: string): string
	local root = normalize(Sim.root) .. "/"
	if string.sub(path, 1, #root) == root then
		return string.sub(path, #root + 1)
	end
	return path
end

local function moduleName(path: string): string
	local base = string.match(path, "([^/]+)$") :: string
	return (string.gsub(base, "%.luau?$", ""))
end

--------------------------------------------------------------------------------
-- Server
--------------------------------------------------------------------------------

local Server = {}
Server.__index = Server

local function newGuid(world, wrap: boolean?): string
	local hex = "0123456789ABCDEF"
	local chars = {}
	for i = 1, 32 do
		local v = world.rng:NextInteger(0, 15)
		if i == 13 then
			v = 4
		elseif i == 17 then
			v = 8 + v % 4
		end
		chars[i] = string.sub(hex, v + 1, v + 1)
	end
	local s = table.concat(chars)
	s = `{string.sub(s, 1, 8)}-{string.sub(s, 9, 12)}-{string.sub(s, 13, 16)}-{string.sub(s, 17, 20)}-{string.sub(s, 21, 32)}`
	if wrap == false then
		return s
	end
	return "{" .. s .. "}"
end

function Server:_log(level: string, ...)
	local n = select("#", ...)
	local parts = table.create(n)
	for i = 1, n do
		parts[i] = tostring((select(i, ...)))
	end
	local msg = table.concat(parts, " ")
	table.insert(self.logs, { level = level, time = self.world.sched.now, message = msg })
	if Sim.verbose or (level == "warn" and Sim.echoWarnings) then
		realPrint(`[{self.name} {level} t={string.format("%.2f", self.world.sched.now)}] {msg}`)
	end
end

-- Returns log entries whose message matches `pattern` (Lua pattern, plain=true by default).
function Server:logsMatching(pattern: string, level: string?, usePattern: boolean?)
	local out = {}
	for _, entry in self.logs do
		if (level == nil or entry.level == level) and string.find(entry.message, pattern, 1, not usePattern) then
			table.insert(out, entry)
		end
	end
	return out
end

function Server:_newSignal(name: string?)
	return self.world.sched:newSignal(self, name)
end

local function makeInstanceLib(server)
	local sched = server.world.sched
	local function new(className: string, parent)
		local inst = Roblox.newInstance(className)
		if className == "DataStoreOptions" then
			rawset(inst, "AllScopes", false)
			rawset(inst, "SetExperimentalFeatures", function(self, features)
				if type(features) ~= "table" then
					error("SetExperimentalFeatures expects a table", 2)
				end
				rawset(self, "_features", table.clone(features))
			end)
		elseif className == "DataStoreSetOptions" or className == "DataStoreIncrementOptions" then
			rawset(inst, "SetMetadata", function(self, metadata)
				rawset(self, "_metadata", metadata)
			end)
			rawset(inst, "GetMetadata", function(self)
				return rawget(self, "_metadata") or {}
			end)
		elseif className == "DataStoreGetOptions" then
			rawset(inst, "UseCache", true)
		elseif className == "BindableEvent" then
			local signal = sched:newSignal(server, "Event")
			rawset(inst, "Event", signal)
			rawset(inst, "Fire", function(_self, ...)
				signal:Fire(...)
			end)
		end
		rawset(inst, "_server", server)
		if parent then
			inst.Parent = parent
		end
		return inst
	end
	return table.freeze({ new = new })
end

local function makeOs(server)
	local world = server.world
	local o = table.clone(realOs)
	o.clock = function()
		return server.clockBase + world.sched.now
	end
	o.time = function(t)
		if t ~= nil then
			return realOs.time(t)
		end
		return math.floor(Sim.EPOCH + world.sched.now + server.timeSkew)
	end
	o.date = function(fmt, t)
		return realOs.date(fmt, t or math.floor(Sim.EPOCH + world.sched.now + server.timeSkew))
	end
	return table.freeze(o)
end

local function makeCoroutine(server)
	local sched = server.world.sched
	local c = table.clone(realCoroutine)
	-- A thread resumed by hand stops waiting on the scheduler (like Roblox).
	c.resume = function(co, ...)
		sched:unwait(co)
		return realCoroutine.resume(co, ...)
	end
	c.close = function(co)
		sched:unwait(co)
		return realCoroutine.close(co)
	end
	return table.freeze(c)
end

local function makeDebug()
	local d = table.clone(realDebug)
	d.profilebegin = function() end
	d.profileend = function() end
	d.setmemorycategory = function() end
	d.resetmemorycategory = function() end
	d.dumpcodesize = function() end
	return table.freeze(d)
end

local SHARED_DEBUG = makeDebug()

function Server:_buildEnv()
	local server = self
	local world = self.world
	local sched = world.sched
	local env = table.clone(STD)
	env.game = self.game
	env.Game = self.game
	env.workspace = self.Workspace
	env.Workspace = self.Workspace
	env.task = self.task
	env.wait = function(t)
		local elapsed = self.task.wait(math.max(t or 0, 1 / 30))
		return elapsed, sched.now - server.startTime
	end
	env.delay = function(t, fn)
		self.task.delay(t, fn)
	end
	env.spawn = function(fn)
		self.task.defer(fn)
	end
	env.tick = function()
		return Sim.EPOCH + sched.now + server.timeSkew
	end
	env.time = function()
		return sched.now - server.startTime
	end
	env.elapsedTime = env.time
	env.os = makeOs(self)
	env.coroutine = makeCoroutine(self)
	env.debug = SHARED_DEBUG
	env.typeof = Roblox.typeof
	env.Instance = makeInstanceLib(self)
	env.Enum = Roblox.Enum
	env.DateTime = Roblox.makeDateTime(function()
		return world:unixMillis(server)
	end)
	env.Random = table.freeze({
		new = function(seed)
			return Roblox.newRandom(seed or world.rng:NextInteger(1, 2147483646))
		end,
	})
	env.Vector3 = table.freeze({ new = vector.create, zero = vector.zero, one = vector.one })
	env.print = function(...)
		server:_log("print", ...)
	end
	env.warn = function(...)
		server:_log("warn", ...)
	end
	env.settings = function()
		return {}
	end
	env.shared = self.shared
	env._G = self.G
	return env
end

local function buildServices(server)
	local world = server.world
	local game = Roblox.newInstance("DataModel", "Game")
	server.game = game
	rawset(game, "_server", server)
	rawset(game, "PlaceId", server.PlaceId)
	rawset(game, "PlaceVersion", server.PlaceVersion)
	rawset(game, "GameId", server.GameId)
	rawset(game, "JobId", server.JobId)
	rawset(game, "CreatorId", 1)
	rawset(game, "PrivateServerId", "")
	rawset(game, "PrivateServerOwnerId", 0)
	rawset(game, "GetService", function(_self, name)
		local service = Roblox.InstanceMethods.FindFirstChild(game, name)
		if service == nil then
			error(`mock game:GetService: unknown service "{name}" (add it in tests/mock/sim.luau)`, 2)
		end
		return service
	end)
	rawset(game, "FindService", function(_self, name)
		return Roblox.InstanceMethods.FindFirstChild(game, name)
	end)
	rawset(game, "BindToClose", function(_self, fn)
		if type(fn) ~= "function" then
			error("BindToClose expects a function", 2)
		end
		table.insert(server._bindToClose, fn)
	end)
	rawset(game, "IsLoaded", function()
		return true
	end)

	local function service(className: string, inst)
		inst = inst or Roblox.newInstance(className, className)
		rawset(inst, "_server", server)
		inst.Parent = game
		return inst
	end

	-- RunService
	local RunService = service("RunService")
	for _, name in { "Heartbeat", "PostSimulation", "Stepped", "PreSimulation", "RenderStepped", "PreRender" } do
		rawset(RunService, name, server:_newSignal(name))
	end
	rawset(RunService, "IsServer", function()
		return true
	end)
	rawset(RunService, "IsClient", function()
		return false
	end)
	rawset(RunService, "IsStudio", function()
		return server.IsStudio
	end)
	rawset(RunService, "IsRunning", function()
		return true
	end)
	rawset(RunService, "IsRunMode", function()
		return false
	end)
	server.RunService = RunService

	-- Players
	local Players = service("Players")
	rawset(Players, "PlayerAdded", server:_newSignal("PlayerAdded"))
	rawset(Players, "PlayerRemoving", server:_newSignal("PlayerRemoving"))
	rawset(Players, "MaxPlayers", 50)
	rawset(Players, "GetPlayers", function()
		return table.clone(server.playerList)
	end)
	rawset(Players, "GetPlayerByUserId", function(_self, userId)
		for _, p in server.playerList do
			if p.UserId == userId then
				return p
			end
		end
		return nil
	end)
	server.Players = Players

	-- HttpService
	local HttpService = service("HttpService")
	rawset(HttpService, "HttpEnabled", false)
	rawset(HttpService, "GenerateGUID", function(_self, wrap)
		return newGuid(world, wrap)
	end)
	rawset(HttpService, "JSONEncode", function(_self, value)
		return JSON.encode(value)
	end)
	rawset(HttpService, "JSONDecode", function(_self, text)
		return JSON.decode(text)
	end)
	rawset(HttpService, "UrlEncode", function(_self, s)
		return (string.gsub(s, "[^%w%-_%.~]", function(c)
			return string.format("%%%02X", string.byte(c))
		end))
	end)
	for _, m in { "GetAsync", "PostAsync", "RequestAsync" } do
		rawset(HttpService, m, function()
			error("Http requests are not enabled. Enable via game settings", 2)
		end)
	end

	server.DataStoreService = service("DataStoreService", DS.newService(world.ds, server))
	server.MessagingService = service("MessagingService", MS.newService(world.bus, server))
	server.ReplicatedStorage = service("ReplicatedStorage")
	server.ServerScriptService = service("ServerScriptService")
	server.ServerStorage = service("ServerStorage")
	server.Workspace = service("Workspace")
	rawset(server.Workspace, "GetServerTimeNow", function()
		return world:unixMillis(server) / 1000
	end)
	service("Lighting")
	service("ReplicatedFirst")
	service("StarterPlayer")
	service("Teams")
end

-- Sim.newServer({PlaceId?, JobId?, GameId?, PlaceVersion?, IsStudio?, timeSkew?, name?})
function Sim.newServer(opts)
	opts = opts or {}
	local world = W
	world.serverCount += 1
	local server = setmetatable({}, Server)
	server.world = world
	server.alive = true
	server.closing = false
	server.name = opts.name or opts.JobId or `server{world.serverCount}`
	server.PlaceId = opts.PlaceId or 1
	server.GameId = opts.GameId or 1
	server.PlaceVersion = opts.PlaceVersion or 1
	server.JobId = opts.JobId or newGuid(world, false):lower()
	server.IsStudio = opts.IsStudio == true
	server.timeSkew = opts.timeSkew or 0
	server.clockBase = opts.clockBase or (1000 + world.serverCount * 137.25)
	server.startTime = world.sched.now
	server.stats = {
		calls = {},
		bytesWritten = 0,
		bytesRead = 0,
		conflicts = 0,
		throttled = 0,
		writesByKey = {},
		publishes = 0,
		messagesReceived = 0,
	}
	server.logs = {}
	server.kicks = {}
	server.playerList = {}
	server.modules = {}
	server.scripts = {}
	server.loading = {}
	server.G = {}
	server.shared = {}
	server._bindToClose = {}
	server._dsBudgets = {}
	server.task = world.sched:taskLib(server)
	buildServices(server)
	server.env = server:_buildEnv()
	table.insert(world.servers, server)
	return server
end

function Server:_frame(dt: number)
	local rs = self.RunService
	local now = self.world.sched.now
	if #rs.Stepped._connections > 0 then
		rs.Stepped:Fire(now - self.startTime, dt)
	end
	if #rs.PreSimulation._connections > 0 then
		rs.PreSimulation:Fire(dt)
	end
	if #rs.Heartbeat._connections > 0 then
		rs.Heartbeat:Fire(dt)
	end
	if #rs.PostSimulation._connections > 0 then
		rs.PostSimulation:Fire(dt)
	end
	if self._shutdown and self.alive then
		local sd = self._shutdown
		if sd.pending == 0 or now - sd.start >= 30 then
			sd.timedOut = sd.pending > 0
			self:_kill("shutdown")
		end
	end
end

-- Threads ------------------------------------------------------------------

local Job = {}
Job.__index = Job

function Job:result()
	if not self.done then
		error("job has not finished", 2)
	end
	if not self.ok then
		error(self.err, 0)
	end
	return table.unpack(self.results, 1, self.results.n)
end

-- Starts fn(...) on a new thread of this server (runs until its first yield).
function Server:spawn(fn, ...)
	if not self.alive then
		error(`server {self.name} is dead`, 2)
	end
	local job = setmetatable({ done = false, ok = nil, results = nil, err = nil, server = self }, Job)
	local co = coroutine.create(function(...)
		local r = table.pack(xpcall(fn, function(e)
			return debug.traceback(tostring(e), 2)
		end, ...))
		job.ok = r[1]
		if r[1] then
			job.results = table.pack(table.unpack(r, 2, r.n))
		else
			job.err = r[2]
		end
		job.done = true
	end)
	job.thread = co
	self.world.sched:resume(self, co, ...)
	return job
end

-- Runs fn(...) on a server thread, advancing virtual time until it returns
-- (at most maxSeconds, default Sim.defaultTimeout). Returns its results or
-- re-raises its error.
function Server:awaitFor(maxSeconds: number, fn, ...)
	local job = self:spawn(fn, ...)
	local finished = self.world.sched:runUntil(function()
		return job.done or not self.alive
	end, maxSeconds)
	if not job.done then
		if not self.alive then
			error(`server {self.name} died while awaiting`, 2)
		end
		error(`await timed out after {maxSeconds} virtual seconds (t={self.world.sched.now})`, 2)
	end
	local _ = finished
	return job:result()
end

function Server:await(fn, ...)
	return self:awaitFor(Sim.defaultTimeout, fn, ...)
end

-- Players ------------------------------------------------------------------

function Server:addPlayer(userId: number, opts)
	opts = opts or {}
	local server = self
	local name = opts.Name or `Player{userId}`
	local player = Roblox.newInstance("Player", name, {
		UserId = userId,
		DisplayName = opts.DisplayName or name,
		AccountAge = opts.AccountAge or 100,
		_server = server,
	})
	rawset(player, "Kick", function(p, message)
		table.insert(server.kicks, { player = p, userId = p.UserId, message = message, time = server.world.sched.now })
		server:_log("kick", `{p.Name} kicked: {tostring(message)}`)
		server:removePlayer(p)
	end)
	player.Parent = self.Players
	table.insert(self.playerList, player)
	self.Players.PlayerAdded:Fire(player)
	return player
end

function Server:removePlayer(player)
	local i = table.find(self.playerList, player)
	if i == nil then
		return
	end
	self.Players.PlayerRemoving:Fire(player)
	i = table.find(self.playerList, player)
	if i then
		table.remove(self.playerList, i)
	end
	player.Parent = nil
end

function Server:wasKicked(userId: number): (boolean, string?)
	for _, k in self.kicks do
		if k.userId == userId then
			return true, k.message
		end
	end
	return false, nil
end

-- Lifecycle ----------------------------------------------------------------

function Server:_kill(reason: string)
	if not self.alive then
		return
	end
	self.alive = false
	self.closing = true
	self.deathReason = reason
	self.diedAt = self.world.sched.now
	self:_log("sim", `server died ({reason})`)
end

-- Kills the server immediately: no BindToClose, no further saves; every
-- thread it owns (waits, DataStore requests in flight, subscriptions) stops.
function Server:crash()
	self:_kill("crash")
end

-- Starts a Roblox-style shutdown: players are removed (PlayerRemoving fires),
-- every BindToClose callback runs on its own thread, and the server dies when
-- all callbacks returned or 30 virtual seconds passed. Does not advance time.
function Server:beginShutdown(opts)
	if not self.alive or self._shutdown then
		return
	end
	opts = opts or {}
	self.closing = true
	local sd = { start = self.world.sched.now, pending = 0, timedOut = false }
	self._shutdown = sd
	if opts.kickPlayers ~= false then
		for _, p in table.clone(self.playerList) do
			self:removePlayer(p)
		end
	end
	for _, fn in table.clone(self._bindToClose) do
		sd.pending += 1
		local co = coroutine.create(function()
			local ok, err = xpcall(fn, debug.traceback)
			if not ok then
				self:_log("error", "BindToClose callback errored: " .. tostring(err))
			end
			sd.pending -= 1
		end)
		self.world.sched:resume(self, co)
	end
end

-- beginShutdown + advance until the server is dead. Returns
-- {elapsed = virtual seconds, timedOut = boolean}.
function Server:shutdown(opts)
	self:beginShutdown(opts)
	local start = self._shutdown and self._shutdown.start or self.world.sched.now
	self.world.sched:runUntil(function()
		return not self.alive
	end, 31)
	return { elapsed = self.world.sched.now - start, timedOut = self._shutdown and self._shutdown.timedOut or false }
end

-- Modules ------------------------------------------------------------------

function Server:_makeRequire(fromPath: string?)
	return function(target)
		if type(target) == "string" then
			if fromPath == nil then
				error("string require from a module without a file path", 2)
			end
			local file = resolveStringRequire(fromPath, target)
			return self:_requireFile(file, self.scripts[file])
		end
		local file = type(target) == "table" and rawget(target, "_path") or nil
		if not file then
			error(`require: {tostring(target)} is not a ModuleScript backed by a file`, 2)
		end
		return self:_requireFile(file, target)
	end
end

function Server:_requireFile(path: string, scriptInst)
	local cached = self.modules[path]
	if cached ~= nil then
		return if cached == NIL_RESULT then nil else cached
	end
	if self.loading[path] then
		error(`cyclic require of {displayPath(path)}`, 0)
	end
	if scriptInst == nil then
		scriptInst = self.scripts[path]
		if scriptInst == nil then
			scriptInst = Roblox.newInstance("ModuleScript", moduleName(path))
			scriptInst.Parent = self.ServerScriptService
		end
	end
	rawset(scriptInst, "_path", path)
	rawset(scriptInst, "_server", self)
	self.scripts[path] = scriptInst

	local env = table.clone(self.env)
	env.script = scriptInst
	env.require = self:_makeRequire(path)
	local fn, err = __load(compileFile(path), "@" .. displayPath(path), env)
	if fn == nil then
		error(`failed to load {path}: {err}`, 0)
	end

	self.loading[path] = true
	local result
	local running = coroutine.running()
	if running == self.world.sched.mainThread or not coroutine.isyieldable() then
		-- Called from the test's main thread: run on a server thread and drive
		-- the simulation if the module yields while loading.
		local job = self:spawn(fn)
		if not job.done then
			self.world.sched:runUntil(function()
				return job.done
			end, Sim.defaultTimeout)
		end
		self.loading[path] = nil
		if not job.done then
			error(`module {displayPath(path)} did not finish loading`, 0)
		end
		result = job:result()
	else
		local ok, r = pcall(fn)
		self.loading[path] = nil
		if not ok then
			error(r, 0)
		end
		result = r
	end
	self.modules[path] = if result == nil then NIL_RESULT else result
	return result
end

-- Mounts a directory as a ModuleScript (with init.luau) / Folder tree.
function Server:mountTree(diskPath: string, parent, name: string?)
	local inst
	if isDir(diskPath) then
		local init = nil
		for _, candidate in { "/init.luau", "/init.lua" } do
			if isFile(diskPath .. candidate) then
				init = diskPath .. candidate
			end
		end
		inst = Roblox.newInstance(if init then "ModuleScript" else "Folder", name or moduleName(diskPath))
		if init then
			rawset(inst, "_path", init)
			self.scripts[init] = inst
		end
		for _, entry in listdir(diskPath) do
			local child = `{diskPath}/{entry.name}`
			if entry.dir or (string.match(entry.name, "%.luau?$") and not string.match(entry.name, "^init%.luau?$")) then
				self:mountTree(child, inst)
			end
		end
	else
		inst = Roblox.newInstance("ModuleScript", name or moduleName(diskPath))
		rawset(inst, "_path", diskPath)
		self.scripts[diskPath] = inst
	end
	rawset(inst, "_server", self)
	inst.Parent = parent
	return inst
end

-- server:require(pathOrModuleScript, {name?, parent?}) -> module result
-- Paths are relative to the repo root (or absolute). A directory is mounted
-- as a ModuleScript tree (init.luau + children) so `script.X` and string
-- requires work. Each server gets its own fresh module state.
function Server:require(target, opts)
	opts = opts or {}
	if type(target) == "table" then
		return self:_requireFile(rawget(target, "_path"), target)
	end
	local path = absPath(target)
	local parent = opts.parent or self.ServerScriptService
	local inst
	if isDir(path) then
		inst = self.scripts[path .. "/init.luau"] or self.scripts[path .. "/init.lua"]
		if inst == nil then
			inst = self:mountTree(path, parent, opts.name)
		end
	else
		local file = resolveFile(path)
		if file == nil then
			error(`server:require: no module at {target}`, 2)
		end
		inst = self.scripts[file]
		if inst == nil then
			inst = self:mountTree(file, parent, opts.name)
		end
	end
	if rawget(inst, "_path") == nil then
		error(`server:require: {target} has no init.luau`, 2)
	end
	return self:_requireFile(rawget(inst, "_path"), inst)
end

-- Runs a source string as a server Script (own env, `script` = a Script).
function Server:runScript(source: string, chunkname: string?)
	local env = table.clone(self.env)
	local scriptInst = Roblox.newInstance("Script", chunkname or "Script")
	scriptInst.Parent = self.ServerScriptService
	env.script = scriptInst
	env.require = self:_makeRequire(nil)
	local bc, err = __compile(source)
	if bc == nil then
		error(err, 2)
	end
	local fn = __load(bc, "=" .. (chunkname or "Script"), env)
	return self:spawn(fn)
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- Sim.reset(options?) -> fresh world. Options: seed, plus anything Sim.configure takes.
function Sim.reset(options)
	W = newWorld(options)
	Sim.world = W
	if options then
		Sim.configure(options)
	end
	return W
end

-- Sim.configure{latency = {min,max}|n, conflictRate, throttle, maxVersions,
--   listPageSize, messageLatency, messageDelay = {min,max}|n, messageDropRate}
function Sim.configure(options)
	local ds = W.ds.options
	local bus = W.bus.options
	for k, v in options do
		if k == "latency" or k == "conflictRate" or k == "throttle" or k == "maxVersions" or k == "listPageSize" then
			ds[k] = v
		elseif k == "messageLatency" then
			bus.latency = v
		elseif k == "messageDelay" or k == "messageDropRate" then
			bus[k] = v
		elseif k ~= "seed" then
			error(`Sim.configure: unknown option {k}`, 2)
		end
	end
end

function Sim.now(): number
	return W.sched.now
end

function Sim.frame(): number
	return W.sched.frame
end

function Sim.unixTime(): number
	return Sim.EPOCH + W.sched.now
end

function Sim.advance(seconds: number)
	W.sched:advance(seconds)
end

function Sim.step(frames: number?)
	for _ = 1, frames or 1 do
		W.sched:step()
	end
end

-- Advances until pred() is true. Returns true, or false after maxSeconds (default 600).
function Sim.runUntil(pred: () -> boolean, maxSeconds: number?): boolean
	return W.sched:runUntil(pred, maxSeconds)
end

-- Waits (advancing time) until every job is done; returns true or false on timeout.
function Sim.awaitJobs(jobs, maxSeconds: number?): boolean
	return W.sched:runUntil(function()
		for _, j in jobs do
			if not j.done then
				return false
			end
		end
		return true
	end, maxSeconds)
end

function Sim.servers()
	return W.servers
end

-- Error injection. spec = {method?, store?, key?, server?, rate?, count?,
-- callNumber?, message?, phase = "before"|"after", when = fn(info)?}
-- method: "UpdateAsync", "GetAsync", "SetAsync", "RemoveAsync", "IncrementAsync",
-- "GetVersionAsync", "ListVersionsAsync", "AdvanceToNextPageAsync",
-- "PublishAsync", "SubscribeAsync", or a list. Returns a rule (rule:remove(), rule.hits).
function Sim.injectError(spec)
	return DS.injectError(W.ds, spec or {})
end

function Sim.clearInjectedErrors()
	table.clear(W.ds.rules)
end

function Sim.callCount(): number
	return W.ds.callCount
end

-- World totals: {calls = {[method] = n}, bytesWritten, bytesRead, writes,
-- conflicts, throttled, publishes, delivered, dropped}
function Sim.stats()
	local t = table.clone(W.ds.totals)
	t.calls = table.clone(t.calls)
	for k, v in W.bus.totals do
		t[k] = v
	end
	return t
end

-- Direct backend access (no latency, not counted) ---------------------------

-- Sim.peek(storeName, key, scope?) -> decoded value | nil, keyInfo | nil
function Sim.peek(storeName: string, key: string, scope: string?)
	local rec = DS.getStoreRec(W.ds, storeName, scope)
	local k = rec and rec.keys[key]
	if k == nil or k.value == nil then
		return nil, nil
	end
	return JSON.decode(k.value), DS.keyInfo(k, k.current)
end

function Sim.rawJson(storeName: string, key: string, scope: string?): string?
	local rec = DS.getStoreRec(W.ds, storeName, scope)
	local k = rec and rec.keys[key]
	return k and k.value
end

-- Writes a value directly (validated + JSON round-tripped like a real write).
function Sim.poke(storeName: string, key: string, value: any, opts)
	opts = opts or {}
	local rec = DS.getStoreRec(W.ds, storeName, opts.scope, true)
	if value == nil then
		if rec.keys[key] and rec.keys[key].value then
			DS.commit(W.ds, rec, key, nil, {}, {})
		end
		return
	end
	DS.commit(W.ds, rec, key, DS.encodeValue(value), opts.userIds, opts.metadata)
end

-- Versions of a key: { {Version, CreatedTime, IsDeleted, value}, ... } oldest first.
function Sim.versions(storeName: string, key: string, scope: string?)
	local rec = DS.getStoreRec(W.ds, storeName, scope)
	local k = rec and rec.keys[key]
	local out = {}
	for _, e in (k and k.versions or {}) do
		table.insert(out, {
			Version = e.Version,
			CreatedTime = e.CreatedTime,
			IsDeleted = e.IsDeleted,
			value = if e.json then JSON.decode(e.json) else nil,
		})
	end
	return out
end

function Sim.keys(storeName: string, scope: string?)
	local rec = DS.getStoreRec(W.ds, storeName, scope)
	local out = {}
	for k, v in (rec and rec.keys or {}) do
		if v.value ~= nil then
			table.insert(out, k)
		end
	end
	table.sort(out)
	return out
end

-- Uncaught errors from simulated threads (Roblox would print them to output).
function Sim.threadErrors()
	return W.sched.errors
end

function Sim.clearThreadErrors()
	table.clear(W.sched.errors)
end

Sim._mainThread = coroutine.running()
Sim.reset()

return Sim
