--[[
    Headless check for pfQuest settings.lua + options.lua under Lua 5.1.

    Drives the real event handler (ADDON_LOADED then PLAYER_ENTERING_WORLD)
    against mock pfQuest frames, then opens the generated ElvUI panel and pokes
    every control type pfQuest_defconfig produces.

    Run: lua5.1 tests/core_spec.lua
]]

local function scriptDir()
  local src = debug.getinfo(1, "S").source
  src = src:gsub("^@", "")
  return src:match("^(.*)[/\\]") .. "/"
end
local ADDON = scriptDir() .. "../"

local failures, checks = 0, 0
local function check(name, ok, detail)
  checks = checks + 1
  if ok then
    print(string.format("  ok   %s", name))
  else
    failures = failures + 1
    print(string.format("  FAIL %s %s", name, detail and ("-> " .. tostring(detail)) or ""))
  end
end

local frames = {}
local function makeFrame(kind)
  local f = { __kind = kind or "Frame", events = {} }
  function f:SetBackdrop(t) self.backdrop = t end
  -- name it bgColor: pfQuest uses .bg for a texture on the tracker
  function f:SetBackdropColor(r, g, b, a) self.bgColor = { r, g, b, a } end
  function f:SetBackdropBorderColor(r, g, b, a) self.border = { r, g, b, a } end
  function f:GetFrameLevel() return 3 end
  function f:SetFrameLevel() end
  function f:CreateTexture() local t = makeFrame("Texture"); t.SetTexture = function(self, ...) self.tex = { ... } end; t.SetAllPoints = function() end; return t end
  function f:CreateFontString() local t = makeFrame("FontString"); t.SetFont = function(self, p, s, fl) self.font = { p, s, fl } end; t.SetPoint = function() end; return t end
  function f:SetFont(p, s, fl) self.font = { p, s, fl } end
  function f:SetPoint() end
  function f:SetAllPoints() end
  function f:SetWidth() end
  function f:SetHeight() end
  function f:SetAlpha(a) self.alpha = a end
  function f:SetTexture(...) self.tex = { ... } end
  function f:SetVertexColor(...) self.vertex = { ... } end
  function f:GetAlpha() return self.alpha or 1 end
  function f:SetText() end
  function f:SetTextColor() end
  function f:SetNormalTexture() end
  function f:SetHighlightTexture() end
  function f:SetPushedTexture() end
  function f:SetDisabledTexture() end
  function f:GetScript(k) return self["script_" .. k] end
  function f:SetScript(k, fn) self["script_" .. k] = fn end
  function f:HookScript(k, fn) self["hook_" .. k] = fn end
  function f:RegisterEvent(e) self.events[e] = true end
  function f:Show() self.shown = true end
  function f:Hide() self.shown = false end
  function f:GetScale() return 1 end
  function f:GetCenter() return 100, 100 end
  function f:GetFontString() return self.text end
  function f:GetName() return self.name end
  frames[#frames + 1] = f
  return f
end

local function newWorld(withPfQuest)
  local env = {}
  setmetatable(env, { __index = _G })
  env._G = env
  env.STANDARD_TEXT_FONT = "Fonts\\FRIZQT__.TTF"
  env.GetScreenWidth = function() return 1920 end
  env.GetScreenHeight = function() return 1080 end
  env.GetCurrentMapContinent = function() return 1 end
  env.GetCurrentMapZone = function() return 12 end
  env.UnitClass = function() return "Warrior", "WARRIOR" end
  env.RAID_CLASS_COLORS = { WARRIOR = { r = 0.78, g = 0.61, b = 0.43 } }
  env.CreateFrame = function(kind) return makeFrame(kind) end
  env.floor, env.ceil, env.abs = math.floor, math.ceil, math.abs
  env.gsub, env.strfind, env.format = string.gsub, string.find, string.format
  env.IsAddOnLoaded = function(name) return name == "ElvUI_pfQuest" and true or false end
  env.hooksecurefunc = function(a, b, c)
    if type(a) == "table" then
      a["hooked_" .. b] = c
    else
      env["hooked_" .. tostring(a)] = b
    end
  end
  env.GetAddOnMetadata = function() return "0.2.0" end
  env.print = function() end
  env.SlashCmdList = {}
  env.ElvUI = { {
    media = {
      blankTex = "ElvUI\\Media\\Textures\\Blank",
      normFont = "ElvUI\\Fonts\\Expressway.ttf",
      bordercolor = { 1, 1, 1, 0.35 },
      backdropfadecolor = { 0.06, 0.06, 0.06, 0.8 },
    },
    Border = 1,
    Options = { args = {} },
    ToggleOptionsUI = function(_, group) env.__openedOptions = group or true end,
    Libs = { EP = { RegisterPlugin = function(_, name, fn) env.__plugin = { name = name, fn = fn } end } },
  } }

  if withPfQuest then
    local resetCalls = { n = 0 }
    env.__reset = resetCalls

    env.tracker = makeFrame("Frame")
    env.tracker.backdrop = makeFrame("Frame")
    env.tracker.backdrop.bg = makeFrame("Texture")
    env.tracker.backdrop.bg.alpha = 0.2
    env.tracker.buttons = {}
    local row = makeFrame("Button")
    row.text = makeFrame("FontString")
    row.bg = makeFrame("Texture")
    env.tracker.buttons[1] = row
    env.__row = row
    env.tracker.ButtonAdd = function() end

    -- the icon strip along the tracker's top edge
    for _, key in ipairs({ "btnquest", "btndatabase", "btngiver", "btnclose", "btnclean", "btnsearch", "btnsettings" }) do
      local b = makeFrame("Button")
      b.icon = makeFrame("Texture")
      env.tracker[key] = b
    end
    env.tracker.mode = "QUEST_TRACKING"
    env.pfMap = { highlight = nil }

    -- /db browser: a tab holding one pfQuest result row with its own hover script
    local browser = makeFrame("Frame")
    browser.input = makeFrame("EditBox")
    browser.tabs = {}
    local row = makeFrame("Button")
    row.pfResultButton = true
    row.tex = makeFrame("Texture")
    row.script_OnEnter = function() end
    browser.tabs.quests = { buttons = { row }, button = makeFrame("Button") }
    env.pfBrowser = browser
    env.pfBrowserRow = row

    env.pfQuest_config = { ["arrow"] = "1", ["worldmapmenu"] = "1", ["nodesize"] = "10" }

    -- the one dropdown pfQuest owns, with its UIDropDownMenuTemplate children
    local dd = makeFrame("Frame")
    dd.name = "pfQuestMapDropdown"
    env.pfQuestMapDropdown = dd
    for _, part in ipairs({ "Left", "Middle", "Right" }) do
      local tex = makeFrame("Texture")
      tex.alpha = 1
      env["pfQuestMapDropdown" .. part] = tex
    end
    env.pfQuestMapDropdownText = makeFrame("FontString")

    -- first-run wizard, shaped like pfQuest's: title, three cards, a checkbox
    local wizard = makeFrame("Frame")
    wizard.title = makeFrame("FontString")
    for i = 1, 3 do
      local card = makeFrame("Button")
      card.id = i
      card.GetID = function(self) return self.id end
      card.bg = makeFrame("Texture")
      -- pfQuest desaturates the two unselected cards to 0.5 grey
      card.bg.GetVertexColor = function(self) return self.id == 2 and 1 or 0.5 end
      card.caption = makeFrame("FontString")
      wizard[i] = card
    end
    wizard.checkbox = makeFrame("CheckButton")
    wizard.checkbox.caption = makeFrame("FontString")
    wizard.checkbox.checked = makeFrame("Texture")
    wizard.checkbox.GetCheckedTexture = function(self) return self.checked end
    env.pfQuestInit = wizard
    env.pfQuest = {
      ResetAll = function() resetCalls.n = resetCalls.n + 1 end,
      route = { arrow = makeFrame("Frame"), coords = {} },
      mapButton = dd,
    }
    env.pfQuest.route.arrow:SetScript("OnUpdate", function() end)
    env.__arrow = env.pfQuest.route.arrow

    env.pfQuest_defconfig = {
      { config = "trackingmethod", text = nil, default = 1, type = nil },
      { text = "General", default = nil, type = "header" },
      { text = "Enable World Map Menu", default = "1", type = "checkbox", config = "worldmapmenu" },
      { text = "Node Size", default = "10", type = "text", config = "nodesize" },
      { text = "Reset Everything", default = nil, type = "button", func = function() env.__buttonFired = true end },
      { text = "Experimental", default = nil, type = "header" },
      { text = "Group Sync", default = "0", type = "checkbox", config = "questiegroup" },
    }

    -- pfQuest's own slash handler; ours wraps it
    env.SlashCmdList.PFDB = function(input) env.__originalSlash = input end

    -- r240-shaped TomTom so the navigation hand-off is exercised for real
    env.TomTom = {
      AddZWaypoint = function() return "uid1" end,
      RemoveWaypoint = function() end,
    }
  end

  return env
end

local function run(env, file, ...)
  local chunk, err = loadstring(assert(io.open(ADDON .. file):read("*a")))
  assert(chunk, err)
  setfenv(chunk, env)
  return chunk(...)
end

local function loadAll(env)
  local ns = {}
  -- the fork owns the ElvUI backend now; the plugin binds to it
  run(env, ADDON .. "elvui.lua", "ElvUI_pfQuest")
  -- the fork resolves E.media on its own PLAYER_ENTERING_WORLD; do it here so
  -- the plugin is exercised against the real post-login font
  env.pfq.font = env.ElvUI[1].media.normFont
  run(env, "options.lua", "ElvUI_pfQuest")
  run(env, "settings.lua", "ElvUI_pfQuest")
  return ns
end

local function eventFrame()
  local found
  for _, f in ipairs(frames) do
    if f.events["PLAYER_ENTERING_WORLD"] then found = f end
  end
  return found
end

local function boot(env)
  local ev = eventFrame()
  assert(ev, "settings.lua registered no event frame")
  env.event, env.arg1 = "PLAYER_ENTERING_WORLD", nil
  ev.script_OnEvent()
  return ev
end

-- =====================================================================
print("== boot ==")
local world = newWorld(true)
local ns = loadAll(world)
boot(world)

check("no extra saved table written", world.pfQuest_ui == nil)
do
  local r, g, b = world.pfq.accent()
  check("accent is the fixed mint", math.abs(r - 0.2) < 0.01 and math.abs(g - 1) < 0.01 and math.abs(b - 0.8) < 0.01,
    string.format("%.2f %.2f %.2f", r, g, b))
end
check("ElvUI plugin registered", world.__plugin and world.__plugin.name == "ElvUI_pfQuest")

print("== pfQuest present: options tree ==")
world.__plugin.fn()
local panel = world.ElvUI[1].Options.args.pfQuest
check("group registered under pfQuest", panel ~= nil)
check("panel name is solid mint", panel.name == "|cff33ffccpfQuest|r", panel.name)
check("header is solid mint", panel.args.header.name == "|cff33ffccpfQuest|r")
check("version read from the TOC", panel.args.version.name:find("0.2.0") ~= nil, panel.args.version.name)
check("no appearance group (accent is fixed)", panel.args.appearanceGroup == nil)
check("no navigation group (TomTom removed)", panel.args.navigationGroup == nil)

local general = panel.args.group1
check("first pfQuest header becomes a group", general ~= nil and general.name == "General", general and general.name)
local toggles, inputs, execs = 0, 0, 0
local toggle, input, exec
for _, entry in pairs(general.args) do
  if entry.type == "toggle" then toggles = toggles + 1; toggle = entry end
  if entry.type == "input" then inputs = inputs + 1; input = entry end
  if entry.type == "execute" then execs = execs + 1; exec = entry end
end
check("checkbox became a toggle", toggles == 1)
check("text field became an input", inputs == 1)
check("button became an execute", execs == 1)
check("second header became a second group", panel.args.group2 ~= nil and panel.args.group2.name == "Experimental")

print("== pfQuest present: controls write through ==")
check("toggle reflects saved state", toggle.get() == true)
toggle.set(nil, false)
check("toggle writes the pfQuest string", world.pfQuest_config["worldmapmenu"] == "0")
check("toggle triggers ResetAll", world.__reset.n == 1)
check("input reflects saved state", input.get() == "10")
input.set(nil, "14")
check("input writes a string", world.pfQuest_config["nodesize"] == "14")
check("input triggers ResetAll", world.__reset.n == 2)
exec.func()
check("execute runs the pfQuest func", world.__buttonFired == true)

print("== one settings surface ==")
world.SlashCmdList.PFDB("config")
check("/db config opens the ElvUI panel", world.__openedOptions == "pfQuest", world.__openedOptions)
world.SlashCmdList.PFDB("tracker")
check("other /db commands pass through", world.__originalSlash == "tracker", world.__originalSlash)
world.SlashCmdList.PFRESKIN("")
check("/pfq opens the panel", world.__openedOptions == "pfQuest")

-- the minimap icon's right-click menu was the last door onto the retired config
-- window: it toggled a 1x1 hidden frame, so "Settings" did nothing at all
local menuFile = (arg and arg[0] or ""):match("^(.*)/tests/[^/]+$") or "."
local menuText = io.open(menuFile .. "/menu.lua", "rb")
check("menu.lua is readable", menuText ~= nil)
if menuText then
	local source = menuText:read("*a")
	menuText:close()

	local settingsLine
	for line in source:gmatch("[^\n]+") do
		if line:find('"settings"', 1, true) then settingsLine = line end
	end
	check("the minimap menu has a settings entry", settingsLine ~= nil)
	check("it opens the ElvUI panel", settingsLine and settingsLine:find("pfq.OpenOptions", 1, true) ~= nil,
		settingsLine)
	check("it no longer toggles the retired window",
		settingsLine and settingsLine:find("pfQuestConfig", 1, true) == nil, settingsLine)
end

-- /pfq status must report from the pack manifest, never by reading a table: a
-- status command that materialises the database causes the cost it reports
world.pfDB_PACKED_MANIFEST = {
  version = 2,
  tables = {
    quests = { rows = 13974, subRows = { ["data"] = 4433, ["data-epoch"] = 2718, ["enUS"] = 4433 } },
    units = { rows = 0, subRows = { ["data"] = 12738, ["enUS"] = 10385 } },
    objects = { rows = 0, subRows = { ["data"] = 9873, ["enUS"] = 8944 } },
    items = { rows = 0, subRows = { ["data"] = 23651, ["enUS"] = 17712 } },
  },
}
world.pfDB = world.pfDB or {}
world.pfDB.IsLoaded = function(kind) return kind == "quests" end
world.pfDB.Status = function() return "items 0/2" end
local printed = {}
local realPrint = world.print
world.print = function(line) printed[#printed + 1] = tostring(line) end
world.SlashCmdList.PFRESKIN("status")
world.print = realPrint

check("/pfq status prints a database line", (function()
  for _, line in ipairs(printed) do if line:find("database: quests") then return true end end
  return false
end)())
check("/pfq status says which tables are built", (function()
  for _, line in ipairs(printed) do
    if line:find("database: quests") and line:find("built") then return true end
  end
  return false
end)())
check("/pfq status reports the loader state", (function()
  for _, line in ipairs(printed) do if line:find("packed: items 0/2") then return true end end
  return false
end)())

-- =====================================================================
print(string.format("\n%d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
