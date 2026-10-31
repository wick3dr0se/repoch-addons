--[[
Proves data/local/ is applied after upstream, and that removing it restores
upstream.

Run:  lua5.1 tests/db_local_spec.lua

The README says a real correction belongs in data/local/ so a refresh of the
vendored tables cannot undo it. That promise is only worth making if the packer
actually reads those files, so this spec builds a throwaway database, packs it
twice (with and without the local file), materialises the blobs through the real
decoder and loader, and reads the rows back.

The cases are the three things a correction has to be able to do: change a field,
delete a row (a "_" value), and add one. Plus what it must not do: disturb fields
it does not mention.
]]

local addonRoot = (arg and arg[0] or ""):match("^(.*)/tests/[^/]+$") or "."

local checks, failures = 0, 0
local function check(label, cond, detail)
	checks = checks + 1
	if cond then
		print("  ok   " .. label)
	else
		failures = failures + 1
		print(string.format("  FAIL %s%s", label, detail and ("  [" .. tostring(detail) .. "]") or ""))
	end
end

local function writeFile(path, body)
	local f = assert(io.open(path, "wb"), "cannot write " .. path)
	f:write(body)
	f:close()
end

local function readFile(path)
	local f = io.open(path, "rb")
	if not f then return nil end
	local body = f:read("*a")
	f:close()
	return body
end

local root = os.tmpname()
os.execute("rm -rf '" .. root .. "'")
os.execute(("mkdir -p '%s/db/packed' '%s/data/local' '%s/tools'"):format(root, root, root))

---------------------------------------------------------------------------
-- fixtures: a tiny database with the same shape as the real one
---------------------------------------------------------------------------

writeFile(root .. "/db/init.lua", [[
pfDB = {
	["quests"] = {},
	["meta"] = {},
}
]])

writeFile(root .. "/db/quests.lua", [[
pfDB["quests"]["data"] = {
	[1] = { ["title"] = "upstream one", ["level"] = 1, ["coords"] = { 10, 20, 0 } },
	[2] = { ["title"] = "upstream two", ["level"] = 2 },
}
pfDB["quests"]["enUS"] = { [1] = "Upstream One", [2] = "Upstream Two" }
]])

-- an epoch row replaces the base row, which is why this one restates every field
writeFile(root .. "/db/quests-epoch.lua", [[
pfDB["quests"]["data-epoch"] = {
	[1] = { ["title"] = "epoch one", ["level"] = 1, ["coords"] = { 10, 20, 0 }, ["flags"] = 5 },
	[3] = { ["title"] = "epoch three", ["level"] = 3 },
}
pfDB["quests"]["enUS-epoch"] = { [1] = "Epoch One" }
]])

-- ours: change a field, delete a row, add one
local LOCAL = [[
pfDB["quests"]["data-local"] = {
	[1] = { ["title"] = "ours", ["level"] = 60 },
	[2] = "_",
	[4] = { ["title"] = "ours four", ["level"] = 4 },
}
pfDB["quests"]["enUS-local"] = { [1] = "Ours" }
]]

writeFile(root .. "/data/local/quests.lua", LOCAL)

-- the real packer, and the real decoder and loader
writeFile(root .. "/tools/pack_db.lua", assert(readFile(addonRoot .. "/tools/pack_db.lua")))
writeFile(root .. "/db/packed/decode.lua", assert(readFile(addonRoot .. "/db/packed/decode.lua")))
writeFile(root .. "/db/packed/loader.lua", assert(readFile(addonRoot .. "/db/packed/loader.lua")))

local function build()
	os.remove(root .. "/db/packed/quests.lua")
	local ok = os.execute(("cd '%s' && lua5.1 tools/pack_db.lua > pack.log 2>&1"):format(root))
	return ok, readFile(root .. "/pack.log") or ""
end

-- materialise the packed table the way the client does: real decoder, real loader
local function readBack()
	local env = {
		pfDB = {}, pfDB_PACKED = {},
		string = string, table = table, math = math, pairs = pairs, ipairs = ipairs,
		next = next, type = type, tostring = tostring, tonumber = tonumber,
		rawget = rawget, rawset = rawset, setmetatable = setmetatable,
		loadstring = loadstring, select = select, error = error, pcall = pcall, unpack = unpack,
		print = function() end,
		CreateFrame = function()
			return { SetScript = function() end, Show = function() end, Hide = function() end }
		end,
	}
	for _, path in ipairs({ "db/packed/decode.lua", "db/packed/loader.lua", "db/packed/quests.lua" }) do
		local chunk = assert(loadfile(root .. "/" .. path))
		setfenv(chunk, env)
		chunk()
	end
	env.pfDB.LoadSub("quests", "data")
	env.pfDB.LoadSub("quests", "enUS")
	return env.pfDB.quests.data, env.pfDB.quests.enUS
end

---------------------------------------------------------------------------
-- 1. with the local overlay
---------------------------------------------------------------------------

local ok, log = build()
check("the packer runs with a local overlay", ok ~= nil, log:sub(-200))
check("it reports the local file", log:find("local overlay file(s) applied after upstream", 1, true) ~= nil
	and log:find("data/local/quests.lua", 1, true) ~= nil, log:match("[^\n]*local overlay[^\n]*"))

local data, names = readBack()

if type(data) ~= "table" then
	check("the packed table materialises", false, type(data))
else
	check("the packed table materialises", true)
	check("local beats epoch and upstream on the same field",
		data[1] and data[1].title == "ours", data[1] and data[1].title)
	check("fields the overlay does not mention survive it",
		data[1] and data[1].coords ~= nil and data[1].coords[1] == 10 and data[1].flags == 5,
		data[1] and tostring(data[1].coords))
	check("a \"_\" value deletes the row", data[2] == nil, data[2] and data[2].title)
	check("an epoch row the overlay does not touch survives",
		data[3] and data[3].title == "epoch three", data[3] and data[3].title)
	check("the overlay can add a row", data[4] and data[4].title == "ours four", data[4] and data[4].title)
	check("the locale overlay wins too", names and names[1] == "Ours", names and names[1])
end

---------------------------------------------------------------------------
-- 2. the same build without it: upstream is intact, nothing leaked
---------------------------------------------------------------------------

os.remove(root .. "/data/local/quests.lua")
local ok2, log2 = build()
check("the packer runs without a local overlay", ok2 ~= nil, log2:sub(-200))
check("it reports no local files", log2:find("local overlay file(s)", 1, true) == nil)

local plainData, plainNames = readBack()

if type(plainData) ~= "table" then
	check("the plain table materialises", false, type(plainData))
else
	check("the plain table materialises", true)
	check("removing the overlay restores the epoch value",
		plainData[1] and plainData[1].title == "epoch one", plainData[1] and plainData[1].title)
	check("the deleted row comes back", plainData[2] and plainData[2].title == "upstream two",
		plainData[2] and plainData[2].title)
	check("the added row is gone", plainData[4] == nil)
	check("the locale falls back to epoch", plainNames and plainNames[1] == "Epoch One",
		plainNames and plainNames[1])
	check("the epoch row is back in full",
		plainData[1] and plainData[1].level == 1 and plainData[1].coords ~= nil
			and plainData[1].flags == 5,
		plainData[1] and tostring(plainData[1].level))
end

os.execute("rm -rf '" .. root .. "'")

print(string.format("\n%d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
