--[[
    pfQuest / settings.lua

    The ElvUI settings page for this addon. It used to be a separate addon
    (ElvUI_pfQuest) because pfQuest and its ElvUI layer loaded as different
    addons; now that they are one addon there is nothing to bridge, so this file
    only does the lifecycle:

      /db config        wrapped so it opens the ElvUI page
      /pfq              the same page, plus `status`

    options.lua next door builds the page itself from pfQuest_defconfig.
]]

local addonName = ...

local function version()
  return tostring(GetAddOnMetadata(addonName, "Version") or "8.0.0-elvui.1")
end

-- `/db config` and the /pfquest, /shagu, /pfdb aliases all reach PFDB
local function wrapConfigSlash()
  local list = SlashCmdList
  if pfq.slashWrapped or not list or type(list.PFDB) ~= "function" then return end
  pfq.slashWrapped = true

  local original = list.PFDB
  list.PFDB = function(input)
    if (input or ""):lower():gsub("%s+", "") == "config" then
      pfq.OpenOptions()
      return
    end
    return original(input)
  end
end

local function buildOptions()
  local E = pfq.engine()
  if not E or not E.Libs or not E.Libs.EP then return false end
  if pfq.optionsBuilt then return true end
  pfq.optionsBuilt = true

  -- built when the page opens, never at login: pfQuest-epoch appends its own
  -- entries to pfQuest_defconfig from a delayed handler after
  -- PLAYER_ENTERING_WORLD, so a login-time tree misses every one of them
  E.Libs.EP:RegisterPlugin(addonName, function()
    local args = pfq.BuildOptions(version())
    if args then
      E.Options.args.pfQuest = args
    end
  end)
  return true
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:SetScript("OnEvent", function()
  wrapConfigSlash()

  if not buildOptions() then
    -- ElvUI may still be initialising; retry briefly
    local retry, waited = CreateFrame("Frame"), 0
    retry:SetScript("OnUpdate", function(self, elapsed)
      waited = waited + (elapsed or 0)
      if buildOptions() or waited > 15 then
        self:SetScript("OnUpdate", nil)
      end
    end)
  end
end)

SLASH_PFRESKIN1 = "/pfq"
SlashCmdList["PFRESKIN"] = function(input)
  input = (input or ""):lower():gsub("%s+", "")

  if input == "debug" then
    local browser = pfBrowser
    if not browser or not browser.tabs then
      print("browser not created yet")
      return
    end

    local tab = browser.tabs[browser.active or "quests"]
    print(string.format("tab %s: view %sx%s, window %s, offset %s",
      tostring(browser.active),
      tostring(tab and tab.view and tab.view:GetWidth()), tostring(tab and tab.view and tab.view:GetHeight()),
      tostring(tab and #(tab.data or {})), tostring(tab and tab.offset)))

    local pool = pfDB and pfDB.quests and pfDB.quests.loc
    local poolCount = 0
    if type(pool) == "table" then for _ in pairs(pool) do poolCount = poolCount + 1 end end
    print("pfDB.quests.loc entries: " .. poolCount)

    local ok, err = pcall(function() browser:Search("") end)
    print("Search('') ok=" .. tostring(ok) .. " err=" .. tostring(err))

    local rows, withID, shown = 0, 0, 0
    for i, row in ipairs(tab and tab.buttons or {}) do
      rows = rows + 1
      if row.id then withID = withID + 1 end
      if row:IsShown() then shown = shown + 1 end
      if i <= 3 then
        print(string.format("  row %d id=%s shown=%s text=%s", i, tostring(row.id), tostring(row:IsShown()),
          tostring(row.text and row.text:GetText())))
      end
    end
    print(string.format("rows=%d withID=%d shown=%d readout=%s",
      rows, withID, shown, tostring(browser.count and browser.count:GetText())))
  elseif input == "status" then
    print("|cff33ffccpf|cffffffffQuest|r " .. version() ..
      ", ElvUI " .. (pfq.engine() and "present" or "missing") ..
      ", pfQuest " .. (pfQuest and "loaded" or "missing"))

    -- cheap field diagnostic: the browser showing nothing is usually a data or
    -- geometry question, and this answers both without a screenshot
    local function count(t)
      local n = 0
      if type(t) == "table" then for _ in pairs(t) do n = n + 1 end end
      return n
    end

    -- The database ships packed and builds on demand, so reporting must never
    -- touch a table: reading pfDB.items.data here would materialise it and the
    -- status command would quietly cause the cost it exists to report. Counts come
    -- from the pack manifest, and "built" comes from the loader's own bookkeeping.
    if pfDB then
      local manifest = pfDB_PACKED_MANIFEST

      for _, entry in ipairs({ { "quests", "quests" }, { "units", "units" },
                               { "objects", "objects" }, { "items", "items" } }) do
        local kind = entry[1]
        local man = manifest and manifest.tables and manifest.tables[kind]
        local subRows = man and man.subRows or {}

        local names = (subRows["enUS"] or 0) + (subRows["enUS-epoch"] or 0)
        local rows = (subRows["data"] or 0) + (subRows["data-epoch"] or 0)
        if rows == 0 then rows = subRows["data"] or 0 end

        print(string.format("database: %-8s %6d names %6d rows   %s",
          kind, names, rows,
          pfDB.IsLoaded and pfDB.IsLoaded(kind) and "built" or "packed"))
      end

      if pfDB.Status then
        print("packed: " .. pfDB.Status())
      end
    end

    if pfBrowser and pfBrowser.tabs then
      local tab = pfBrowser.tabs[pfBrowser.active or "quests"]
      local shown = 0
      for _, row in ipairs(tab and tab.buttons or {}) do
        if row.id then shown = shown + 1 end
      end
      print(string.format("browser: %s tab, %d shown, window %s-%s of %d, readout %s",
        tostring(pfBrowser.active), shown,
        tostring((tab and tab.offset or 0) + 1),
        tostring(math.min((tab and tab.offset or 0) + 15, #(tab and tab.data or {}))),
        #(tab and tab.data or {}),
        tostring(pfBrowser.count and pfBrowser.count:GetText())))
    end
  else
    pfq.OpenOptions()
  end
end
