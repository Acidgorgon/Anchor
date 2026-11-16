--!optimize 2
-- JSON with Roblox DataStore rules (also used for HttpService:JSONEncode/Decode
-- and MessagingService payloads).
--
--   * arrays: tables whose keys are exactly 1..n -> JSON array; {} -> "[]"
--   * dicts: tables whose keys are all strings -> JSON object
--   * errors (with the path of the offending value):
--       mixed tables (number + string keys), sparse arrays / non 1..n number
--       keys, keys that are not strings or numbers, NaN and +-inf, functions,
--       threads, userdata, vectors, cycles, invalid UTF-8 strings
--   * buffers -> {"m":null,"t":"buffer","base64":"..."} (decoded back to a
--     buffer). Real Roblox may also write {"t":"buffer","zbase64":...} (zstd);
--     the mock never compresses (Studio-only fact, see SPEC section 2).
--   * integers |x| < 2^53 print as integers; other numbers use the shortest
--     %.15g/%.16g/%.17g form that round-trips exactly.
--
-- encode(value) -> string, or error("104: Cannot store ... (at <path>)").
-- decode(text) -> value, or error on malformed input.

local JSON = {}

local BASE64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_ENC = {} -- [0..63] = byte
local B64_DEC = {} -- [byte] = 0..63
for i = 1, 64 do
	local b = string.byte(BASE64_ALPHABET, i)
	B64_ENC[i - 1] = b
	B64_DEC[b] = i - 1
end

function JSON.base64Encode(buf: buffer): string
	local len = buffer.len(buf)
	local outLen = 4 * math.ceil(len / 3)
	local out = buffer.create(outLen)
	local o = 0
	local i = 0
	while i + 3 <= len do
		local n = buffer.readu8(buf, i) * 65536 + buffer.readu8(buf, i + 1) * 256 + buffer.readu8(buf, i + 2)
		buffer.writeu8(out, o, B64_ENC[bit32.extract(n, 18, 6)])
		buffer.writeu8(out, o + 1, B64_ENC[bit32.extract(n, 12, 6)])
		buffer.writeu8(out, o + 2, B64_ENC[bit32.extract(n, 6, 6)])
		buffer.writeu8(out, o + 3, B64_ENC[bit32.extract(n, 0, 6)])
		i += 3
		o += 4
	end
	local rest = len - i
	if rest > 0 then
		local n = buffer.readu8(buf, i) * 65536 + (if rest == 2 then buffer.readu8(buf, i + 1) * 256 else 0)
		buffer.writeu8(out, o, B64_ENC[bit32.extract(n, 18, 6)])
		buffer.writeu8(out, o + 1, B64_ENC[bit32.extract(n, 12, 6)])
		buffer.writeu8(out, o + 2, if rest == 2 then B64_ENC[bit32.extract(n, 6, 6)] else 61)
		buffer.writeu8(out, o + 3, 61) -- '='
	end
	return buffer.tostring(out)
end

function JSON.base64Decode(s: string): buffer
	s = string.gsub(s, "[^%w%+/=]", "")
	local len = #s
	if len % 4 ~= 0 then
		error("invalid base64 length")
	end
	local pad = 0
	if string.sub(s, -2) == "==" then
		pad = 2
	elseif string.sub(s, -1) == "=" then
		pad = 1
	end
	local out = buffer.create(len // 4 * 3 - pad)
	local o = 0
	for i = 1, len, 4 do
		local a, b, c, d = string.byte(s, i, i + 3)
		local n = B64_DEC[a] * 262144 + B64_DEC[b] * 4096 + (B64_DEC[c] or 0) * 64 + (B64_DEC[d] or 0)
		buffer.writeu8(out, o, bit32.extract(n, 16, 8))
		if c ~= 61 then
			buffer.writeu8(out, o + 1, bit32.extract(n, 8, 8))
		end
		if d ~= 61 then
			buffer.writeu8(out, o + 2, bit32.extract(n, 0, 8))
		end
		o += 3
	end
	return out
end

--------------------------------------------------------------------------------
-- Encode
--------------------------------------------------------------------------------

local ESCAPES = {
	['"'] = '\\"',
	["\\"] = "\\\\",
	["\b"] = "\\b",
	["\f"] = "\\f",
	["\n"] = "\\n",
	["\r"] = "\\r",
	["\t"] = "\\t",
}

local function escapeChar(c: string): string
	return ESCAPES[c] or string.format("\\u%04x", string.byte(c))
end

local function pathString(path: { any }, depth: number): string
	local parts = {}
	for i = 1, depth do
		local k = path[i]
		if type(k) == "number" then
			parts[i] = `[{k}]`
		else
			parts[i] = (if i > 1 then "." else "") .. tostring(k)
		end
	end
	local s = table.concat(parts)
	return if s == "" then "<root>" else s
end

local function formatNumber(v: number): string?
	if v ~= v or v == math.huge or v == -math.huge then
		return nil
	end
	if v == math.floor(v) and math.abs(v) < 2 ^ 53 then
		if v == 0 then
			return "0"
		end
		return string.format("%d", v)
	end
	for precision = 15, 17 do
		local s = string.format(`%.{precision}g`, v)
		if tonumber(s) == v then
			return s
		end
	end
	return string.format("%.17g", v)
end

JSON.formatNumber = formatNumber

-- Returns "array", n | "object" | error message
local function classify(t: { [any]: any }): (string, number | string)
	local count = 0
	local numeric = 0
	local maxIndex = 0
	local hasString = false
	for k in t do
		count += 1
		local kt = type(k)
		if kt == "string" then
			hasString = true
		elseif kt == "number" then
			if k ~= math.floor(k) or k < 1 then
				return "error", `non-integer or non-positive number key {k}`
			end
			numeric += 1
			if k > maxIndex then
				maxIndex = k
			end
		else
			return "error", `key of type {typeof(k)}`
		end
	end
	if numeric > 0 and hasString then
		return "error", "mixed table (number and string keys)"
	end
	if numeric > 0 then
		if maxIndex ~= numeric then
			return "error", `sparse array (max index {maxIndex}, {numeric} entries)`
		end
		return "array", numeric
	end
	if count == 0 then
		return "array", 0
	end
	return "object", count
end

local function fail(path, depth, what: string)
	error(`104: Cannot store {what} in data store (at {pathString(path, depth)})`, 0)
end

local encodeValue

local function encodeString(s: string, out: { string }, n: number, path, depth): number
	if utf8.len(s) == nil then
		fail(path, depth, "string with invalid UTF-8")
	end
	if string.find(s, '[%c"\\]') then
		s = string.gsub(s, '[%c"\\]', escapeChar)
	end
	n += 1
	out[n] = '"' .. s .. '"'
	return n
end

function encodeValue(v: any, out: { string }, n: number, path: { any }, depth: number, visiting: { [any]: boolean }): number
	local t = type(v)
	if t == "string" then
		return encodeString(v, out, n, path, depth)
	elseif t == "number" then
		local s = formatNumber(v)
		if s == nil then
			fail(path, depth, `number {v}`)
		end
		n += 1
		out[n] = s :: string
		return n
	elseif t == "boolean" then
		n += 1
		out[n] = if v then "true" else "false"
		return n
	elseif t == "buffer" then
		n += 1
		out[n] = '{"m":null,"t":"buffer","base64":"' .. JSON.base64Encode(v) .. '"}'
		return n
	elseif t == "table" then
		if getmetatable(v) ~= nil and rawget(getmetatable(v) :: any, "__robloxtype") then
			fail(path, depth, (getmetatable(v) :: any).__robloxtype)
		end
		if visiting[v] then
			fail(path, depth, "cyclic table")
		end
		if depth >= 300 then
			fail(path, depth, "table nested deeper than 300 levels")
		end
		local kind, info = classify(v)
		if kind == "error" then
			fail(path, depth, info :: string)
		end
		visiting[v] = true
		if kind == "array" then
			local len = info :: number
			if len == 0 then
				n += 1
				out[n] = "[]"
			else
				n += 1
				out[n] = "["
				for i = 1, len do
					if i > 1 then
						n += 1
						out[n] = ","
					end
					path[depth + 1] = i
					n = encodeValue(v[i], out, n, path, depth + 1, visiting)
				end
				n += 1
				out[n] = "]"
			end
		else
			n += 1
			out[n] = "{"
			local first = true
			for k, item in v do
				if not first then
					n += 1
					out[n] = ","
				end
				first = false
				path[depth + 1] = k
				n = encodeString(k, out, n, path, depth + 1)
				n += 1
				out[n] = ":"
				n = encodeValue(item, out, n, path, depth + 1, visiting)
			end
			n += 1
			out[n] = "}"
		end
		visiting[v] = nil
		path[depth + 1] = nil
		return n
	elseif t == "nil" then
		n += 1
		out[n] = "null"
		return n
	end
	fail(path, depth, typeof(v))
	return n
end

function JSON.encode(value: any): string
	local out = {}
	local n = encodeValue(value, out, 0, {}, 0, {})
	return table.concat(out, "", 1, n)
end

-- validate(value) -> ok, errorMessage?
function JSON.validate(value: any): (boolean, string?)
	local ok, err = pcall(JSON.encode, value)
	return ok, if ok then nil else tostring(err)
end

--------------------------------------------------------------------------------
-- Decode
--------------------------------------------------------------------------------

local function decodeError(s: string, pos: number, what: string)
	error(`JSON decode error at {pos}: {what} near '{string.sub(s, pos, pos + 20)}'`, 0)
end

local decodeAt

local function skipWs(s: string, pos: number): number
	return string.find(s, "[^ \t\r\n]", pos) or (#s + 1)
end

local function decodeStringAt(s: string, pos: number): (string, number)
	-- pos at opening quote
	local i = pos + 1
	local stop = string.find(s, '["\\]', i)
	if stop and string.byte(s, stop) == 34 then
		return string.sub(s, i, stop - 1), stop + 1
	end
	local parts = {}
	while true do
		stop = string.find(s, '["\\]', i)
		if not stop then
			decodeError(s, pos, "unterminated string")
		end
		table.insert(parts, string.sub(s, i, stop - 1))
		if string.byte(s, stop) == 34 then
			return table.concat(parts), stop + 1
		end
		local c = string.sub(s, stop + 1, stop + 1)
		if c == "u" then
			local code = tonumber(string.sub(s, stop + 2, stop + 5), 16)
			if not code then
				decodeError(s, stop, "bad \\u escape")
			end
			i = stop + 6
			if code >= 0xD800 and code <= 0xDBFF and string.sub(s, i, i + 1) == "\\u" then
				local low = tonumber(string.sub(s, i + 2, i + 5), 16)
				if low and low >= 0xDC00 and low <= 0xDFFF then
					code = 0x10000 + (code - 0xD800) * 0x400 + (low - 0xDC00)
					i += 6
				end
			end
			table.insert(parts, utf8.char(code :: number))
		else
			local map = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }
			local ch = map[c]
			if not ch then
				decodeError(s, stop, "bad escape")
			end
			table.insert(parts, ch)
			i = stop + 2
		end
	end
end

function decodeAt(s: string, pos: number): (any, number)
	pos = skipWs(s, pos)
	local c = string.byte(s, pos)
	if c == 123 then -- {
		local out = {}
		pos = skipWs(s, pos + 1)
		if string.byte(s, pos) == 125 then
			return out, pos + 1
		end
		while true do
			pos = skipWs(s, pos)
			if string.byte(s, pos) ~= 34 then
				decodeError(s, pos, "expected string key")
			end
			local k
			k, pos = decodeStringAt(s, pos)
			pos = skipWs(s, pos)
			if string.byte(s, pos) ~= 58 then
				decodeError(s, pos, "expected ':'")
			end
			local v
			v, pos = decodeAt(s, pos + 1)
			out[k] = v
			pos = skipWs(s, pos)
			local sep = string.byte(s, pos)
			if sep == 44 then
				pos += 1
			elseif sep == 125 then
				pos += 1
				break
			else
				decodeError(s, pos, "expected ',' or '}'")
			end
		end
		if out.t == "buffer" and type(out.base64) == "string" then
			return JSON.base64Decode(out.base64), pos
		elseif out.t == "buffer" and out.zbase64 ~= nil then
			error("JSON decode: zbase64 (compressed) buffers are not supported by the mock", 0)
		end
		return out, pos
	elseif c == 91 then -- [
		local out = {}
		local n = 0
		pos = skipWs(s, pos + 1)
		if string.byte(s, pos) == 93 then
			return out, pos + 1
		end
		while true do
			local v
			v, pos = decodeAt(s, pos)
			n += 1
			out[n] = v
			pos = skipWs(s, pos)
			local sep = string.byte(s, pos)
			if sep == 44 then
				pos += 1
			elseif sep == 93 then
				pos += 1
				break
			else
				decodeError(s, pos, "expected ',' or ']'")
			end
		end
		return out, pos
	elseif c == 34 then
		return decodeStringAt(s, pos)
	elseif c == 116 and string.sub(s, pos, pos + 3) == "true" then
		return true, pos + 4
	elseif c == 102 and string.sub(s, pos, pos + 4) == "false" then
		return false, pos + 5
	elseif c == 110 and string.sub(s, pos, pos + 3) == "null" then
		return nil, pos + 4
	end
	local num = string.match(s, "^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
	if num == nil or num == "" then
		decodeError(s, pos, "unexpected character")
	end
	local v = tonumber(num)
	if v == nil then
		decodeError(s, pos, "bad number")
	end
	return v, pos + #(num :: string)
end

function JSON.decode(s: string): any
	if type(s) ~= "string" then
		error("JSON decode: expected a string", 0)
	end
	local v, pos = decodeAt(s, 1)
	pos = skipWs(s, pos)
	if pos <= #s then
		decodeError(s, pos, "trailing characters")
	end
	return v
end

-- Deep copy through a JSON round trip (what Roblox does to stored values).
function JSON.roundTrip(v: any): any
	return JSON.decode(JSON.encode(v))
end

return JSON
