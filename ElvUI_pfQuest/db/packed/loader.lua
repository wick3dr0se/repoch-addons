--[[
Build database tables when something asks for them, not at login.

The database ships as blobs (tools/pack_db.lua). A blob is a string constant, so
the client lexes it instead of compiling tens of thousands of lines, and nothing is
built until it is read.

Granularity is the subtable, not the row. Lua 5.1 has no __pairs, so a per-row
proxy would make pairs() iterate only what happened to be loaded, and the browser
would quietly show a partial list. A subtable builds whole, then it is an ordinary
table for everybody.

    pfDB["items"]["enUS"][123]      builds items.enUS
    pfDB.Load("quests")             builds every subtable of quests
    pfDB.Status()                   what is still a blob

A warm-up builds the likely-needed tables during idle time after login so the first
item tooltip does not pay for it in front of the player.
]]

pfDB_PACKED = pfDB_PACKED or {}
pfDB = pfDB or {}

local WARMUP_DELAY = 10
local WARMUP_STEP = 2

-- least urgent first: a tooltip matters more in the first minutes than a
-- profession window, and quests/units/objects are pulled in by the tracker anyway
local WARMUP_ORDER = { "refloot", "professions", "items", "meta-tbc", "minimap-tbc" }

local function decodeInstall(rows)
	if pfDB_DECODE and pfDB_DECODE.install then
		pfDB_DECODE.install(rows)
	end
end

local function loadBlob(blob, kind, sub, packed, label)
	local chunk = loadstring(blob, "pfDB:" .. kind .. "." .. tostring(sub) .. (label or ""))
	if not chunk then
		if DEFAULT_CHAT_FRAME then
			DEFAULT_CHAT_FRAME:AddMessage(string.format(
				"|cff33ffccpfQuest|r: database %s.%s failed to load.", kind, tostring(sub)))
		end
		return nil
	end

	local value = chunk()
	if packed then
		decodeInstall(value)
	end
	return value
end

-- A sharded subtable (units.data, quests.data, ...) builds one slice per lookup.
-- Nobody iterates these whole: the only pairs() over row data in the addon is on
-- a single row. Anything that does want them whole calls pfDB.Load(kind), which
-- builds every shard.
local function shardProxy(kind, sub, subEntry)
	local proxy = {}

	setmetatable(proxy, {
		__index = function(self, key)
			if type(key) ~= "number" then return nil end

			local index = (math.floor(key) % subEntry.shards) + 1
			local blob = subEntry.blobs[index]
			if type(blob) ~= "string" then
				return rawget(self, key)
			end

			local rows = loadBlob(blob, kind, sub, subEntry.packed, "#" .. index)
			subEntry.blobs[index] = nil -- the rows are here now
			if rows then
				for k, v in next, rows do rawset(self, k, v) end
			end

			return rawget(self, key)
		end,
	})

	return proxy
end

local function materialiseSub(kind, sub)
	-- "loc" is database.lua's alias for the Locale subtable, which ships as enUS
	if sub == "loc" then sub = "enUS" end

	local entry = pfDB_PACKED[kind]
	local subEntry = entry and entry.subs and entry.subs[sub]
	if type(subEntry) ~= "table" then
		return nil
	end

	if subEntry.shards then
		local value = shardProxy(kind, sub, subEntry)
		return value
	end

	if type(subEntry.blob) ~= "string" then
		return nil
	end

	local value = loadBlob(subEntry.blob, kind, sub, subEntry.packed)
	if value == nil then
		pfDB_PACKED[kind].subs[sub] = nil
		return nil
	end

	subEntry.blob = nil -- the table is the data now; release the string
	return value
end

local function materialiseKind(kind)
	local existing = rawget(pfDB, kind)
	if existing ~= nil then return existing end

	local entry = pfDB_PACKED[kind]
	if type(entry) ~= "table" then return nil end

	-- a table whose subtables build on first read
	local proxy = setmetatable({}, {
		__index = function(self, sub)
			local value = materialiseSub(kind, sub)
			if value ~= nil then
				rawset(self, sub, value)
			end
			return value
		end,
	})

	rawset(pfDB, kind, proxy)
	return proxy
end

setmetatable(pfDB, {
	__index = function(_, kind)
		if type(kind) == "string" then
			return materialiseKind(kind)
		end
		return nil
	end,
})

function pfDB.Load(kind)
	if kind then
		local proxy = materialiseKind(kind)
		local entry = pfDB_PACKED[kind]
		if proxy and entry and entry.subs then
			for sub, subEntry in next, entry.subs do
				local value = rawget(proxy, sub) or materialiseSub(kind, sub)
				rawset(proxy, sub, value)

				-- sharded subtables: build whatever slices are still packed
				if subEntry.shards and subEntry.blobs then
					for index = 1, subEntry.shards do
						local blob = subEntry.blobs[index]
						if type(blob) == "string" then
							local rows = loadBlob(blob, kind, sub, subEntry.packed, "#" .. index)
							subEntry.blobs[index] = nil
							if rows then
								for k, v in next, rows do rawset(value, k, v) end
							end
						end
					end
				end
			end
		end
		return proxy
	end

	local names = {}
	for name in next, pfDB_PACKED do
		names[#names + 1] = name
	end
	table.sort(names)
	for _, name in ipairs(names) do
		pfDB.Load(name)
	end
	return names
end

-- "quests 2/3 subtables" style reporting for /pfq debug
function pfDB.Status()
	local parts = {}
	for kind, entry in next, pfDB_PACKED do
		if type(entry) == "table" and entry.subs then
			local pending, total = 0, 0
			for _, subEntry in next, entry.subs do
				total = total + 1
				local stillPacked = type(subEntry.blob) == "string"
				if not stillPacked and subEntry.blobs then
					for _, blob in next, subEntry.blobs do
						if type(blob) == "string" then stillPacked = true break end
					end
				end
				if stillPacked then pending = pending + 1 end
			end
			if pending > 0 then
				parts[#parts + 1] = string.format("%s %d/%d", kind, total - pending, total)
			end
		end
	end
	table.sort(parts)
	return #parts > 0 and table.concat(parts, ", ") or "everything built"
end

-- build every shard of one subtable, for the paths that iterate it (search, the
-- browser list). Cheaper than pfDB.Load(kind), which also builds the row tables.
function pfDB.LoadSub(kind, sub)
	-- "loc" is database.lua's alias for the locale subtable, which ships as enUS
	if sub == "loc" then sub = "enUS" end

	local entry = pfDB_PACKED[kind]
	local subEntry = entry and entry.subs and entry.subs[sub]

	local kindTable = rawget(pfDB, kind) or materialiseKind(kind)
	local value = kindTable and (rawget(kindTable, sub) or materialiseSub(kind, sub))
	if value and kindTable then rawset(kindTable, sub, value) end

	if value and subEntry and subEntry.shards and subEntry.blobs then
		for index = 1, subEntry.shards do
			local blob = subEntry.blobs[index]
			if type(blob) == "string" then
				local rows = loadBlob(blob, kind, sub, subEntry.packed, "#" .. index)
				subEntry.blobs[index] = nil
				if rows then
					for k, v in next, rows do rawset(value, k, v) end
				end
			end
		end
	end

	return value
end

function pfDB.IsLoaded(kind, sub)
	local entry = rawget(pfDB, kind)
	if entry == nil then return false end
	if not sub then return true end
	return rawget(entry, sub) ~= nil
end

-- warm-up, one subtable-group per step so a frame never stalls
local warmup = CreateFrame("Frame")
local elapsed, index = 0, 0

warmup:SetScript("OnUpdate", function(self, delta)
	elapsed = elapsed + (delta or 0)
	if elapsed < WARMUP_DELAY then return end

	elapsed = elapsed - WARMUP_STEP
	index = index + 1

	local kind = WARMUP_ORDER[index]
	if not kind then
		self:SetScript("OnUpdate", nil)
		return
	end

	if pfDB_PACKED[kind] and rawget(pfDB, kind) == nil then
		pfDB.Load(kind)
	end
end)
