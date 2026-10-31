--[[
Decode the field-packed values that tools/pack_db.lua writes.

Rows ship with "table" fields stored as tagged strings under a "__name" key, so
the client never pays to build spawn lists, drop tables or quest relations it may
never read. The first time something asks for row.name, this installs the decoded
table, replaces the packed key, and from then on the row looks exactly like the
one in db/*.lua.

Grammar (see the packer for the writer side):
    E{}         empty table
    A1,2,3      list of numbers
    Px,y,z;...  list of number tuples
    S2:ab,3:cde list of strings, length prefixed
    K3:key:1.5  map string -> number
    M12:0.5,... map number -> number
    N3:key:1,2; map string -> list of numbers
    L{...}      fallback: compact Lua source
]]

local decode = {}
pfDB_DECODE = decode

local tonumber, type, next, rawget, rawset, setmetatable = tonumber, type, next, rawget, rawset, setmetatable
local match, gmatch, sub = string.match, string.gmatch, string.sub

local function numbers(payload)
	local out = {}
	local i = 0
	for value in gmatch(payload, "[^,]+") do
		i = i + 1
		out[i] = tonumber(value) or 0
	end
	return out
end

function decode.string(packed)
	local tag = sub(packed, 1, 1)
	local payload = sub(packed, 2)

	if tag == "E" then
		return {}
	end

	if tag == "A" then
		return numbers(payload)
	end

	if tag == "P" then
		local out, i = {}, 0
		for tuple in gmatch(payload, "[^;]+") do
			i = i + 1
			out[i] = numbers(tuple)
		end
		return out
	end

	if tag == "S" or tag == "T" then
		local out, i = {}, 0
		for entry in gmatch(payload, "[^,]+") do
			local len, text = match(entry, "^(%d+):(.*)$")
			if len then
				i = i + 1
				out[i] = text
			end
		end
		return out
	end

	if tag == "M" then
		local out = {}
		for pair in gmatch(payload, "[^,]+") do
			local key, value = match(pair, "^(%-?%d+):(.+)$")
			if key then out[tonumber(key)] = tonumber(value) end
		end
		return out
	end

	if tag == "K" then
		local out = {}
		for entry in gmatch(payload, "[^;]+") do
			local len, rest = match(entry, "^(%d+):(.*)$")
			if len then
				len = tonumber(len)
				local key = sub(rest, 1, len)
				out[key] = tonumber(sub(rest, len + 2)) or 0
			end
		end
		return out
	end

	if tag == "N" then
		local out = {}
		for entry in gmatch(payload, "[^;]+") do
			local len, rest = match(entry, "^(%d+):(.*)$")
			if len then
				len = tonumber(len)
				local key = sub(rest, 1, len)
				local values = sub(rest, len + 2)
				out[key] = numbers(values)
			end
		end
		return out
	end

	if tag == "L" then
		local chunk = loadstring("return " .. payload, "pfDB:pack")
		if chunk then
			local ok, value = pcall(chunk)
			if ok then return value end
		end
		return {}
	end

	return nil
end

-- one metatable for every packed row: decode on first read, then behave like a
-- plain table. Keeping it shared matters: thousands of rows, one allocation.
decode.rowMeta = {
	__index = function(row, key)
		local kt = type(key)
		if kt ~= "string" and kt ~= "number" then return nil end
		local packed = rawget(row, "__" .. tostring(key))
		if type(packed) ~= "string" then return nil end

		local value = decode.string(packed)
		if value == nil then return nil end

		rawset(row, key, value)
		rawset(row, "__" .. key, nil)
		return value
	end,
}

-- rows only need the metatable when the packer actually packed something
function decode.install(rows)
	for _, row in next, rows do
		if type(row) == "table" then
			setmetatable(row, decode.rowMeta)
		end
	end
end
