--[[
Pull the pinned upstream databases and report what changed.

We do not maintain an Epoch database. pfQuest-epoch is where server content is
tracked, shagu's pfQuest is the frozen WotLK base, and this addon consumes both.
Keeping that true only requires one routine: refresh the pin, see the diff, accept
it, regenerate the packed blobs.

    lua5.1 tools/sync_data.lua             # report only (default)
    lua5.1 tools/sync_data.lua --update    # copy changed and new files into db/
    lua5.1 tools/sync_data.lua --source epoch

Bump the commit in tools/lock_data.lua first, then run --update, then:

    lua5.1 tools/lock_data.lua
    lua5.1 tools/pack_db.lua
    lua5.1 tests/db_provenance_spec.lua
    lua5.1 tests/db_pack_spec.lua

What you get is a row-level diff: which quests, NPCs, objects and items appeared,
disappeared or changed, per file, instead of a blob you have to trust.
]]

local update = false
local onlySource = nil
for _, value in ipairs(arg or {}) do
	if value == "--update" then
		update = true
	elseif value:match("^%-%-source=") then
		onlySource = value:gsub("^%-%-source=", "")
	elseif value == "--check" then
		update = false
	else
		error("unknown argument: " .. value)
	end
end

---------------------------------------------------------------------------
-- helpers
---------------------------------------------------------------------------

local function readAll(path)
	local f = io.open(path, "rb")
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	return s
end

local function writeAll(path, body)
	os.execute('mkdir -p "' .. path:match("^(.*)/[^/]+$") .. '"')
	local f = assert(io.open(path, "wb"))
	f:write(body)
	f:close()
end

local function shell(cmd)
	local pipe = io.popen(cmd)
	local out = {}
	if pipe then
		for line in pipe:lines() do out[#out + 1] = line end
		pipe:close()
	end
	return table.concat(out, "\n")
end

-- load one db file in isolation and hand back its table for that database name
local function loadTable(path, name)
	if not readAll(path) then return nil end
	local env = { pfDB = {} }
	local init = io.open("db/init.lua", "rb")
	if init then
		init:close()
		local chunk = loadfile("db/init.lua")
		if chunk then
			setfenv(chunk, env)
			local ok = pcall(chunk)
			if not ok then return nil end
		end
	end
	local chunk = loadfile(path)
	if not chunk then return nil end
	setfenv(chunk, env)
	local ok = pcall(chunk)
	if not ok then return nil end
	return env.pfDB[name]
end

-- rows keyed by id inside a subtable (data, enUS, ...)
-- nested tables (objectives, spawns) need value comparison, not identity, or
-- every row with a table field reports as edited
local function deepEqual(a, b)
	if a == b then return true end
	if type(a) ~= "table" or type(b) ~= "table" then return false end
	for k, v in next, a do
		if not deepEqual(v, b[k]) then return false end
	end
	for k in next, b do
		if a[k] == nil then return false end
	end
	return true
end

local function rowCount(tbl)
	local n = 0
	if type(tbl) ~= "table" then return 0 end
	for _, sub in next, tbl do
		if type(sub) == "table" then
			for _ in next, sub do n = n + 1 end
		end
	end
	return n
end

-- first subtable that looks like a row map
local function rowsOf(tbl)
	if type(tbl) ~= "table" then return nil end
	local best, bestN = nil, -1
	for _, sub in next, tbl do
		if type(sub) == "table" then
			local n = rowCount({ sub })
			if n > bestN then best, bestN = sub, n end
		end
	end
	return best
end

local function tableFor(path)
	local name = path:match("db/[%w%-]+/([%w%-]+)%.lua$") or path:match("db/([%w%-]+)%.lua$")
	if not name then return nil end
	return (name:gsub("%-epoch$", ""))
end

---------------------------------------------------------------------------
-- lock
---------------------------------------------------------------------------

local function loadLock()
	local text = readAll("data/upstream.lock")
	if not text then error("data/upstream.lock is missing, run tools/lock_data.lua first") end
	local env = {}
	local chunk = assert(loadstring(text, "upstream.lock"))
	setfenv(chunk, env)
	return chunk()
end

local lock = loadLock()

---------------------------------------------------------------------------
-- per-source work
---------------------------------------------------------------------------

local totals = { same = 0, changed = 0, added = 0, removed = 0, rows = 0 }

local function compareSource(key, source)
	print("== " .. key .. " ==")
	print("   " .. source.repo .. " @ " .. source.commit:sub(1, 7) .. " (" .. source.date .. ")")

	local tmp = "/tmp/pfq-sync-" .. key
	shell("rm -rf " .. tmp .. " && mkdir -p " .. tmp)
	local tarball = "/tmp/pfq-sync-" .. key .. ".tar.gz"
	local url = "https://codeload.github.com/"
		.. source.repo:gsub("^https://github.com/", ""):gsub("%.git$", "")
		.. "/tar.gz/" .. source.commit

	local code = shell('curl -sSL -o "' .. tarball .. '" -w "%{http_code}" "' .. url .. '"')
	if code ~= "200" then
		print("   ERROR: download failed (" .. tostring(code) .. ") from " .. url)
		totals.removed = totals.removed -- no-op, keeps counters honest below
		return
	end

	shell('tar -xzf "' .. tarball .. '" -C "' .. tmp .. '" --strip-components=1 2>/dev/null')

	local files = {}
	local pipe = io.popen('find "' .. tmp .. '" -path "*/db/*" -name "*.lua" 2>/dev/null')
	if pipe then
		for path in pipe:lines() do files[#files + 1] = path end
		pipe:close()
	end
	table.sort(files)

	for _, remote in ipairs(files) do
		local prefix = tmp .. "/"
		local rel = remote:sub(1, #prefix) == prefix and remote:sub(#prefix + 1) or remote
		-- we ship enUS only: shagu carries eight other locales, all dead weight here
		local locale = rel:match("^db/(%a%a%a%a)/")
		local wantsLocale = (locale == nil) or (locale == "enUS")

		local wantsThisSource = (key == "epoch") == (rel:match("%-epoch%.lua$") ~= nil)
		if wantsThisSource and wantsLocale and not rel:match("%-tbc%.lua$") then
			local localPath = rel

			-- shagu ships enUS tables and row tables at different depths; both are flat here
			local remoteBody = readAll(remote)
			local localBody = readAll(localPath)

			if not localBody then
				totals.added = totals.added + 1
				print("   new      " .. rel .. "  (" .. math.floor(#remoteBody / 1024) .. " KB)")
				if update then writeAll(localPath, remoteBody) end
			elseif localBody ~= remoteBody then
				totals.changed = totals.changed + 1

				local name = tableFor(rel)
				local before = name and loadTable(localPath, name)
				local after = name and loadTable(remote, name)
				local beforeRows, afterRows = rowsOf(before), rowsOf(after)
				local added, removed, changedRows = 0, 0, 0

				if beforeRows and afterRows then
					for id in next, afterRows do
						local old = beforeRows[id]
						if old == nil then
							added = added + 1
						elseif type(old) ~= "table" or type(afterRows[id]) ~= "table" then
							if old ~= afterRows[id] then changedRows = changedRows + 1 end
						elseif not deepEqual(old, afterRows[id]) then
							changedRows = changedRows + 1
						end
					end
					for id in next, beforeRows do
						if afterRows[id] == nil then removed = removed + 1 end
					end
				end

				print(string.format("   changed  %-34s rows %d -> %d  (+%d new, -%d gone, %d edited)",
					rel, rowCount(before), rowCount(after), added, removed, changedRows))
				if update then writeAll(localPath, remoteBody) end
			else
				totals.same = totals.same + 1
			end
		end
	end
end

for _, key in ipairs({ "base", "epoch" }) do
	if not onlySource or onlySource == key then
		compareSource(key, lock.sources[key])
	end
end

print("")
if update then
	print("updated. now run: tools/lock_data.lua, tools/pack_db.lua, then the two specs")
else
	print(string.format("up to date: %d unchanged, %d changed, %d new. Run with --update to accept.",
		totals.same, totals.changed, totals.added))
end
