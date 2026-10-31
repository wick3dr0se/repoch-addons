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

local function materialiseSub(kind, sub)
	local entry = pfDB_PACKED[kind]
	local subEntry = entry and entry.subs and entry.subs[sub]
	if type(subEntry) ~= "table" or type(subEntry.blob) ~= "string" then
		return nil
	end

	local chunk = loadstring(subEntry.blob, "pfDB:" .. kind .. "." .. tostring(sub))
	if not chunk then
		if DEFAULT_CHAT_FRAME then
			DEFAULT_CHAT_FRAME:AddMessage(string.format(
				"|cff33ffccpfQuest|r: database %s.%s failed to load.", kind, tostring(sub)))
		end
		pfDB_PACKED[kind].subs[sub] = nil
		return nil
	end

	local value = chunk()
	if subEntry.packed then
		decodeInstall(value)
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
			for sub in next, entry.subs do
				rawset(proxy, sub, materialiseSub(kind, sub))
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
				if type(subEntry.blob) == "string" then pending = pending + 1 end
			end
			if pending > 0 then
				parts[#parts + 1] = string.format("%s %d/%d", kind, total - pending, total)
			end
		end
	end
	table.sort(parts)
	return #parts > 0 and table.concat(parts, ", ") or "everything built"
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
