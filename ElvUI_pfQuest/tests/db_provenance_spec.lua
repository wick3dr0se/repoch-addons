--[[
Guards the rule that we consume an Epoch database rather than maintain our own.

Run:  lua5.1 tests/db_provenance_spec.lua

Checks, all offline:
  - every vendored db file still matches the checksum recorded in data/upstream.lock
  - no db file exists that the lock does not know about
  - no file disappeared that the lock still lists
  - shagu's TBC variants are not shipped
  - data/local/, if present, only contains files declared as our own overlay

A failure here is not a bug to silence: it means somebody edited a vendored file.
That change belongs in data/local/ (kept as an explicit overlay) so the next
upstream refresh cannot silently undo it, and so the divergence is visible in git.
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

local function checksum(text)
	local h = 5381
	for i = 1, #text do
		h = (h * 33 + text:byte(i)) % 4294967296
	end
	return string.format("%08x", h)
end

local function walk(dir)
	local out = {}
	local pipe = io.popen('find "' .. dir .. '" -name "*.lua" 2>/dev/null')
	if not pipe then return out end
	for path in pipe:lines() do out[#out + 1] = path end
	pipe:close()
	table.sort(out)
	return out
end

local lock = (function()
	local text = readAll(addonRoot .. "/data/upstream.lock")
	if not text then return nil end
	-- the lock is a module: it returns its table
	local env = {}
	local chunk = assert(loadstring(text, "upstream.lock"))
	setfenv(chunk, env)
	return chunk()
end)()

check("data/upstream.lock exists and loads", type(lock) == "table")
check("the lock names its sources", lock and lock.sources and lock.sources.base and lock.sources.epoch)

if type(lock) == "table" and lock.files then
	local known = {}
	for _, entry in ipairs(lock.files) do known["ElvUI_pfQuest/" .. entry.path] = entry end

	local mismatched, missing, extra = {}, {}, {}
	local present = {}

	for _, path in ipairs(walk(addonRoot .. "/db")) do
		if not path:match("/db/packed/") then
			local rel = path:gsub("^" .. addonRoot:gsub("%p", "%%%0") .. "/", "")
			present[rel] = true

			local entry = known["ElvUI_pfQuest/" .. rel] or known[rel]
			if not entry then
				extra[#extra + 1] = rel
			else
				local body = readAll(addonRoot .. "/" .. rel)
				if not body then
					missing[#missing + 1] = rel
				elseif checksum(body) ~= entry.checksum then
					mismatched[#mismatched + 1] = rel
				end
			end
		end
	end

	for key in next, known do
		local rel = key:gsub("^ElvUI_pfQuest/", "")
		if not present[rel] then missing[#missing + 1] = rel end
	end

	check("every vendored db file matches its locked checksum", #mismatched == 0,
		table.concat(mismatched, ", "))
	check("no locked file is missing", #missing == 0, table.concat(missing, ", "))
	check("no unrecorded db file appeared", #extra == 0, table.concat(extra, ", "))

	local tbc = {}
	for _, path in ipairs(walk(addonRoot .. "/db")) do
		-- db/packed carries a table *named* meta-tbc, which is not shagu's TBC data
		if not path:match("/db/packed/") and path:match("%-tbc%.lua$") then
			tbc[#tbc + 1] = path
		end
	end
	check("shagu's TBC variants are not shipped", #tbc == 0, table.concat(tbc, ", "))

	-- our own corrections are allowed, but they must be explicit
	local localFiles = {}
	for _, path in ipairs(walk(addonRoot .. "/data/local")) do
		if path:match("%.lua$") then localFiles[#localFiles + 1] = path end
	end
	if #localFiles > 0 then
		print("  note: " .. #localFiles .. " local overlay file(s) present, applied after upstream")
	else
		check("no local overlay yet (nothing upstream is being overridden)", true)
	end
end

print(string.format("\n%d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
