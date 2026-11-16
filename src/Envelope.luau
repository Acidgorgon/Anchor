--!nonstrict
--[[
	Anchor / Envelope

	Everything that knows how a profile is laid out inside the DataStore value.
	The envelope is the stock ProfileStore one, field for field:

		{ Data = {...},
		  MetaData = { ProfileCreateTime, SessionLoadCount, ActiveSession, ForceLoadSession,
		               LastUpdate, MetaTags, Anchor = {...ours} },
		  RobloxMetaData = {}, UserIds = {},
		  GlobalUpdates = { lastIndex, { {index, data}, ... } } }

	Two Data formats:
	  * Compat  : Data is the plain table (what stock writes).
	  * Compact : Data = { AnchorBlob = <Codec buffer> } AND the stock load counter is
	              poisoned: MetaData.SessionLoadCount = "Anchor" (non-numeric) with the
	              real count in MetaData.Anchor.LoadCount. Every stock session-start path
	              runs `SessionLoadCount + 1` inside its UpdateAsync transform, which throws
	              on the string, so a stock server can never claim (and later overwrite) a
	              Compact profile.

	INVARIANT: a blob in Data <=> the counter is poisoned. Both are written together
	in the same transform (writeData), so no stored version ever has one without the other.

	Readers accept both formats regardless of the writer mode. ProfileService-era
	GlobalUpdates entries ({id, version, locked, data}) are read the way stock reads
	them: index = entry[1], payload = entry[#entry].
--]]

local Codec = require(script.Parent.Codec)

local Envelope = {}

Envelope.POISON = "Anchor" -- MetaData.SessionLoadCount value of a Compact profile
Envelope.BLOB_KEY = "AnchorBlob"

----- Load counter -----

function Envelope.isPoisoned(meta: any): boolean
	return type(meta) == "table" and meta.SessionLoadCount == Envelope.POISON
end

-- Real session load count of a stored profile (number), whatever the format.
-- Returns stock's raw value for non-poisoned profiles (may be nil on malformed data,
-- exactly what stock would compare against).
function Envelope.getLoadCount(meta: any): any
	if type(meta) ~= "table" then
		return nil
	end
	local count = meta.SessionLoadCount
	if count == Envelope.POISON then
		local anchor = meta.Anchor
		if type(anchor) == "table" and type(anchor.LoadCount) == "number" then
			return anchor.LoadCount
		end
		return nil
	end
	return count
end

-- Session start: the stock `SessionLoadCount + 1`, on whichever counter is real.
-- Errors (aborting the UpdateAsync write) on malformed counters, like stock does.
function Envelope.bumpLoadCount(meta: any)
	if meta.SessionLoadCount == Envelope.POISON then
		local anchor = meta.Anchor
		if type(anchor) ~= "table" or type(anchor.LoadCount) ~= "number" then
			error("[Anchor]: Compact profile has no MetaData.Anchor.LoadCount; refusing to start a session")
		end
		anchor.LoadCount = anchor.LoadCount + 1
	else
		meta.SessionLoadCount = meta.SessionLoadCount + 1
	end
end

local function poison(meta: any): boolean
	if meta.SessionLoadCount == Envelope.POISON then
		return true
	end
	local count = meta.SessionLoadCount
	if type(count) ~= "number" then
		return false -- can't move a counter we don't understand; caller writes Compat
	end
	local anchor = meta.Anchor
	if type(anchor) ~= "table" then
		anchor = {}
		meta.Anchor = anchor
	end
	anchor.LoadCount = count
	meta.SessionLoadCount = Envelope.POISON
	return true
end

-- Compact -> Compat: put the real count back where stock looks for it.
function Envelope.unpoison(meta: any)
	if type(meta) ~= "table" or meta.SessionLoadCount ~= Envelope.POISON then
		return
	end
	local anchor = meta.Anchor
	local count = if type(anchor) == "table" then anchor.LoadCount else nil
	if type(count) ~= "number" then
		-- Corrupt poison (no real count). Leave it poisoned: stock still can't claim it,
		-- and our own readers treat the count as unknown (no ownership -> no write).
		return
	end
	meta.SessionLoadCount = count
	anchor.LoadCount = nil
	if next(anchor) == nil then
		meta.Anchor = nil
	end
end

----- Data -----

function Envelope.isCompactData(data: any): boolean
	if type(data) ~= "table" or type(data[Envelope.BLOB_KEY]) ~= "buffer" then
		return false
	end
	local first = next(data)
	return next(data, first) == nil -- exactly one key
end

-- Reads Data out of a stored envelope.
-- Returns ok, data, blob (the stored blob when Compact), err.
-- A Compact blob that fails to decode is an error: the caller must NOT treat the
-- profile as missing (that would overwrite it).
function Envelope.readData(raw: any): (boolean, any, buffer?, string?)
	local data = raw.Data
	if Envelope.isCompactData(data) then
		local blob = data[Envelope.BLOB_KEY]
		local ok, result = pcall(Codec.decode, blob)
		if ok == false then
			return false, nil, nil, tostring(result)
		end
		if type(result) ~= "table" then
			return false, nil, nil, "Compact blob did not decode to a table"
		end
		return true, result, blob, nil
	end
	return true, data or {}, nil, nil
end

-- Writes Data into latest_data inside the UpdateAsync transform.
-- `compact` true and a (verified) blob -> Compact + poison; otherwise Compat + un-poison.
-- Returns the format actually written ("Compact" | "Compat").
function Envelope.writeData(latest_data: any, data: any, blob: buffer?, compact: boolean): string
	local meta = latest_data.MetaData
	if compact == true and blob ~= nil and type(meta) == "table" and poison(meta) then
		latest_data.Data = { [Envelope.BLOB_KEY] = blob }
		return "Compact"
	end
	latest_data.Data = data
	Envelope.unpoison(meta)
	return "Compat"
end

----- MetaData.Anchor -----

-- The owning session's copy of MetaData.Anchor (minus LoadCount) is authoritative:
-- it was loaded from the stored value at session start, so keys we don't know about
-- survive; keys removed in-session are removed. Never creates an empty Anchor table.
function Envelope.writeAnchorMeta(meta: any, mine: any)
	if type(meta) ~= "table" then
		return
	end
	local stored = meta.Anchor
	if type(stored) ~= "table" then
		if mine == nil or next(mine) == nil then
			return
		end
		stored = {}
	end
	for key in next, stored do
		if key ~= "LoadCount" and (mine == nil or mine[key] == nil) then
			stored[key] = nil
		end
	end
	if mine ~= nil then
		for key, value in next, mine do
			if key ~= "LoadCount" then
				stored[key] = value
			end
		end
	end
	meta.Anchor = if next(stored) ~= nil then stored else nil
end

-- Session-side copy of MetaData.Anchor (without LoadCount). Shallow: the loaded
-- value is already a private copy returned by UpdateAsync.
function Envelope.readAnchorMeta(meta: any): { [string]: any }
	local result = {}
	if type(meta) == "table" and type(meta.Anchor) == "table" then
		for key, value in next, meta.Anchor do
			if key ~= "LoadCount" then
				result[key] = value
			end
		end
	end
	return result
end

----- GlobalUpdates (messages) -----

-- ProfileStore: {index, data}; ProfileService: {index, version, locked, data}
function Envelope.messageIndex(update: any): any
	return update[1]
end

function Envelope.messageData(update: any): any
	return update[#update]
end

----- Blobs -----

@native
function Envelope.blobEqual(a: buffer?, b: buffer?): boolean
	if a == nil or b == nil then
		return false
	end
	if a == b then
		return true
	end
	local n = buffer.len(a)
	if n ~= buffer.len(b) then
		return false
	end
	local i = 0
	while i + 8 <= n do
		if buffer.readu32(a, i) ~= buffer.readu32(b, i) or buffer.readu32(a, i + 4) ~= buffer.readu32(b, i + 4) then
			return false
		end
		i += 8
	end
	while i < n do
		if buffer.readu8(a, i) ~= buffer.readu8(b, i) then
			return false
		end
		i += 1
	end
	return true
end

-- Rough serialized-size estimate for the 4 MB DataStore limit guard.
-- Compact: base64 of the blob. Compat: JSON is larger than the binary blob; we use 2x
-- the blob as a conservative estimate (Studio-only fact: real JSON length may differ).
function Envelope.estimateSize(blob: buffer, compact: boolean): number
	local n = buffer.len(blob)
	if compact then
		return math.ceil(n / 3) * 4 + 64
	end
	return n * 2
end

----- Hard-invalid check -----

--[[
	Only things a DataStore write would certainly reject. Used to decide whether to
	block a save when Codec.validate fails: anything Codec rejects but Roblox would
	accept (mixed tables, sparse arrays, NaN, ...) is saved like stock saves it, so we
	never stop saving data that stock would have saved.
--]]
local function hardWalk(value: any, path: string, seen: { [any]: boolean }, depth: number): (string?, string?)
	local t = type(value)
	if t == "table" then
		if seen[value] then
			return path, "Cannot store a cyclic table in data store"
		end
		if depth > 1000 then
			return path, "Cannot store a table nested this deep in data store"
		end
		seen[value] = true
		for key, child in next, value do
			local kt = type(key)
			if kt ~= "string" and kt ~= "number" then
				return `{path}[<{typeof(key)}>]`, `Cannot store a table key of type {typeof(key)} in data store`
			end
			if kt == "string" and utf8.len(key) == nil then
				return `{path}[?]`, "Cannot store a table key that is not valid UTF-8 in data store"
			end
			local child_path = if kt == "string" then `{path}.{key}` else `{path}[{key}]`
			local bad_path, reason = hardWalk(child, child_path, seen, depth + 1)
			if bad_path ~= nil then
				return bad_path, reason
			end
		end
		seen[value] = nil
		return nil, nil
	elseif t == "string" then
		if utf8.len(value) == nil then
			return path, "Cannot store a string that is not valid UTF-8 in data store"
		end
		return nil, nil
	elseif t == "number" or t == "boolean" or t == "buffer" or t == "nil" then
		return nil, nil
	end
	return path, `Cannot store {typeof(value)} in data store`
end

function Envelope.findHardInvalid(value: any): (string?, string?)
	return hardWalk(value, "Data", {}, 0)
end

return table.freeze(Envelope)
