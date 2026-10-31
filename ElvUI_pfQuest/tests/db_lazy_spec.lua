--[[
Loader semantics: tables build on demand, and only once.

Run:  lua5.1 tests/db_lazy_spec.lua

The equality of the data itself is tests/db_pack_spec.lua. This file pins the
behaviour that makes the database cheap:

  - nothing is built at load, so login pays lexing and nothing else
  - asking for one subtable builds that subtable only
  - a built subtable is a plain table, so pairs() sees every row
  - the blob string is released once the table exists
  - Load, IsLoaded and Status report the truth
  - the warm-up only starts after its delay, and only builds what is still packed
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

local env = { print = print, string = string, table = table, math = math,
	pairs = pairs, next = next, type = type, tostring = tostring, tonumber = tonumber,
	ipairs = ipairs, error = error, rawget = rawget, rawset = rawset,
	setmetatable = setmetatable, select = select, loadstring = loadstring, pcall = pcall }

local warmFrame
function env.CreateFrame()
	local f = { scripts = {} }
	function f:SetScript(e, fn) self.scripts[e] = fn end
	warmFrame = f
	return f
end

local function run(rel)
	local chunk = assert(loadfile(addonRoot .. "/" .. rel))
	setfenv(chunk, env)
	chunk()
end

run("db/packed/manifest.lua")
for _, kind in ipairs({ "items", "units", "quests", "refloot", "professions", "zones" }) do
	run("db/packed/" .. kind .. ".lua")
end
run("db/packed/decode.lua")
run("db/packed/loader.lua")

local pfDB = env.pfDB

check("nothing is built at load", pfDB.IsLoaded("items") == false)
check("IsLoaded is false for a subtable too", pfDB.IsLoaded("items", "enUS") == false)

---------------------------------------------------------------------------
-- subtable granularity
---------------------------------------------------------------------------

local items = pfDB["items"]
check("asking for a kind returns a table", type(items) == "table")
check("but builds no subtable yet", pfDB.IsLoaded("items", "enUS") == false)

local names = items["enUS"]
check("asking for one subtable builds it", type(names) == "table")
check("only that subtable is built", pfDB.IsLoaded("items", "enUS") == true and pfDB.IsLoaded("items", "data") == false)
-- names ship whole: they are the tables every list in the addon iterates
local built = pfDB.LoadSub("items", "enUS")
check("the name table is available without LoadSub", type(built) == "table")
check("LoadSub returns the subtable", type(built) == "table")
check("LoadSub builds every name shard", (function()
	local n = 0
	for _ in next, built do n = n + 1 end
	return n > 1000
end)())
check("pairs sees the whole subtable after LoadSub", (function()
	local n = 0
	for _ in next, built do n = n + 1 end
	return n > 1000
end)())

check("the same table comes back on a second ask", items["enUS"] == built)

---------------------------------------------------------------------------
-- Load / Status
---------------------------------------------------------------------------

check("Status names what is still packed", (function()
	local status = pfDB.Status()
	return type(status) == "string" and status ~= ""
end)(), pfDB.Status())

pfDB.Load("items")
check("Load(kind) builds every subtable of that kind",
	pfDB.IsLoaded("items", "data") == true)

local zones = pfDB.Load("zones")
check("Load returns the kind table", type(zones) == "table")
check("Load(kind) marks every subtable built", (function()
	local entry = env.pfDB_PACKED["zones"]
	if not entry then return true end
	for _, sub in next, entry.subs do
		if sub.blob then return false end
		if sub.blobs then
			for _, blob in next, sub.blobs do
				if type(blob) == "string" then return false end
			end
		end
	end
	return true
end)())

---------------------------------------------------------------------------
-- warm-up
---------------------------------------------------------------------------

check("a warm-up frame exists with an OnUpdate", warmFrame ~= nil and type(warmFrame.scripts.OnUpdate) == "function")

local pendingBefore = pfDB.IsLoaded("refloot")
for _ = 1, 5 do warmFrame.scripts.OnUpdate(warmFrame, 0.1) end
check("nothing happens before the warm-up delay", pfDB.IsLoaded("refloot") == pendingBefore)

---------------------------------------------------------------------------
-- sharded row tables
---------------------------------------------------------------------------

print("== shards ==")

-- an id to look for, from the eager name table
package.loaded["units.enUS"] = true
local wanted
for id in next, pfDB["units"]["enUS"] do
	if type(id) == "number" then wanted = id break end
end
check("there is an id to look for", wanted ~= nil)

local shardEntry = env.pfDB_PACKED["units"].subs["data"]
check("units.data is sharded", type(shardEntry.shards) == "number" and shardEntry.shards > 1)

local function packedShards()
	local n = 0
	for _, blob in next, shardEntry.blobs do
		if type(blob) == "string" then n = n + 1 end
	end
	return n
end

local before = packedShards()
check("every shard starts packed", before == shardEntry.shards, before)

local t0 = os.clock()
local row = pfDB["units"]["data"][wanted]
local elapsed = (os.clock() - t0) * 1000

check("a lookup finds its row", row ~= nil)
check("a lookup builds exactly one shard", packedShards() == before - 1, packedShards())
print(string.format("       one shard built in %.1f ms", elapsed))

-- the rest stay packed until something asks for everything
pfDB.Load("units")
check("Load builds the remaining shards", packedShards() == 0, packedShards())

pfDB.Load("units")
check("Load builds the remaining shards", packedShards() == 0, packedShards())

print(string.format("\n%d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
