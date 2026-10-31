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

local firstId
for id in next, names do firstId = id break end
check("the subtable has rows", firstId ~= nil)

local before = env.pfDB_PACKED["items"].subs["enUS"].blob
check("the blob was released when the table was built", before == nil)

check("the same table comes back on a second ask", items["enUS"] == names)
check("pairs sees the whole subtable", (function()
	local n = 0
	for _ in next, names do n = n + 1 end
	return n > 1000
end)())

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

local names2 = pfDB.Load("zones")
check("Load returns the kind table", type(names2) == "table")
check("Load(kind) marks every subtable built", (function()
	local entry = env.pfDB_PACKED["zones"]
	if not entry then return true end
	for _, sub in next, entry.subs do
		if sub.blob then return false end
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

print(string.format("\n%d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
