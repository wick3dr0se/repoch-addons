--[[
Proves the packed database still equals the readable sources, field by field.

Run:  lua5.1 tests/db_pack_spec.lua

This is the test that makes the pipeline safe. The packer encodes nested tables
(coords, drops, quest relations) into compact strings under __name, and the loader
decodes them on first read. If either side drifts, consumers start reading nil
tables and nothing throws, so the only useful check is a full comparison: build the
source table, build the blob, compare every row and every field including decoded
ones.

It also reports the numbers that justify the design: bytes in the TOC, and what
building each table on demand costs.
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

local function readAll(path)
	local f = io.open(path, "rb")
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	return s
end

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
-- source side: everything, built the way the client used to build it
---------------------------------------------------------------------------

local source, sourceBytes = {}, 0
do
	local env = { pfDB = {} }
	local init = assert(loadfile(addonRoot .. "/db/init.lua"))
	setfenv(init, env)
	init()
	for _, rel in ipairs(FILES) do
		local path = addonRoot .. "/" .. rel
		local text = readAll(path)
		if text then
			sourceBytes = sourceBytes + #text
			local chunk = assert(loadfile(path), "cannot compile " .. rel)
			setfenv(chunk, env)
			chunk()
		end
	end
	source = env.pfDB
end

---------------------------------------------------------------------------
-- packed side: same order the client uses from init/data.xml
---------------------------------------------------------------------------

local env = { print = print, string = string, table = table, math = math,
	pairs = pairs, next = next, type = type, tostring = tostring,
	rawget = rawget, rawset = rawset, setmetatable = setmetatable,
	select = select, loadstring = loadstring, pcall = pcall,
	tonumber = tonumber, ipairs = ipairs, error = error, os = os }
function env.CreateFrame()
	local f = { scripts = {} }
	function f:SetScript(e, fn) self.scripts[e] = fn end
	return f
end

local function run(rel)
	local chunk = assert(loadfile(addonRoot .. "/" .. rel))
	setfenv(chunk, env)
	chunk()
end

local packedFiles, packedBytes = {}, 0
do
	local pipe = io.popen('ls "' .. addonRoot .. '/db/packed/"*.lua 2>/dev/null')
	for path in pipe:lines() do packedFiles[#packedFiles + 1] = path end
	pipe:close()
end
table.sort(packedFiles)

run("db/packed/manifest.lua")
for _, path in ipairs(packedFiles) do
	local name = path:match("([^/]+)$")
	if name ~= "decode.lua" and name ~= "loader.lua" and name ~= "manifest.lua" then
		packedBytes = packedBytes + (#readAll(path) or 0)
		run("db/packed/" .. name)
	end
end
run("db/packed/decode.lua")
run("db/packed/loader.lua")

local pfDB = env.pfDB
local manifest = (function()
	local text = readAll(addonRoot .. "/db/packed/manifest.lua")
	local sandbox = {}
	local chunk = assert(loadstring(text, "manifest"))
	setfenv(chunk, sandbox)
	return chunk()
end)()

check("manifest exists and is the current version", type(manifest) == "table" and manifest.version == 2)
check("nothing is built at load", pfDB.IsLoaded("items") == false)
print(string.format("       login carries %.2f MB of packed data (was %.2f MB of source, %.0f%%)",
	packedBytes / 1048576, sourceBytes / 1048576, 100 * packedBytes / sourceBytes))

---------------------------------------------------------------------------
-- deep comparison, decoded fields included
---------------------------------------------------------------------------

local function diff(a, b, path, out)
	path = path or ""
	out = out or {}
	if type(a) ~= type(b) then
		out[#out + 1] = path .. ": " .. type(a) .. " vs " .. type(b)
		return out
	end
	if type(a) ~= "table" then
		if a ~= b then out[#out + 1] = path .. ": " .. tostring(a) .. " vs " .. tostring(b) end
		return out
	end
	for k, v in next, a do
		diff(v, b[k], path .. "[" .. tostring(k) .. "]", out)
		if #out > 4 then return out end
	end
	for k in next, b do
		if a[k] == nil then
			out[#out + 1] = path .. "[" .. tostring(k) .. "]: only in packed"
			if #out > 4 then return out end
		end
	end
	return out
end

local kindNames = {}
for kind in next, manifest.tables do kindNames[#kindNames + 1] = kind end
table.sort(kindNames)

local totalBuild = 0

for _, kind in ipairs(kindNames) do
	local t0 = os.clock()
	local built = pfDB.Load(kind)
	local buildMs = (os.clock() - t0) * 1000
	totalBuild = totalBuild + buildMs

	local problems = diff(source[kind], built, kind)
	check(kind .. ": identical to the sources, decoded", #problems == 0, problems[1] or "match")

	local man = manifest.tables[kind]
	if man then
		local actual = 0
		for _, sub in next, built do
			if type(sub) == "table" then
				for _ in next, sub do actual = actual + 1 end
			end
		end
		check(kind .. ": manifest row count matches", man.rows == actual,
			man.rows .. " vs " .. tostring(actual))
	end

	print(string.format("       %-16s built in %5.1f ms", kind, buildMs))
end

-- nothing packed may survive the comparison: every __field was read
local leftover = 0
for kind in next, pfDB do
	-- pfDB also carries Load/Status/IsLoaded; only tables hold subtables
	if type(pfDB[kind]) == "table" and type(kind) == "string" then
	for _, sub in next, pfDB[kind] do
		if type(sub) == "table" then
			for _, row in next, sub do
				if type(row) == "table" then
					for field in next, row do
						if type(field) == "string" and field:sub(1, 2) == "__" then
							leftover = leftover + 1
						end
					end
				end
			end
		end
	end
	end
end
check("no __ fields left behind after a full walk", leftover == 0, leftover)

print("")
print(string.format("building everything on demand: %.1f ms, moved off the login path", totalBuild))
print(string.format("%d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
