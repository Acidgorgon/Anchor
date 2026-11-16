--!optimize 2
-- DataStoreService mock: one backend per Sim world (shared by every server),
-- one DataStoreService instance per server (own counters and budgets).
--
-- Semantics modelled on Roblox:
--   * values are stored as JSON text (Roblox rules, see json.luau); every read
--     decodes a fresh copy; the 4 MB (4,194,304 byte) limit applies to the text
--   * UpdateAsync(key, transform): transform(currentCopy, keyInfo|nil) runs on
--     the calling server, may not yield, returning nil cancels the write; it
--     returns (value, userIds?, metadata?). With `conflictRate` > 0 the
--     transform is sometimes called twice (first result discarded), like a
--     write conflict retry. Returns (savedValueCopy, DataStoreKeyInfo).
--   * every write creates a version (GetVersionAsync / ListVersionsAsync);
--     RemoveAsync writes a tombstone version
--   * each call takes virtual latency (default 0.1-0.3 s): half before the
--     commit, half after. A server that crashes in the first half never
--     writes; in the second half the write is committed but never observed.
--   * error injection (Sim.injectError) by method / store / key / server /
--     call number / probability, before or after the commit
--   * optional throttling (budgets of 60 + 10 x players per minute per
--     category, 30-deep request queue, 6 s same-key write cooldown)

local JSON = require("./json")
local Roblox = require("./roblox")

local DS = {}

local MAX_VALUE_BYTES = 4194304
local MAX_KEY_LENGTH = 50
local MAX_NAME_LENGTH = 50
local MAX_METADATA_BYTES = 300
local MAX_USER_IDS = 4

export type Rule = {
	method: (string | { [string]: boolean })?,
	store: string?,
	key: string?,
	server: any?,
	rate: number?,
	count: number?,
	callNumber: number?,
	message: string?,
	phase: ("before" | "after")?,
	when: ((info: any) -> boolean)?,
	hits: number,
	remove: (self: any) -> (),
}

local DEFAULT_ERROR = "502: API Services rejected request with error. HTTP 500 (Internal Server Error)"

function DS.newBackend(world)
	return {
		world = world,
		stores = {}, -- [name .. "\0" .. scope] = { name, scope, keys = {} }
		rules = {},
		callCount = 0,
		keyLastWrite = {},
		totals = { calls = {}, bytesWritten = 0, bytesRead = 0, writes = 0, conflicts = 0, throttled = 0 },
		options = {
			latency = { 0.1, 0.3 },
			conflictRate = 0,
			throttle = false,
			maxVersions = nil, -- nil = keep every version
			listPageSize = 10,
		},
	}
end

local function storeId(name: string, scope: string): string
	return name .. "\0" .. scope
end

function DS.getStoreRec(backend, name: string, scope: string?, create: boolean?)
	local id = storeId(name, scope or "global")
	local rec = backend.stores[id]
	if rec == nil and create then
		rec = { name = name, scope = scope or "global", keys = {} }
		backend.stores[id] = rec
	end
	return rec
end

--------------------------------------------------------------------------------
-- Error injection
--------------------------------------------------------------------------------

local RuleMT = {}
RuleMT.__index = RuleMT
function RuleMT.remove(self)
	local list = self._backend.rules
	local i = table.find(list, self)
	if i then
		table.remove(list, i)
	end
end

function DS.injectError(backend, spec): Rule
	local rule = setmetatable(table.clone(spec), RuleMT) :: any
	rule._backend = backend
	rule.hits = 0
	if type(rule.method) == "string" then
		rule.method = { [rule.method] = true }
	elseif type(rule.method) == "table" and rule.method[1] then
		local set = {}
		for _, m in rule.method do
			set[m] = true
		end
		rule.method = set
	end
	if rule.count == nil then
		rule.count = if rule.callNumber then 1 else math.huge
	end
	table.insert(backend.rules, rule)
	return rule
end

local function matchRule(backend, info)
	for _, rule in backend.rules do
		if rule.count > 0
			and (rule.method == nil or rule.method[info.method])
			and (rule.store == nil or rule.store == info.store)
			and (rule.key == nil or rule.key == info.key)
			and (rule.server == nil or rule.server == info.server)
			and (rule.callNumber == nil or rule.callNumber == info.callNumber)
			and (rule.when == nil or rule.when(info))
		then
			if rule.rate == nil or backend.world.rng:NextNumber() < rule.rate then
				rule.count -= 1
				rule.hits += 1
				return rule
			end
		end
	end
	return nil
end

DS.matchRule = matchRule

--------------------------------------------------------------------------------
-- Records, versions, key info
--------------------------------------------------------------------------------

local function versionString(rec, n: number, writtenMs: number): string
	return string.format("%016X.%010d.%016X.01", rec.createdTime, n, writtenMs)
end

local function deepCopy(v)
	if type(v) ~= "table" then
		return v
	end
	local out = {}
	for k, x in v do
		out[k] = deepCopy(x)
	end
	return out
end

local KeyInfoMT = { __robloxtype = "DataStoreKeyInfo" }
KeyInfoMT.__index = KeyInfoMT
function KeyInfoMT.GetUserIds(self)
	return deepCopy(rawget(self, "_userIds"))
end
function KeyInfoMT.GetMetadata(self)
	return deepCopy(rawget(self, "_metadata"))
end

local function keyInfo(rec, entry)
	return setmetatable({
		Version = entry.Version,
		CreatedTime = entry.keyCreated,
		UpdatedTime = entry.CreatedTime,
		_userIds = entry.userIds,
		_metadata = entry.metadata,
	}, KeyInfoMT)
end

local VersionInfoMT = { __robloxtype = "DataStoreObjectVersionInfo" }
VersionInfoMT.__index = VersionInfoMT

local function validateUserIds(userIds)
	if userIds == nil then
		return {}
	end
	if type(userIds) ~= "table" then
		error("Argument userIds must be an array of numbers", 0)
	end
	if #userIds > MAX_USER_IDS then
		error(`UserIds can contain at most {MAX_USER_IDS} entries`, 0)
	end
	local out = {}
	for i, id in userIds do
		if type(i) ~= "number" or type(id) ~= "number" or id % 1 ~= 0 then
			error("Argument userIds must be an array of integers", 0)
		end
		out[i] = id
	end
	return out
end

local function validateMetadata(metadata)
	if metadata == nil then
		return {}
	end
	if type(metadata) ~= "table" then
		error("Argument metadata must be a table", 0)
	end
	local json = JSON.encode(metadata)
	if #json > MAX_METADATA_BYTES then
		error(`Metadata exceeds {MAX_METADATA_BYTES} bytes`, 0)
	end
	return JSON.decode(json)
end

-- Commits a new version. json == nil writes a tombstone. Returns the entry.
local function commit(backend, storeRec, key: string, json: string?, userIds, metadata)
	local nowMs = backend.world:unixMillis()
	local rec = storeRec.keys[key]
	if rec == nil then
		rec = { createdTime = nowMs, versionNum = 0, versions = {}, value = nil, current = nil }
		storeRec.keys[key] = rec
	elseif rec.value == nil and json ~= nil then
		rec.createdTime = nowMs -- key re-created after removal
	end
	rec.versionNum += 1
	local entry = {
		Version = versionString(rec, rec.versionNum, nowMs),
		CreatedTime = nowMs,
		IsDeleted = json == nil,
		json = json,
		userIds = userIds or {},
		metadata = metadata or {},
		keyCreated = rec.createdTime,
	}
	table.insert(rec.versions, entry)
	local maxVersions = backend.options.maxVersions
	if maxVersions and #rec.versions > maxVersions then
		table.remove(rec.versions, 1)
	end
	rec.value = json
	rec.current = entry
	backend.keyLastWrite[storeId(storeRec.name, storeRec.scope) .. "\0" .. key] = backend.world.sched.now
	backend.totals.writes += 1
	return entry, rec
end

DS.commit = commit
DS.keyInfo = keyInfo

local function encodeValue(value): string
	local json = JSON.encode(value)
	if #json > MAX_VALUE_BYTES then
		error(`105: Serialized value converted byte size exceeds max size {MAX_VALUE_BYTES} bytes (got {#json})`, 0)
	end
	return json
end

DS.encodeValue = encodeValue

--------------------------------------------------------------------------------
-- Throttling (opt-in)
--------------------------------------------------------------------------------

local CATEGORY = {
	GetAsync = { "get" },
	SetAsync = { "set" },
	IncrementAsync = { "set" },
	RemoveAsync = { "set" },
	UpdateAsync = { "get", "set" },
	GetVersionAsync = { "getVersion" },
	ListVersionsAsync = { "list" },
	AdvanceToNextPageAsync = { "list" },
}

local WRITES = { SetAsync = true, IncrementAsync = true, RemoveAsync = true, UpdateAsync = true }

local function perMinute(server, category: string): number
	local players = #server.playerList
	if category == "get" or category == "set" then
		return 60 + 10 * players
	end
	return 5 + 2 * players
end

local function budgetFor(server, category: string)
	local budgets = server._dsBudgets
	local b = budgets[category]
	local now = server.world.sched.now
	local rate = perMinute(server, category)
	if b == nil then
		b = { value = rate, last = now, queued = 0 }
		budgets[category] = b
	else
		b.value = math.min(rate * 3, b.value + (now - b.last) * rate / 60)
		b.last = now
	end
	return b, rate
end

function DS.budget(server, category: string): number
	if not server.world.ds.options.throttle then
		return 1e6
	end
	local b = budgetFor(server, category)
	return math.floor(b.value)
end

local function throttle(backend, server, method: string, storeKeyId: string)
	local sched = backend.world.sched
	for _, category in CATEGORY[method] or {} do
		local b, rate = budgetFor(server, category)
		if b.value < 1 then
			if b.queued >= 30 then
				error(`Request was throttled, but the throttled request queue was full. ({method})`, 0)
			end
			b.queued += 1
			backend.totals.throttled += 1
			server.stats.throttled += 1
			while true do
				sched:wait(server, (1 - b.value) * 60 / rate)
				b = budgetFor(server, category)
				if b.value >= 1 then
					break
				end
			end
			b.queued -= 1
		end
		b.value -= 1
	end
	if WRITES[method] then
		local last = backend.keyLastWrite[storeKeyId]
		if last and sched.now - last < 6 then
			backend.totals.throttled += 1
			server.stats.throttled += 1
			sched:wait(server, 6 - (sched.now - last))
		end
	end
end

--------------------------------------------------------------------------------
-- Call pipeline
--------------------------------------------------------------------------------

local function bump(t, k)
	t[k] = (t[k] or 0) + 1
end

local function latency(backend): number
	local l = backend.options.latency
	if type(l) == "number" then
		return l
	end
	return l[1] + (l[2] - l[1]) * backend.world.rng:NextNumber()
end

local function checkKey(key)
	if type(key) ~= "string" then
		error("Argument 1 missing or nil", 0)
	end
	if #key == 0 then
		error("101: Key name can't be empty.", 0)
	end
	if #key > MAX_KEY_LENGTH then
		error(`103: Key name exceeds the {MAX_KEY_LENGTH} character limit.`, 0)
	end
end

-- Runs body() as one DataStore request of `method` from `store`'s server.
local function request(store, method: string, key: string?, body: () -> ...any): ...any
	local server = store._server
	local backend = store._backend
	local sched = backend.world.sched
	if not server.alive then
		error("DataStore request from a dead server", 0)
	end
	sched:assertCanYield(`DataStore:{method}`)
	if key ~= nil or method ~= "AdvanceToNextPageAsync" then
		checkKey(key)
	end
	backend.callCount += 1
	local info = {
		method = method,
		store = store.Name,
		scope = store._scope,
		key = key,
		server = server,
		callNumber = backend.callCount,
	}
	bump(server.stats.calls, method)
	bump(backend.totals.calls, method)
	if backend.options.throttle then
		throttle(backend, server, method, storeId(store.Name, store._scope) .. "\0" .. tostring(key))
	end
	local lat = latency(backend)
	sched:wait(server, lat / 2)
	local rule = matchRule(backend, info)
	if rule and rule.phase ~= "after" then
		error(rule.message or DEFAULT_ERROR, 0)
	end
	local results = table.pack(body())
	sched:wait(server, lat / 2)
	if rule then -- phase == "after": committed, but the caller sees an error
		error(rule.message or DEFAULT_ERROR, 0)
	end
	return table.unpack(results, 1, results.n)
end

--------------------------------------------------------------------------------
-- GlobalDataStore
--------------------------------------------------------------------------------

local DataStore = {}
local DataStoreMT = { __robloxtype = "Instance", __index = DataStore }
function DataStoreMT.__tostring(self)
	return self.Name
end

function DataStore.IsA(self, name)
	return name == "DataStore" or name == "GlobalDataStore" or name == "Instance"
end

local function callTransform(sched, transform, ...)
	local co = coroutine.create(transform)
	local res = table.pack(coroutine.resume(co, ...))
	if not res[1] then
		error(res[2], 0)
	end
	if coroutine.status(co) ~= "dead" then
		sched:unwait(co)
		coroutine.close(co)
		error("UpdateAsync: transform function yielded; callbacks cannot yield", 0)
	end
	return res[2], res[3], res[4]
end

function DataStore.UpdateAsync(self, key: string, transform)
	if type(transform) ~= "function" then
		error("Argument 2 missing or nil", 2)
	end
	local backend = self._backend
	local server = self._server
	return request(self, "UpdateAsync", key, function()
		local storeRec = DS.getStoreRec(backend, self.Name, self._scope, true)
		local rec = storeRec.keys[key]
		local cur = rec and rec.value
		if cur then
			server.stats.bytesRead += #cur
			backend.totals.bytesRead += #cur
		end
		local function run()
			local value = if cur then JSON.decode(cur) else nil
			local info = if cur then keyInfo(rec, rec.current) else nil
			return callTransform(backend.world.sched, transform, value, info)
		end
		if backend.options.conflictRate > 0 and backend.world.rng:NextNumber() < backend.options.conflictRate then
			run()
			backend.totals.conflicts += 1
			server.stats.conflicts += 1
		end
		local newValue, userIds, metadata = run()
		if newValue == nil then
			return nil, nil
		end
		local json = encodeValue(newValue)
		local entry, newRec = commit(backend, storeRec, key, json, validateUserIds(userIds), validateMetadata(metadata))
		server.stats.bytesWritten += #json
		backend.totals.bytesWritten += #json
		bump(server.stats.writesByKey, key)
		return JSON.decode(json), keyInfo(newRec, entry)
	end)
end

function DataStore.GetAsync(self, key: string, _options)
	local backend = self._backend
	local server = self._server
	return request(self, "GetAsync", key, function()
		local storeRec = DS.getStoreRec(backend, self.Name, self._scope)
		local rec = storeRec and storeRec.keys[key]
		if rec == nil or rec.value == nil then
			return nil, nil
		end
		server.stats.bytesRead += #rec.value
		backend.totals.bytesRead += #rec.value
		return JSON.decode(rec.value), keyInfo(rec, rec.current)
	end)
end

function DataStore.SetAsync(self, key: string, value, userIds, options)
	if value == nil then
		error("Argument 2 missing or nil", 2)
	end
	local backend = self._backend
	local server = self._server
	return request(self, "SetAsync", key, function()
		local json = encodeValue(value)
		local metadata = nil
		if type(options) == "table" and options._metadata then
			metadata = options._metadata
		end
		local storeRec = DS.getStoreRec(backend, self.Name, self._scope, true)
		local entry = commit(backend, storeRec, key, json, validateUserIds(userIds), validateMetadata(metadata))
		server.stats.bytesWritten += #json
		backend.totals.bytesWritten += #json
		bump(server.stats.writesByKey, key)
		return entry.Version
	end)
end

function DataStore.IncrementAsync(self, key: string, delta: number?, userIds, _options)
	local backend = self._backend
	local server = self._server
	return request(self, "IncrementAsync", key, function()
		local storeRec = DS.getStoreRec(backend, self.Name, self._scope, true)
		local rec = storeRec.keys[key]
		local cur = if rec and rec.value then JSON.decode(rec.value) else 0
		if type(cur) ~= "number" then
			error("IncrementAsync: cannot increment a non-number value", 0)
		end
		local newValue = cur + (delta or 1)
		local json = encodeValue(newValue)
		local entry, newRec = commit(backend, storeRec, key, json, validateUserIds(userIds), nil)
		server.stats.bytesWritten += #json
		backend.totals.bytesWritten += #json
		return newValue, keyInfo(newRec, entry)
	end)
end

function DataStore.RemoveAsync(self, key: string)
	local backend = self._backend
	return request(self, "RemoveAsync", key, function()
		local storeRec = DS.getStoreRec(backend, self.Name, self._scope, true)
		local rec = storeRec.keys[key]
		if rec == nil or rec.value == nil then
			return nil, nil
		end
		local old = JSON.decode(rec.value)
		local entry, newRec = commit(backend, storeRec, key, nil, rec.current.userIds, rec.current.metadata)
		return old, keyInfo(newRec, entry)
	end)
end

function DataStore.GetVersionAsync(self, key: string, version: string)
	local backend = self._backend
	local server = self._server
	return request(self, "GetVersionAsync", key, function()
		if type(version) ~= "string" then
			error("GetVersionAsync: version is not valid", 0)
		end
		local storeRec = DS.getStoreRec(backend, self.Name, self._scope)
		local rec = storeRec and storeRec.keys[key]
		if rec then
			for _, entry in rec.versions do
				if entry.Version == version then
					if entry.IsDeleted then
						return nil, nil
					end
					server.stats.bytesRead += #entry.json
					backend.totals.bytesRead += #entry.json
					return JSON.decode(entry.json), keyInfo(rec, entry)
				end
			end
		end
		error(`GetVersionAsync: version "{version}" is not valid`, 0)
	end)
end

local PagesMT = { __robloxtype = "Instance" }
PagesMT.__index = PagesMT

function PagesMT.GetCurrentPage(self)
	return table.clone(self._pages[self._index] or {})
end

function PagesMT.AdvanceToNextPageAsync(self)
	return request(self._store, "AdvanceToNextPageAsync", self._key, function()
		if self._index >= #self._pages then
			error("AdvanceToNextPageAsync: no more pages", 0)
		end
		self._index += 1
		self.IsFinished = self._index >= #self._pages
	end)
end

function DataStore.ListVersionsAsync(self, key: string, sortDirection, minDate: number?, maxDate: number?, pageSize: number?)
	local backend = self._backend
	return request(self, "ListVersionsAsync", key, function()
		local storeRec = DS.getStoreRec(backend, self.Name, self._scope)
		local rec = storeRec and storeRec.keys[key]
		local items = {}
		for _, entry in (rec and rec.versions or {}) do
			local t = entry.CreatedTime
			if (minDate == nil or minDate == 0 or t >= minDate) and (maxDate == nil or maxDate == 0 or t <= maxDate) then
				table.insert(
					items,
					setmetatable({ Version = entry.Version, CreatedTime = t, IsDeleted = entry.IsDeleted }, VersionInfoMT)
				)
			end
		end
		if sortDirection ~= nil and sortDirection == Roblox.Enum.SortDirection.Descending then
			local n = #items
			for i = 1, n // 2 do
				items[i], items[n - i + 1] = items[n - i + 1], items[i]
			end
		end
		local size = if pageSize and pageSize > 0 then pageSize else backend.options.listPageSize
		local pages = {}
		for i = 1, #items, size do
			table.insert(pages, table.move(items, i, math.min(i + size - 1, #items), 1, {}))
		end
		if #pages == 0 then
			pages[1] = {}
		end
		return setmetatable({ _pages = pages, _index = 1, IsFinished = #pages <= 1, _store = self, _key = key }, PagesMT)
	end)
end

--------------------------------------------------------------------------------
-- Service (one per server)
--------------------------------------------------------------------------------

function DS.newService(backend, server)
	local service = Roblox.newInstance("DataStoreService", "DataStoreService")
	local cache = {}
	local function getStore(name: string, scope: string?, _options)
		if type(name) ~= "string" then
			error("Argument 1 missing or nil", 3)
		end
		if #name == 0 or #name > MAX_NAME_LENGTH then
			error(`DataStore name must be 1-{MAX_NAME_LENGTH} characters`, 3)
		end
		scope = scope or "global"
		local id = storeId(name, scope :: string)
		local store = cache[id]
		if store == nil then
			store = setmetatable({
				Name = name,
				ClassName = "DataStore",
				_scope = scope,
				_server = server,
				_backend = backend,
			}, DataStoreMT)
			cache[id] = store
		end
		return store
	end
	rawset(service, "GetDataStore", function(_self, name, scope, options)
		return getStore(name, scope, options)
	end)
	rawset(service, "GetGlobalDataStore", function(_self)
		return getStore("GlobalDataStore", "global")
	end)
	rawset(service, "GetRequestBudgetForRequestType", function(_self, requestType)
		local name = if type(requestType) == "table" then requestType.Name else tostring(requestType)
		local category = if name == "GetAsync" then "get"
			elseif name == "SetIncrementAsync" then "set"
			elseif name == "UpdateAsync" then "set"
			elseif name == "GetVersionAsync" then "getVersion"
			elseif name == "ListAsync" then "list"
			else "get"
		if name == "UpdateAsync" then
			return math.min(DS.budget(server, "get"), DS.budget(server, "set"))
		end
		return DS.budget(server, category)
	end)
	return service
end

return DS
