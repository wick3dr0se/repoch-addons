--[[
Loads the addon's real database.lua against the packed database, the way the
client does, and proves it finished.

Run:  lua5.1 tests/db_load_spec.lua

This exists because a lazy alias broke exactly this: database.lua asks for
pfDB["quests"]["loc"], and when the loader had only cached "enUS" under its own
name, that read returned nil, isempty() threw, and the file aborted before it
defined GetQuestIDs. The client then threw "attempt to call method 'GetQuestIDs'"
out of the quest log, which looks nothing like a database bug.

So: load the real file in order, and assert it got to the end.
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

---------------------------------------------------------------------------
-- a client-ish environment
---------------------------------------------------------------------------

local env = {}
for _, name in ipairs({ "print", "string", "table", "math", "pairs", "next", "type",
	"tostring", "tonumber", "ipairs", "error", "select", "rawget", "rawset",
	"setmetatable", "getmetatable", "loadstring", "pcall", "xpcall", "unpack",
	"assert", "collectgarbage", "os" }) do
	env[name] = _G[name]
end

local function makeRegion()
	local region = {}
	function region:SetPoint() end
	function region:SetWidth() end
	function region:SetHeight() end
	function region:SetSize() end
	function region:SetAllPoints() end
	function region:SetParent() end
	function region:Show() end
	function region:Hide() end
	function region:SetText() end
	function region:GetText() return "" end
	function region:SetTexture() end
	function region:SetVertexColor() end
	function region:SetFont() end
	function region:SetJustifyH() end
	function region:SetJustifyV() end
	return region
end

function env.CreateFrame(kind, name)
	local f = makeRegion()
	f.scripts = {}
	f.events = {}
	function f:SetScript(e, fn) self.scripts[e] = fn end
	function f:RegisterEvent(e) self.events[e] = true end
	function f:UnregisterEvent(e) self.events[e] = nil end
	function f:CreateFontString() return makeRegion() end
	function f:CreateTexture() return makeRegion() end
	function f:GetParent() return env.UIParent end
	function f:GetChildren() return {} end
	function f:GetRegions() return {} end
	function f:IsObjectType() return true end
	function f:IsVisible() return false end
	function f:IsShown() return false end
	function f:SetID() end
	function f:GetID() return 0 end
	if name then env[name] = f end
	return f
end

env.UIParent = env.CreateFrame("Frame", "UIParent")

function env.GetLocale() return "enUS" end
function env.GetBuildInfo() return "3.3.5", "12340", "Jan 1 2010", 30300 end
function env.GetTime() return 0 end
function env.GetRealmName() return "Test" end
function env.GetCVar() return "0" end
function env.SetCVar() end
function env.getfenv() return env end
function env.UnitName() return "Tester" end
function env.UnitLevel() return 80 end
function env.UnitClass() return "Paladin", "PALADIN" end
function env.UnitFactionGroup() return "Alliance" end
function env.UnitGUID() return "0x0" end
function env.GetNumQuestLogEntries() return 0 end
function env.GetQuestLogSelection() return 0 end
function env.InCombatLockdown() return false end
function env.IsAddonLoaded() return false end
env.Minimap = env.CreateFrame("Frame", "Minimap")

env.pfQuest_Loc = setmetatable({}, { __index = function(_, k) return k end })
env.pfQuest_config = {}
env.pfQuest = {}
env.pfQuest.locales = {}
env.pfQuest_history = {}

local function run(rel, label)
	local chunk, err = loadfile(addonRoot .. "/" .. rel)
	if not chunk then
		return false, err
	end
	setfenv(chunk, env)
	local ok, problem = xpcall(chunk, function(e) return tostring(e) end)
	return ok, problem or label
end

---------------------------------------------------------------------------
-- the database, in the order init/data.xml loads it
---------------------------------------------------------------------------

local packedFiles = {}
do
	local pipe = io.popen('ls "' .. addonRoot .. '/db/packed/"*.lua 2>/dev/null')
	for path in pipe:lines() do packedFiles[#packedFiles + 1] = path end
	pipe:close()
end
table.sort(packedFiles)

for _, path in ipairs(packedFiles) do
	local name = path:match("([^/]+)$")
	if name ~= "decode.lua" and name ~= "loader.lua" then
		local ok, problem = run("db/packed/" .. name, name)
		if not ok then check(name .. " loads", false, problem) end
	end
end
check("decode loads", (run("db/packed/decode.lua", "decode")))
check("loader loads", (run("db/packed/loader.lua", "loader")))

env.pfDB.locales = { enUS = "enUS" }

---------------------------------------------------------------------------
-- the alias that broke it
---------------------------------------------------------------------------

print("== locale alias ==")

local names = env.pfDB["quests"]["enUS"]
check("reading enUS builds the name table", type(names) == "table")
check("loc is the same table, not nil", env.pfDB["quests"]["loc"] == names,
	tostring(env.pfDB["quests"]["loc"]))

-- and the other way round, on a kind nothing has touched
local fresh = env.pfDB["zones"]
local viaLoc = fresh["loc"]
check("reading loc first also fills enUS", fresh["enUS"] == viaLoc and type(viaLoc) == "table")

---------------------------------------------------------------------------
-- the real database.lua
---------------------------------------------------------------------------

print("== database.lua ==")

-- compat/client.lua pokes more of the frame API than this harness provides, so it
-- may stop partway. What database.lua needs from it is the table itself, and the
-- point of this spec is database.lua, not the shim.
local compatOk, compatErr = run("compat/client.lua", "compat")
if not compatOk then
	print("       note: compat/client.lua stopped early (" .. tostring(compatErr) .. "), expected here")
end
check("pfQuestCompat exists for database.lua", type(env.pfQuestCompat) == "table")

local dbOk, dbErr = run("database.lua", "database.lua")
check("database.lua loads to the end", dbOk, dbErr)

check("it defined GetQuestIDs", env.pfDatabase and type(env.pfDatabase.GetQuestIDs) == "function")
check("it defined GetIDByName", env.pfDatabase and type(env.pfDatabase.GetIDByName) == "function")
check("it built the dbstring", env.pfDatabase and type(env.pfDatabase.dbstring) == "string"
	and #env.pfDatabase.dbstring > 0)

print(string.format("\n%d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
