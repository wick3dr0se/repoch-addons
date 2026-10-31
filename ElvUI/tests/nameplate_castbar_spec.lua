--[[
Drives ElvUI's nameplate cast bar through the states that used to throw.

Run from ElvUI/:  lua5.1 tests/nameplate_castbar_spec.lua

The bug: a UNIT_SPELLCAST_CHANNEL_UPDATE or UNIT_SPELLCAST_DELAYED arrived for a
bar that had never seen its start (plates are recycled, and a stop or failed
event resets the bar while the plate stays shown), so `castBar.startTime - start`
did arithmetic on nil and threw out of the nameplate update:

  Elements/CastBar.lua:198: attempt to perform arithmetic on field 'startTime'

The element file caches WoW API calls as upvalues at load (line 10-12), so the
mocks must be installed before the chunk runs; the cases then just swap what the
cached calls return.
]]

local root = (arg and arg[0] or ""):match("^(.*)/tests/[^/]+$") or "."

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

local now = 1000

---------------------------------------------------------------------------
-- mocks, installed before the element file is loaded
---------------------------------------------------------------------------

local castingOf, channellingOf = nil, nil

local function region()
	local r = {}
	function r:SetText() end
	function r:SetTexture() end
	function r:Show() end
	function r:Hide() end
	return r
end

local function makeCastBar()
	local bar = region()
	bar.shown = false
	local iconTexture = region()
	function iconTexture:SetDesaturated() end
	bar.Name, bar.Icon, bar.Spark, bar.Time = region(), { texture = iconTexture }, region(), region()
	function bar:SetStatusBarColor() end
	function bar:IsShown() return self.shown end
	function bar:Show() self.shown = true end
	function bar:Hide() self.shown = false end
	function bar:SetMinMaxValues(min, max) self.min, self.maximum = min, max end
	function bar:SetValue(value) self.value = value end
	return bar
end

local NP
local E = {
	Libs = { LSM = { HashTable = {} } },
	db = {
		units = { ENEMY_NPC = { castbar = { enable = true, timeToHold = 1 } } },
		colors = {
			castColor = { r = 1, g = 1, b = 1 },
			castInterruptedColor = { r = 1, g = 0, b = 0 },
			castNoInterruptColor = { r = 0.5, g = 0.5, b = 0.5 },
			castbarDesaturate = true,
		},
	},
	private = { general = {} },
	media = {},
}
function E:GetModule() return NP end

NP = { db = E.db, StyleFilterUpdate = function() end }

local env = {
	print = print, string = string, table = table, math = math, pairs = pairs,
	next = next, type = type, tostring = tostring, tonumber = tonumber,
	ipairs = ipairs, error = error, select = select, unpack = unpack,
	setmetatable = setmetatable, pcall = pcall, rawget = rawget, rawset = rawset,
	CreateFrame = function() return region() end,
	GetTime = function() return now end,
	-- not `return f and f()`: `and` truncates a call to one value in Lua 5.1,
	-- which silently turned every mock cast into a name with no timings
	UnitCastingInfo = function()
		if castingOf then return castingOf() end
	end,
	UnitChannelInfo = function()
		if channellingOf then return channellingOf() end
	end,
	FAILED = "Failed",
	INTERRUPTED = "Interrupted",
}

-- WoW calls the file as (addonName, ElvUI); it does unpack(select(2, ...))
local chunk = assert(loadfile(root .. "/Modules/Nameplates/Elements/CastBar.lua"))
setfenv(chunk, env)
chunk("ElvUI", { E, {}, {}, {}, {} })

check("the element defines Update_CastBar", type(NP.Update_CastBar) == "function")

---------------------------------------------------------------------------
-- fixtures
---------------------------------------------------------------------------

local function castAt(offset)
	return "Shadow Bolt", "", "", "texture", (now + offset) * 1000, (now + offset + 3) * 1000, false
end

local function channelAt(offset)
	return "Mind Blast", "", "", "texture", (now + offset) * 1000, (now + offset + 3) * 1000, true
end

local function frameFor()
	local frame = { unit = "nameplate1", UnitType = "ENEMY_NPC" }
	frame.IsShown = function() return true end
	frame.Health = { IsShown = function() return true end }
	frame.CastBar = makeCastBar()
	return frame
end

-- Drive one update with the plate visible and whatever the cached API returns.
local function drive(label, event, barState, casting, channelling)
	local frame = frameFor()
	for key, value in pairs(barState or {}) do frame.CastBar[key] = value end
	frame.CastBar:Show() -- the plate is up, which is what let the update reach the maths
	castingOf, channellingOf = casting, channelling

	local ok, problem = pcall(NP.Update_CastBar, NP, frame, event, "nameplate1")
	check(label, ok, problem)
	return frame.CastBar
end

---------------------------------------------------------------------------
-- the cases that used to crash
---------------------------------------------------------------------------

-- 1. channel update on a bar that never saw its start: the reported crash
local bar = drive("channel update with no known start does not throw",
	"UNIT_SPELLCAST_CHANNEL_UPDATE", {}, nil, function() return channelAt(-1) end)
check("it adopts the start time it was handed", type(bar.startTime) == "number", bar.startTime)
check("its delay stays a number", type(bar.delay) == "number", bar.delay)

-- 2. delayed cast, casting flag set, still no start
drive("delayed cast with no known start does not throw", "UNIT_SPELLCAST_DELAYED",
	{ casting = true }, function() return castAt(-1) end, nil)

-- 3. update that finds no cast at all
drive("update with no cast hides cleanly", "UNIT_SPELLCAST_CHANNEL_UPDATE", {}, nil, function() return nil end)

-- 4. start whose timings are missing must not divide nil (defensive guard)
drive("start with missing timings does not throw", "UNIT_SPELLCAST_START", {},
	function() return "Shadow Bolt", "", "", "texture", nil, nil, false end, nil)

---------------------------------------------------------------------------
-- the normal path still works
---------------------------------------------------------------------------

castingOf, channellingOf = function() return castAt(-1) end, nil
local frame = frameFor()
NP.Update_CastBar(NP, frame, "UNIT_SPELLCAST_START", "nameplate1")
check("a normal start shows the bar", frame.CastBar.shown == true)
check("a normal start sets a maximum", type(frame.CastBar.maximum) == "number", frame.CastBar.maximum)

local firstStart = frame.CastBar.startTime
now = now + 1
castingOf = function() return castAt(0) end
NP.Update_CastBar(NP, frame, "UNIT_SPELLCAST_DELAYED", "nameplate1")
check("a delayed event keeps the bar running", frame.CastBar.shown == true)
check("the delayed event refreshes the start time", frame.CastBar.startTime >= firstStart, frame.CastBar.startTime)

print(string.format("\n%d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
