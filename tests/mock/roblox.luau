--!optimize 2
-- Stateless-ish Roblox types for the mock: typeof, Enum, DateTime, Random and a
-- small Instance model (Name/ClassName/Parent/children, FindFirstChild,
-- WaitForChild, GetChildren, IsA, Destroy, attributes, `inst.ChildName`).

local R = {}

--------------------------------------------------------------------------------
-- typeof
--------------------------------------------------------------------------------

local rawtypeof = typeof

function R.typeof(value: any): string
	local t = rawtypeof(value)
	if t == "table" then
		local mt = getmetatable(value)
		if type(mt) == "table" then
			local rt = rawget(mt, "__robloxtype")
			if rt then
				return rt
			end
		end
	elseif t == "vector" then
		return "Vector3"
	end
	return t
end

--------------------------------------------------------------------------------
-- Enum (shared by all servers, like the engine's)
--------------------------------------------------------------------------------

local EnumItemMT = { __robloxtype = "EnumItem" }
EnumItemMT.__index = EnumItemMT
function EnumItemMT.__tostring(self)
	return `Enum.{self.EnumType.Name}.{self.Name}`
end
function EnumItemMT.IsA(self, name)
	return self.EnumType.Name == name
end

local EnumMT = { __robloxtype = "Enum" }
function EnumMT.__index(enumType, itemName)
	if type(itemName) ~= "string" then
		return nil
	end
	if itemName == "GetEnumItems" then
		return function(self)
			local items = {}
			for _, v in rawget(self, "_items") do
				table.insert(items, v)
			end
			table.sort(items, function(a, b)
				return a.Value < b.Value
			end)
			return items
		end
	end
	local items = rawget(enumType, "_items")
	local item = items[itemName]
	if item == nil then
		local count = rawget(enumType, "_count")
		rawset(enumType, "_count", count + 1)
		item = setmetatable({ Name = itemName, Value = count, EnumType = enumType }, EnumItemMT)
		items[itemName] = item
	end
	return item
end
function EnumMT.__tostring(self)
	return rawget(self, "Name")
end

local function newEnum(name: string, itemNames: { string }?)
	local e = setmetatable({ Name = name, _count = 0, _items = {} }, EnumMT)
	for _, item in itemNames or {} do
		local _ = e[item]
	end
	return e
end

R.Enum = setmetatable({}, {
	__robloxtype = "Enums",
	__index = function(enums, typeName)
		local e = newEnum(typeName)
		rawset(enums, typeName, e)
		return e
	end,
})
rawset(R.Enum, "SortDirection", newEnum("SortDirection", { "Ascending", "Descending" }))
rawset(
	R.Enum,
	"DataStoreRequestType",
	newEnum("DataStoreRequestType", {
		"GetAsync",
		"SetIncrementAsync",
		"UpdateAsync",
		"GetSortedAsync",
		"SetIncrementSortedAsync",
		"OnUpdate",
		"ListAsync",
		"GetVersionAsync",
		"RemoveVersionAsync",
	})
)

--------------------------------------------------------------------------------
-- DateTime (clock supplied per server)
--------------------------------------------------------------------------------

local DateTimeMT = { __robloxtype = "DateTime" }
function DateTimeMT.__index(self, key)
	if key == "UnixTimestamp" then
		return rawget(self, "UnixTimestampMillis") // 1000
	end
	return DateTimeMT[key]
end
function DateTimeMT.__eq(a, b)
	return a.UnixTimestampMillis == b.UnixTimestampMillis
end
function DateTimeMT.__lt(a, b)
	return a.UnixTimestampMillis < b.UnixTimestampMillis
end
function DateTimeMT.__le(a, b)
	return a.UnixTimestampMillis <= b.UnixTimestampMillis
end
function DateTimeMT.ToIsoDate(self)
	local ms = self.UnixTimestampMillis
	return os.date("!%Y-%m-%dT%H:%M:%S", ms // 1000) .. string.format(".%03dZ", ms % 1000)
end
function DateTimeMT.ToUniversalTime(self)
	local t = os.date("!*t", self.UnixTimestampMillis // 1000) :: any
	return {
		Year = t.year,
		Month = t.month,
		Day = t.day,
		Hour = t.hour,
		Minute = t.min,
		Second = t.sec,
		Millisecond = self.UnixTimestampMillis % 1000,
	}
end
function DateTimeMT.__tostring(self)
	return self:ToIsoDate()
end

local function dateTimeFromMillis(ms: number)
	return setmetatable({ UnixTimestampMillis = math.floor(ms) }, DateTimeMT)
end

-- nowMillis: () -> number (virtual unix time in ms for that server)
function R.makeDateTime(nowMillis: () -> number)
	return table.freeze({
		now = function()
			return dateTimeFromMillis(nowMillis())
		end,
		fromUnixTimestamp = function(s: number)
			return dateTimeFromMillis(s * 1000)
		end,
		fromUnixTimestampMillis = dateTimeFromMillis,
		fromUniversalTime = function(y, mo, d, h, mi, s, ms)
			local t = os.time({ year = y or 1970, month = mo or 1, day = d or 1, hour = h or 0, min = mi or 0, sec = s or 0 })
			-- os.time interprets local time; the harness host runs with TZ as set, correct for UTC
			local utcOffset = os.time(os.date("!*t", 0) :: any)
			return dateTimeFromMillis((t - utcOffset) * 1000 + (ms or 0))
		end,
	})
end

--------------------------------------------------------------------------------
-- Random (deterministic Park-Miller generator; exact in doubles)
--------------------------------------------------------------------------------

local RandomMT = { __robloxtype = "Random" }
RandomMT.__index = RandomMT

local function nextRaw(self): number
	self._state = (self._state * 48271) % 2147483647
	return self._state
end

function RandomMT.NextNumber(self, min: number?, max: number?)
	local u = (nextRaw(self) - 1) / 2147483646
	local lo, hi = min or 0, max or 1
	return lo + (hi - lo) * u
end

function RandomMT.NextInteger(self, min: number, max: number)
	return min + math.floor(self:NextNumber() * (max - min + 1) - 1e-12)
end

function RandomMT.Clone(self)
	return setmetatable({ _state = self._state }, RandomMT)
end

function R.newRandom(seed: number?)
	local s = math.floor(math.abs(seed or 1)) % 2147483646 + 1
	local r = setmetatable({ _state = s }, RandomMT)
	nextRaw(r)
	return r
end

--------------------------------------------------------------------------------
-- Instances
--------------------------------------------------------------------------------

local Instance = {} -- shared methods
local InstanceMT = { __robloxtype = "Instance" }

local IS_A = {
	Instance = true,
	ServiceProvider = { DataModel = true },
	LuaSourceContainer = { ModuleScript = true, Script = true },
	BaseScript = { Script = true },
}

function InstanceMT.__index(self, key)
	local method = Instance[key]
	if method ~= nil then
		return method
	end
	if key == "Parent" then
		return rawget(self, "_parent")
	end
	local props = rawget(self, "_props")
	if props and props[key] ~= nil then
		return props[key]
	end
	local child = Instance.FindFirstChild(self, key)
	if child ~= nil then
		return child
	end
	error(`{key} is not a valid member of {rawget(self, "ClassName")} "{Instance.GetFullName(self)}"`, 2)
end

function InstanceMT.__newindex(self, key, value)
	if key == "Parent" then
		if value == self then
			error("Attempt to set parent of an instance to itself", 2)
		end
		local old = rawget(self, "_parent")
		if old == value then
			return
		end
		if old then
			local list = rawget(old, "_children")
			local i = table.find(list, self)
			if i then
				table.remove(list, i)
			end
		end
		rawset(self, "_parent", value)
		if value then
			table.insert(rawget(value, "_children"), self)
			local waiters = rawget(value, "_childWaiters")
			if waiters then
				waiters(self)
			end
		end
		return
	end
	local props = rawget(self, "_props")
	if props == nil then
		props = {}
		rawset(self, "_props", props)
	end
	props[key] = value
end

function InstanceMT.__tostring(self)
	return rawget(self, "Name")
end

function R.newInstance(className: string, name: string?, fields: { [string]: any }?)
	local inst = setmetatable({ Name = name or className, ClassName = className, _children = {} }, InstanceMT)
	if fields then
		for k, v in fields do
			rawset(inst, k, v)
		end
	end
	return inst
end

function R.isInstance(v): boolean
	return type(v) == "table" and getmetatable(v) == InstanceMT
end

function Instance.GetChildren(self)
	return table.clone(rawget(self, "_children"))
end

function Instance.FindFirstChild(self, name: string, recursive: boolean?)
	for _, child in rawget(self, "_children") do
		if rawget(child, "Name") == name then
			return child
		end
	end
	if recursive then
		for _, child in rawget(self, "_children") do
			local found = Instance.FindFirstChild(child, name, true)
			if found then
				return found
			end
		end
	end
	return nil
end

function Instance.FindFirstChildOfClass(self, className: string)
	for _, child in rawget(self, "_children") do
		if rawget(child, "ClassName") == className then
			return child
		end
	end
	return nil
end

function Instance.FindFirstChildWhichIsA(self, className: string)
	for _, child in rawget(self, "_children") do
		if Instance.IsA(child, className) then
			return child
		end
	end
	return nil
end

-- WaitForChild polls through the owning server's task.wait (set by sim).
function Instance.WaitForChild(self, name: string, timeout: number?)
	local child = Instance.FindFirstChild(self, name)
	if child then
		return child
	end
	local wait = rawget(self, "_wait") or (rawget(self, "_server") and rawget(self, "_server").task.wait)
	if wait == nil then
		error(`WaitForChild({name}): no scheduler attached to {Instance.GetFullName(self)}`, 2)
	end
	local waited = 0
	while true do
		waited += wait()
		child = Instance.FindFirstChild(self, name)
		if child then
			return child
		end
		if timeout and waited >= timeout then
			return nil
		end
	end
end

function Instance.GetDescendants(self)
	local out = {}
	local function walk(inst)
		for _, child in rawget(inst, "_children") do
			table.insert(out, child)
			walk(child)
		end
	end
	walk(self)
	return out
end

function Instance.IsA(self, className: string): boolean
	local own = rawget(self, "ClassName")
	if own == className or className == "Instance" then
		return true
	end
	local set = IS_A[className]
	return type(set) == "table" and set[own] == true
end

function Instance.IsDescendantOf(self, ancestor): boolean
	local p = rawget(self, "_parent")
	while p do
		if p == ancestor then
			return true
		end
		p = rawget(p, "_parent")
	end
	return false
end

function Instance.GetFullName(self): string
	local names = {}
	local inst = self
	while inst and rawget(inst, "ClassName") ~= "DataModel" do
		table.insert(names, 1, rawget(inst, "Name"))
		inst = rawget(inst, "_parent")
	end
	return table.concat(names, ".")
end

function Instance.Destroy(self)
	InstanceMT.__newindex(self, "Parent", nil)
	rawset(self, "_destroyed", true)
end

function Instance.ClearAllChildren(self)
	for _, child in Instance.GetChildren(self) do
		Instance.Destroy(child)
	end
end

function Instance.Clone(self)
	error("Instance:Clone is not supported by the mock", 2)
end

function Instance.GetAttribute(self, name: string)
	local attrs = rawget(self, "_attributes")
	return attrs and attrs[name]
end

function Instance.SetAttribute(self, name: string, value: any)
	local attrs = rawget(self, "_attributes")
	if attrs == nil then
		attrs = {}
		rawset(self, "_attributes", attrs)
	end
	attrs[name] = value
end

function Instance.GetAttributes(self)
	return table.clone(rawget(self, "_attributes") or {})
end

R.InstanceMethods = Instance
R.InstanceMT = InstanceMT

return R
