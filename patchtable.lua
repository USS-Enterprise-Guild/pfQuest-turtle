-- Initialize all static variables
local loc = GetLocale()
local dbs = { "items", "quests", "quests-itemreq", "objects", "units", "zones", "professions", "areatrigger", "refloot" }
local noloc = { "items", "quests", "objects", "units" }

-- Count turtle quests before cleanup (for cache invalidation)
local pfQuest_turtle_questcount = 0

-- Patch databases to merge TurtleWoW data
local function patchtable(base, diff)
  for k, v in pairs(diff) do
    if type(v) == "string" and v == "_" then
      base[k] = nil
    else
      base[k] = v
    end
  end
end

-- Detect a typo from old clients and re-apply the typo to the zones table
-- This is a workaround which is required until all clients are updated
for id, name in pairs({GetMapZones(2)}) do
  if name == "Northwind " then
    pfDB["zones"]["enUS-turtle"][5581] = "Northwind "
  end
end

local loc_core, loc_update
for _, db in pairs(dbs) do
  if pfDB[db]["data-turtle"] then
    patchtable(pfDB[db]["data"], pfDB[db]["data-turtle"])
    -- Count quests during merge (before cleanup)
    if db == "quests" then
      for _ in pairs(pfDB[db]["data-turtle"]) do
        pfQuest_turtle_questcount = pfQuest_turtle_questcount + 1
      end
    end
    pfDB[db]["data-turtle"] = nil  -- Cleanup immediately after merge
  end

  for loc, _ in pairs(pfDB.locales) do
    local loc_turtle = loc .. "-turtle"
    if pfDB[db][loc] and pfDB[db][loc_turtle] then
      loc_update = pfDB[db][loc_turtle] or pfDB[db]["enUS-turtle"]
      patchtable(pfDB[db][loc], loc_update)
    end
    pfDB[db][loc_turtle] = nil  -- Cleanup all locale-turtle tables
  end
end

loc_core = pfDB["professions"][loc] or pfDB["professions"]["enUS"]
loc_update = pfDB["professions"][loc.."-turtle"] or pfDB["professions"]["enUS-turtle"]
if loc_update then patchtable(loc_core, loc_update) end
-- Cleanup professions locale tables
for loc, _ in pairs(pfDB.locales) do
  pfDB["professions"][loc.."-turtle"] = nil
end

if pfDB["minimap-turtle"] then
  patchtable(pfDB["minimap"], pfDB["minimap-turtle"])
  pfDB["minimap-turtle"] = nil
end
if pfDB["meta-turtle"] then
  patchtable(pfDB["meta"], pfDB["meta-turtle"])
  pfDB["meta-turtle"] = nil
end

-- Detect german client patch and switch some databases
if TURTLE_DE_PATCH then
  pfDB["zones"]["loc"] = pfDB["zones"]["deDE"] or pfDB["zones"]["enUS"]
  pfDB["professions"]["loc"] = pfDB["professions"]["deDE"] or pfDB["professions"]["enUS"]
end

-- Update bitmasks to include custom races
if pfDB.bitraces then
  pfDB.bitraces[256] = "Goblin"
  pfDB.bitraces[512] = "BloodElf"
end

-- Use turtle-wow database url
pfQuest.dburl = "https://database.turtle-wow.org/?quest="

-- Disable Minimap in custom dungeon maps
function pfMap:HasMinimap(map_id)
  -- disable dungeon minimap
  local has_minimap = not IsInInstance()

  -- enable dungeon minimap if continent is less then 3 (e.g AV)
  if IsInInstance() and GetCurrentMapContinent() < 3 then
    has_minimap = true
  end

  return has_minimap
end

-- Reload all pfQuest internal database shortcuts
pfDatabase:Reload()

-- Trigger garbage collection to reclaim -turtle tables (~41MB)
-- Lua 5.0: collectgarbage(0) forces immediate GC cycle
collectgarbage(0)

-- Reusable table and cached patterns for strsplit to reduce GC pressure
local strsplit_buffer = {}
local strsplit_patterns = {}

local function strsplit(delimiter, subject)
  if not subject then return nil end
  delimiter = delimiter or ":"
  -- Cache pattern to avoid repeated string.format allocations
  local pattern = strsplit_patterns[delimiter]
  if not pattern then
    pattern = "([^" .. delimiter .. "]+)"
    strsplit_patterns[delimiter] = pattern
  end
  -- Clear and reuse buffer
  local n = 0
  string.gsub(subject, pattern, function(c)
    n = n + 1
    strsplit_buffer[n] = c
  end)
  -- Clear any leftover entries from previous calls
  for i = n + 1, table.getn(strsplit_buffer) do
    strsplit_buffer[i] = nil
  end
  return unpack(strsplit_buffer)
end

-- Shared default history entry to avoid allocating {0,0} for every quest
local DEFAULT_HISTORY = { 0, 0 }

-- Complete quest id including all pre quests (iterative to avoid stack overflow)
local complete_queue = {}
local function complete(history, start_qid)
  -- Use iterative approach to avoid deep recursion on long quest chains
  complete_queue[1] = start_qid
  local head = 1
  local tail = 1

  while head <= tail do
    local qid = complete_queue[head]
    head = head + 1

    if qid and tonumber(qid) and not history[qid] then
      -- mark quest as complete - share table for default values
      local existing = pfQuest_history[qid]
      if existing then
        history[qid] = { existing[1] or 0, existing[2] or 0 }
      else
        history[qid] = DEFAULT_HISTORY
      end

      local data = pfDB["quests"]["data"][qid]
      if data then
        -- complete all quests that are closed by the selected one
        if data["close"] then
          for _, id in pairs(data["close"]) do
            tail = tail + 1
            complete_queue[tail] = id
          end
        end
        -- make sure all prequests are marked as done as well
        if data["pre"] then
          for _, id in pairs(data["pre"]) do
            tail = tail + 1
            complete_queue[tail] = id
          end
        end
      end
    end
  end
  -- Clear queue for next use
  for i = 1, tail do complete_queue[i] = nil end
end

-- Temporary workaround for a faction group translation error

-- Add function to query for quest completion
local query = CreateFrame("Frame")
query:Hide()

query:SetScript("OnEvent", function()
  if arg1 == "TWQUEST" then
    -- Avoid temp table by iterating the reused buffer directly
    strsplit(" ", arg2)
    for i = 1, table.getn(strsplit_buffer) do
      complete(this.history, tonumber(strsplit_buffer[i]))
    end
  end
end)

query:SetScript("OnShow", function()
  this.history = {}
  this.time = GetTime()
  this:RegisterEvent("CHAT_MSG_ADDON")
  SendChatMessage(".queststatus", "GUILD")
end)

query:SetScript("OnHide", function()
  this:UnregisterEvent("CHAT_MSG_ADDON")

  local count = 0
  for qid in pairs(this.history) do count = count + 1 end

  DEFAULT_CHAT_FRAME:AddMessage("|cff33ffccpf|cffffffffQuest|r: A total of " .. count .. " quests have been marked as completed.")

  pfQuest_history = this.history
  this.history = nil

  pfQuest:ResetAll()
end)

query:SetScript("OnUpdate", function()
  -- Throttle to check twice per second instead of every frame
  this.elapsed = (this.elapsed or 0) + arg1
  if this.elapsed < 0.5 then return end
  this.elapsed = 0
  if GetTime() > this.time + 3 then this:Hide() end
end)

function pfDatabase:QueryServer()
  DEFAULT_CHAT_FRAME:AddMessage("|cff33ffccpf|cffffffffQuest|r: Receiving quest data from server...")
  query:Show()
end

-- Automatically clear quest cache if new turtle quests have been found
local updatecheck = CreateFrame("Frame")
updatecheck:RegisterEvent("PLAYER_ENTERING_WORLD")
updatecheck:SetScript("OnEvent", function()
  if pfQuest_turtle_questcount > 0 then
    pfQuest:Debug("TurtleWoW loaded with |cff33ffcc" .. pfQuest_turtle_questcount .. "|r quests.")

    -- check if the last count differs to the current amount of quests
    if not pfQuest_turtlecount or pfQuest_turtlecount ~= pfQuest_turtle_questcount then
      -- remove quest cache to force reinitialisation of all quests.
      pfQuest:Debug("New quests found. Reloading |cff33ffccCache|r")
      pfQuest_questcache = {}
    end

    -- write current count to the saved variable
    pfQuest_turtlecount = pfQuest_turtle_questcount
  end
  -- Unregister after first run - no need to check again
  this:UnregisterEvent("PLAYER_ENTERING_WORLD")
end)
