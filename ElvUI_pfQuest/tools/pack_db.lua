--[[
Pack the pfQuest database: compact blobs, field-packed rows, one blob per table.

Three things happen here, in this order of importance:

1. Bytes. The client pays to lex whatever is in the TOC (~7 ms per MB), so the
   cheapest database is the smallest one. Table-valued fields (spawn coordinates,
   drop tables, quest relations) are encoded into compact tagged strings: no keys,
   no braces, no quotes. That is what takes 20 MB of source down to roughly half.

2. Compile. Everything ships as a string constant rather than Lua source, so login
   lexes instead of compiling. Tables are built when something asks for them.

3. Shape. Encoded fields are stored under "__name" and decoded back to "name" on
   first read, so consumers keep seeing the tables they always saw. The decoder is
   in db/packed/decode.lua; the spec compares decoded rows against the readable
   sources field by field.

    lua5.1 tools/pack_db.lua

Readable db/*.lua stays the source of truth. Never edit db/packed by hand.
]]

local FILES = {
	"db/items.lua", "db/units.lua", "db/objects.lua", "db/refloot.lua",
	"db/quests-itemreq.lua", "db/quests.lua", "db/zones.lua", "db/minimap.lua",
	"db/areatrigger.lua", "db/meta.lua",
	"db/enUS/items.lua", "db/enUS/units.lua", "db/enUS/objects.lua",
	"db/enUS/quests.lua", "db/enUS/zones.lua", "db/enUS/professions.lua",
	"db/items-epoch.lua", "db/units-epoch.lua", "db/objects-epoch.lua",
	"db/refloot-epoch.lua", "db/quests-itemreq-epoch.lua", "db/quests-epoch.lua",
	"db/zones-epoch.lua", "db/minimap-epoch.lua", "db/meta-epoch.lua",
	"db/areatrigger-epoch.lua",
	"db/enUS/items-epoch.lua", "db/enUS/units-epoch.lua", "db/enUS/objects-epoch.lua",
	"db/enUS/quests-epoch.lua", "db/enUS/zones-epoch.lua", "db/enUS/professions-epoch.lua",
}

---------------------------------------------------------------------------
-- scalar serialization (rows keep their scalar fields as real Lua values)
---------------------------------------------------------------------------

local function keyless(a, b)
	local ta, tb = type(a), type(b)
	if ta ~= tb then return ta < tb end
	if ta == "number" or ta == "string" then return a < b end
	return tostring(a) < tostring(b)
end

local function num(v)
	if v == math.floor(v) and math.abs(v) < 1e15 then
		return string.format("%d", v)
	end
	return string.format("%.14g", v)
end

local function toKey(k)
	local tk = type(k)
	if tk == "string" then return "[" .. string.format("%q", k) .. "]" end
	if tk == "number" then return "[" .. num(k) .. "]" end
	if tk == "boolean" then return "[" .. tostring(k) .. "]" end
	error("unsupported key type: " .. tk)
end

local function toValue(v)
	local tv = type(v)
	if tv == "string" then return string.format("%q", v) end
	if tv == "number" then return num(v) end
	if tv == "boolean" then return tostring(v) end
	if tv == "table" then return serialize(v) end
	error("unsupported value type: " .. tv)
end

function serialize(tbl, seen)
	seen = seen or {}
	seen[tbl] = true
	local keys = {}
	for k in next, tbl do keys[#keys + 1] = k end
	table.sort(keys, keyless)
	local out = { "{" }
	for i = 1, #keys do
		out[#out + 1] = toKey(keys[i]) .. "=" .. toValue(tbl[keys[i]]) .. ","
	end
	out[#out + 1] = "}"
	seen[tbl] = nil
	return table.concat(out)
end

---------------------------------------------------------------------------
-- field encoding: tagged, delimiter based, length prefixed for strings
---------------------------------------------------------------------------

local encode

local function denseArray(tbl)
	local n = 0
	for k in next, tbl do
		if type(k) ~= "number" or k < 1 or k ~= math.floor(k) then return nil end
		n = n + 1
	end
	for i = 1, n do
		if tbl[i] == nil then return nil end
	end
	return n
end

encode = function(value)
	local n = denseArray(value)

	if n == 0 and next(value) == nil then
		return "E{}"
	end

	if n and n > 0 then
		local allNum, allStr, allTuple = true, true, true
		for i = 1, n do
			local v = value[i]
			local tv = type(v)
			if tv ~= "number" then allNum = false end
			if tv ~= "string" then allStr = false end
			if tv ~= "table" then
				allTuple = false
			else
				local tn = denseArray(v)
				if not tn then
					allTuple = false
				else
					for j = 1, tn do
						if type(v[j]) ~= "number" then allTuple = false break end
					end
				end
			end
		end

		if allNum then
			local parts = {}
			for i = 1, n do parts[i] = num(value[i]) end
			return "A" .. table.concat(parts, ",")
		end

		if allStr then
			local parts = {}
			for i = 1, n do parts[i] = #value[i] .. ":" .. value[i] end
			return "S" .. table.concat(parts, ",")
		end

		if allTuple then
			local rows = {}
			for i = 1, n do
				local tuple = value[i]
				local tn = denseArray(tuple)
				local parts = {}
				for j = 1, tn do parts[j] = num(tuple[j]) end
				rows[i] = table.concat(parts, ",")
			end
			return "P" .. table.concat(rows, ";")
		end

		return "L" .. serialize(value)
	end

	-- a map: every key is a number with a number value, or every key is a string
	-- with a numeric value. Anything more interesting than that goes through the
	-- fallback, because a decoder that guesses is a decoder that loses data.
	local numKeys, numValues, strKeyNumValue = true, true, true
	for k, v in next, value do
		if type(k) ~= "number" then numKeys = false end
		if type(v) ~= "number" then numValues = false end
		if type(k) ~= "string" or type(v) ~= "number" then strKeyNumValue = false end
	end

	if numKeys and numValues then
		local keys = {}
		for k in next, value do keys[#keys + 1] = k end
		table.sort(keys)
		local parts = {}
		for i = 1, #keys do parts[i] = num(keys[i]) .. ":" .. num(value[keys[i]]) end
		return "M" .. table.concat(parts, ",")
	end

	if strKeyNumValue then
		local entries = {}
		for k, v in next, value do
			entries[#entries + 1] = string.format("%d:%s:%s", #k, k, num(v))
		end
		table.sort(entries)
		return "K" .. table.concat(entries, ";")
	end

	return "L" .. serialize(value)
end

local function longBracket(payload)
	local level = 0
	while payload:find("]" .. string.rep("=", level) .. "]", 1, true) do
		level = level + 1
	end
	return "[" .. string.rep("=", level) .. "[" .. payload .. "]" .. string.rep("=", level) .. "]"
end

local function checksum(s)
	local h = 5381
	for i = 1, #s do
		h = (h * 33 + s:byte(i)) % 4294967296
	end
	return string.format("%08x", h)
end

---------------------------------------------------------------------------
-- build the database exactly as the client does
---------------------------------------------------------------------------

pfDB = {}
assert(loadfile("db/init.lua"))()

local sourceBytes, used = 0, 0
for _, path in ipairs(FILES) do
	local f = io.open(path, "rb")
	if f then
		sourceBytes = sourceBytes + #f:read("*a")
		f:close()
		assert(loadfile(path), "cannot compile " .. path)()
		used = used + 1
	end
end


---------------------------------------------------------------------------
-- bake in the epoch merge
---------------------------------------------------------------------------

-- patchtable.lua used to do this at every login: it merged every "*-epoch"
-- subtable into its base and dropped keys whose overlay value was the string "_".
-- Doing it here means the client materialises one table instead of two and runs
-- no merge pass. The rule is copied from that file, which is why it looks odd.
local function patch(base, diff)
	for k, v in next, diff do
		if type(v) == "string" and v == "_" then
			base[k] = nil
		else
			base[k] = v
		end
	end
end

-- Big row tables are sharded by id: a lookup builds one slice instead of the
-- whole table. Shard count is chosen so a slice stays around 1000-1500 rows,
-- which is a few milliseconds to build. Nobody iterates these tables whole (the
-- only pairs() over row data is on a single row), and pfDB.Load(kind) builds
-- every shard for anything that does want them all.
-- Row tables only. Name tables stay whole on purpose: search, the browser list,
-- the tooltip, nameplates, the map and the quest log all iterate them with pairs(),
-- and a sharded proxy would make every one of those silently see part of a table.
-- That is the failure mode a lazy table must never have.
local SHARDED = {
	items   = { data = 32 },
	units   = { data = 24 },
	objects = { data = 16 },
	quests  = { data = 8 },
}

local MERGED_KINDS = { "items", "quests", "quests-itemreq", "objects", "units",
	"zones", "professions", "areatrigger", "refloot" }
local MERGED_LOCALES = { "enUS", "loc" }

for _, name in ipairs(MERGED_KINDS) do
	local kind = pfDB[name]
	if type(kind) == "table" then
		if kind["data-epoch"] then
			patch(kind["data"] or {}, kind["data-epoch"])
			kind["data-epoch"] = nil
		end
		for _, locale in ipairs(MERGED_LOCALES) do
			local epoch = kind[locale .. "-epoch"]
			if epoch then
				patch(kind[locale] or {}, epoch)
				kind[locale .. "-epoch"] = nil
			end
		end
	end
end

-- these two merge at the level of the table itself, not per row
for _, name in ipairs({ "minimap", "meta" }) do
	local epoch = pfDB[name .. "-epoch"]
	if epoch and pfDB[name] then
		patch(pfDB[name], epoch)
	end
	pfDB[name .. "-epoch"] = nil
end

os.execute("mkdir -p db/packed")

local kinds = {}
for kind in next, pfDB do
	if type(kind) == "string" and type(pfDB[kind]) == "table" then kinds[#kinds + 1] = kind end
end
table.sort(kinds)

local manifestRows, totalBlob, packedFields = {}, 0, 0

for _, kind in ipairs(kinds) do
	local subs = {}
	local subKeys = {}
	for sub in next, pfDB[kind] do subKeys[#subKeys + 1] = sub end
	table.sort(subKeys, function(a, b) return tostring(a) < tostring(b) end)

	local rowsOut, bytesOut = 0, 0
	local subRows = {}

	for _, subKeyRaw in ipairs(subKeys) do
		local subName = tostring(subKeyRaw)
		local sub = pfDB[kind][subKeyRaw]
		local rowCount = 0
		local rowKeys, rowStrings = {}, {}
		local packedAny = false

		if type(sub) == "table" then
			for k in next, sub do rowKeys[#rowKeys + 1] = k end
			table.sort(rowKeys, keyless)
			rowCount = #rowKeys

			for i = 1, #rowKeys do
				local k = rowKeys[i]
				local row = sub[k]
				if type(row) == "table" then
					local copy, any = {}, false
					for field, value in next, row do
						if type(value) == "table" then
							copy["__" .. tostring(field)] = encode(value)
							any = true
						else
							copy[field] = value
						end
					end
					if any then packedAny = true end
					rowStrings[i] = toKey(k) .. "=" .. serialize(copy)
				else
					rowStrings[i] = toKey(k) .. "=" .. toValue(row)
				end
			end
		end

		local subKey = type(subKeyRaw) == "number"
			and ("[" .. subName .. "]") or ('["' .. subName .. '"]')
		local shardCount = SHARDED[kind] and SHARDED[kind][subName]

		if shardCount and rowCount > shardCount then
			local buckets = {}
			for i = 1, shardCount do buckets[i] = {} end
			for i = 1, #rowKeys do
				local k = rowKeys[i]
				local bucket = ((type(k) == "number" and math.floor(k) or i) % shardCount) + 1
				buckets[bucket][#buckets[bucket] + 1] = rowStrings[i]
			end

			local blobs, bytes = {}, 0
			for i = 1, shardCount do
				local body = "return {" .. table.concat(buckets[i], ",") .. "}"
				assert(loadstring(body, "pack"), "shard " .. i .. " of " .. kind .. "." .. subName .. " does not compile")
				bytes = bytes + #body
				blobs[i] = string.format("[%d] = %s", i, longBracket(body))
			end

			subs[#subs + 1] = string.format(
				'\t\t\t%s = { rows = %d, packed = %s, shards = %d, blobs = { %s } },',
				subKey, rowCount, tostring(packedAny), shardCount, table.concat(blobs, ", "))
			bytesOut = bytesOut + bytes
		else
			local blob = "return {" .. table.concat(rowStrings, ",") .. "}"
			assert(loadstring(blob, "pack"), "blob for " .. kind .. "." .. subName .. " does not compile")
			subs[#subs + 1] = string.format(
				'\t\t\t%s = { rows = %d, packed = %s, blob = %s },',
				subKey, rowCount, tostring(packedAny), longBracket(blob))
			bytesOut = bytesOut + #blob
		end

		subRows[#subRows + 1] = string.format('%s = %d', subKey, rowCount)
		rowsOut = rowsOut + rowCount
		if packedAny then packedFields = packedFields + 1 end
	end


	local out = table.concat({
		"--[[",
		"Packed by tools/pack_db.lua. Generated: edit db/*.lua and re-run the packer.",
		"Field-packed values live under __name and are decoded on first read",
		"(db/packed/decode.lua).",
		"]]",
		"pfDB_PACKED = pfDB_PACKED or {}",
		string.format('pfDB_PACKED["%s"] = {', kind),
		"\trows = " .. rowsOut .. ",",
		"\tsubs = {",
		table.concat(subs, "\n"),
		"\t},",
		"}",
	}, "\n") .. "\n"

	local file = "db/packed/" .. kind .. ".lua"
	local f = assert(io.open(file, "wb"))
	f:write(out)
	f:close()

	totalBlob = totalBlob + #out
	manifestRows[#manifestRows + 1] = string.format(
		'	["%s"] = { rows = %d, bytes = %d, checksum = "%s", subRows = { %s } },',
		kind, rowsOut, #out, checksum(out), table.concat(subRows, ", "))

	print(string.format("%-16s %7d rows  %6.2f MB", kind, rowsOut, #out / 1048576))
end

-- The manifest has two consumers: the addon reads pfDB_PACKED_MANIFEST for
-- /pfq status without touching any table, and the specs take the return value.
local manifest = table.concat({
	"--[[",
	"Generated by tools/pack_db.lua. Do not edit.",
	"",
	"Per table: rows, packed size, checksum and per-subtable row counts.",
	"tests/db_pack_spec.lua compares the decoded blobs against the readable",
	"sources; tests/db_provenance_spec.lua checks those sources against their pins.",
	"]]",
	"local M = {",
	"\tversion = 2,",
	"\tsources = {",
	'\t\tbase = "shagu/pfQuest @ 104f356 (2025-08-25)",',
	'\t\tepoch = "Bennylavaa/pfQuest-epoch @ 5c64470 (2026-09-09)",',
	"\t},",
	"\ttables = {",
	table.concat(manifestRows, "\n"),
	"\t},",
	"}",
	"pfDB_PACKED_MANIFEST = M",
	"return M",
}, "\n") .. "\n"

local mf = assert(io.open("db/packed/manifest.lua", "wb"))
mf:write(manifest)
mf:close()

print(string.format("\n%d files, %.2f MB source -> %.2f MB packed (%.0f%% of source)",
	used, sourceBytes / 1048576, totalBlob / 1048576, 100 * totalBlob / sourceBytes))
