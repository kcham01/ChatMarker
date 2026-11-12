local ADDON, ns = ...

local BOOK_ICON = "Interface\\Icons\\INV_Misc_Book_09"
local PIN_SIZE = 18
local ARRIVE_YARDS = 10

local db
local books = {}      -- resolved book records
local route = {}      -- array of book records in visiting order
local target          -- book currently set as waypoint
local tomtomUID

local function msg(text)
  DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffBookPins|r: " .. text)
end

----------------------------------------------------------------------------
-- Zone resolution (works on any client whose zone names are English, and
-- falls back to Classic-era uiMapIDs otherwise)
----------------------------------------------------------------------------
local CONTINENT_NAMES = { ["Kalimdor"] = true, ["Eastern Kingdoms"] = true }

local function resolveZones()
  local wanted, found = {}, {}
  for _, b in ipairs(ns.BOOKS) do wanted[b[3]] = true end

  for name, id in pairs(ns.ZONE_IDS) do
    local info = C_Map.GetMapInfo(id)
    if info and info.name == name then found[name] = id end
  end

  local missing = false
  for name in pairs(wanted) do if not found[name] then missing = true end end
  if missing then
    for id = 1, 3000 do
      local info = C_Map.GetMapInfo(id)
      if info and wanted[info.name] and not found[info.name] and info.mapType == Enum.UIMapType.Zone then
        local parent = info.parentMapID and C_Map.GetMapInfo(info.parentMapID)
        if parent and CONTINENT_NAMES[parent.name] then found[info.name] = id end
      end
    end
    -- last resort (non-English clients): trust the fallback ID if it exists
    for name in pairs(wanted) do
      if not found[name] and ns.ZONE_IDS[name] and C_Map.GetMapInfo(ns.ZONE_IDS[name]) then
        found[name] = ns.ZONE_IDS[name]
      end
    end
  end
  return found
end

local function buildBooks()
  local ids = resolveZones()
  wipe(books)
  for i, e in ipairs(ns.BOOKS) do
    local b = { key = e[1], title = e[1], kind = e[2], zone = e[3], x = e[4], y = e[5], note = e[6], mapID = ids[e[3]] }
    if b.mapID then
      local cont, pos = C_Map.GetWorldPosFromMapPos(b.mapID, CreateVector2D(b.x / 100, b.y / 100))
      if cont and pos then b.cont, b.wx, b.wy = cont, pos:GetXY() end
    else
      msg("could not find zone '" .. e[3] .. "' — " .. e[1] .. " will not be pinned.")
    end
    books[#books + 1] = b
  end
end

local function isDone(b) return db.done[b.key] end

----------------------------------------------------------------------------
-- Route planning: nearest-neighbour seed + 2-opt, the same family of TSP
-- heuristics the "Routes" addon uses, run per continent on world coords.
----------------------------------------------------------------------------
local function dist(a, b)
  if not a or not b then return 0 end -- open path: missing ends cost nothing
  local dx, dy = a.wx - b.wx, a.wy - b.wy
  return math.sqrt(dx * dx + dy * dy)
end

local function pathLength(p)
  local total = 0
  for i = 2, #p do total = total + dist(p[i - 1], p[i]) end
  return total
end

local function nearestNeighbour(start, pts)
  local path, left = { start }, {}
  for _, p in ipairs(pts) do if p ~= start then left[#left + 1] = p end end
  while #left > 0 do
    local cur, bestI, bestD = path[#path], 1, math.huge
    for i, p in ipairs(left) do
      local d = dist(cur, p)
      if d < bestD then bestI, bestD = i, d end
    end
    path[#path + 1] = table.remove(left, bestI)
  end
  return path
end

-- positions before `lo` stay fixed (used to pin the player's start point)
local function twoOpt(p, lo)
  local n, improved = #p, true
  while improved do
    improved = false
    for i = lo, n - 1 do
      for k = i + 1, n do
        local delta = dist(p[i - 1], p[k]) + dist(p[i], p[k + 1]) - dist(p[i - 1], p[i]) - dist(p[k], p[k + 1])
        if delta < -0.01 then
          local a, z = i, k
          while a < z do p[a], p[z] = p[z], p[a]; a, z = a + 1, z - 1 end
          improved = true
        end
      end
    end
  end
  return p
end

local function solve(pts, startPoint)
  if #pts <= 1 then return pts end
  if startPoint then
    local p = twoOpt(nearestNeighbour(startPoint, { startPoint, unpack(pts) }), 2)
    table.remove(p, 1)
    return p
  end
  local best, bestLen
  for _, s in ipairs(pts) do
    local p = twoOpt(nearestNeighbour(s, pts), 1)
    local len = pathLength(p)
    if not bestLen or len < bestLen then best, bestLen = p, len end
  end
  return best
end

local function playerWorldPos()
  local mapID = C_Map.GetBestMapForUnit("player")
  if not mapID then return end
  local pos = C_Map.GetPlayerMapPosition(mapID, "player")
  if not pos then return end
  local cont, w = C_Map.GetWorldPosFromMapPos(mapID, pos)
  if not cont or not w then return end
  local x, y = w:GetXY()
  return { cont = cont, wx = x, wy = y }
end

local function buildRoute()
  local me = playerWorldPos()
  local groups, order = {}, {}
  for _, b in ipairs(books) do
    if b.cont and not isDone(b) then
      if not groups[b.cont] then groups[b.cont] = {}; order[#order + 1] = b.cont end
      table.insert(groups[b.cont], b)
    end
  end
  -- player's continent first
  table.sort(order, function(a, b)
    if me and a == me.cont then return true end
    if me and b == me.cont then return false end
    return a < b
  end)

  wipe(route)
  local total = 0
  for _, cont in ipairs(order) do
    local start = (me and me.cont == cont) and me or nil
    local leg = solve(groups[cont], start)
    total = total + pathLength(leg) + (start and dist(start, leg[1]) or 0)
    for _, b in ipairs(leg) do route[#route + 1] = b end
  end
  for i, b in ipairs(route) do b.stop = i end
  for _, b in ipairs(books) do if isDone(b) then b.stop = nil end end
  return total
end

local function nextStop()
  for _, b in ipairs(route) do if not isDone(b) then return b end end
end

----------------------------------------------------------------------------
-- Waypoints (native supertracked waypoint, plus TomTom if installed)
----------------------------------------------------------------------------
local function setWaypoint(b)
  target = b
  if not b then return end
  local x, y = b.x / 100, b.y / 100
  if C_Map.CanSetUserWaypointOnMap and C_Map.CanSetUserWaypointOnMap(b.mapID) then
    C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(b.mapID, x, y))
    if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
      C_SuperTrack.SetSuperTrackedUserWaypoint(true)
    end
  end
  if TomTom and TomTom.AddWaypoint then
    if tomtomUID and TomTom.RemoveWaypoint then TomTom:RemoveWaypoint(tomtomUID) end
    tomtomUID = TomTom:AddWaypoint(b.mapID, x, y, { title = b.title, persistent = false })
  end
  msg(("next: |cffffd100%s|r — %s %.1f %.1f%s"):format(b.title, b.zone, b.x, b.y, b.note and (" (" .. b.note .. ")") or ""))
end

local function clearWaypoint()
  target = nil
  if C_Map.ClearUserWaypoint then C_Map.ClearUserWaypoint() end
  if tomtomUID and TomTom and TomTom.RemoveWaypoint then TomTom:RemoveWaypoint(tomtomUID) end
  tomtomUID = nil
end

----------------------------------------------------------------------------
-- World map pins + route lines
----------------------------------------------------------------------------
local pins, lines = {}, {}
local lineFrame
local refreshMap

local function remaining()
  local n = 0
  for _, b in ipairs(books) do if b.mapID and not isDone(b) then n = n + 1 end end
  return n
end

local function setDone(b, value)
  db.done[b.key] = value or nil
  if value and target == b then
    local n = nextStop()
    if n then setWaypoint(n) else clearWaypoint(); msg("all books collected!") end
  end
  refreshMap()
end

local function pinOnEnter(self)
  local b = self.book
  GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
  GameTooltip:AddLine(b.title, 1, 0.82, 0)
  GameTooltip:AddLine(("%s%s  %.1f, %.1f"):format(b.kind and (b.kind .. " — ") or "", b.zone, b.x, b.y), 1, 1, 1)
  if b.note then GameTooltip:AddLine(b.note, 0.6, 0.8, 1) end
  if isDone(b) then
    GameTooltip:AddLine("Collected", 0.4, 1, 0.4)
  elseif b.stop then
    GameTooltip:AddLine("Route stop #" .. b.stop, 0.8, 0.8, 0.8)
  end
  GameTooltip:AddLine("Left-click: set waypoint   Right-click: toggle collected", 0.5, 0.5, 0.5)
  GameTooltip:Show()
end

local function pinOnClick(self, button)
  if button == "RightButton" then
    setDone(self.book, not isDone(self.book))
    pinOnEnter(self)
  else
    setWaypoint(self.book)
  end
end

local function getPin(i, canvas)
  local pin = pins[i]
  if not pin then
    pin = CreateFrame("Button", nil, canvas)
    pin:SetSize(PIN_SIZE, PIN_SIZE)
    pin.icon = pin:CreateTexture(nil, "ARTWORK")
    pin.icon:SetAllPoints()
    pin.icon:SetTexture(BOOK_ICON)
    pin.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    pin.label = pin:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    pin.label:SetPoint("BOTTOM", pin, "TOP", 0, 0)
    pin:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    pin:SetScript("OnEnter", pinOnEnter)
    pin:SetScript("OnLeave", GameTooltip_Hide)
    pin:SetScript("OnClick", pinOnClick)
    pins[i] = pin
  end
  return pin
end

-- normalised position of a book on the displayed map, or nil
local function project(b, mapID)
  if not b.mapID then return end
  if b.mapID == mapID then return b.x / 100, b.y / 100 end
  local minX, maxX, minY, maxY = C_Map.GetMapRectOnMap(b.mapID, mapID)
  if not minX or maxX == minX or maxY == minY then return end
  local x, y = minX + (maxX - minX) * b.x / 100, minY + (maxY - minY) * b.y / 100
  if x < 0 or x > 1 or y < 0 or y > 1 then return end
  return x, y
end

function refreshMap()
  if not WorldMapFrame or not WorldMapFrame:IsShown() then return end
  local mapID = WorldMapFrame:GetMapID()
  local canvas = WorldMapFrame:GetCanvas()
  local w, h = canvas:GetSize()
  local scale = WorldMapFrame.GetCanvasScale and WorldMapFrame:GetCanvasScale() or 1
  local inv = 1 / scale
  local base = canvas:GetFrameLevel() + 2000

  for _, p in ipairs(pins) do p:Hide() end
  for _, l in ipairs(lines) do l:Hide() end
  if not mapID or db.hidden then return end

  local pos = {}
  for i, b in ipairs(books) do
    local x, y = project(b, mapID)
    local done = isDone(b)
    if x and (db.showDone or not done) then
      pos[b] = { x, y }
      local pin = getPin(i, canvas)
      pin.book = b
      pin:SetParent(canvas)
      pin:SetFrameLevel(base + 10)
      pin:SetScale(inv)
      pin:ClearAllPoints()
      pin:SetPoint("CENTER", canvas, "TOPLEFT", x * w * scale, -y * h * scale)
      pin.icon:SetDesaturated(done)
      pin:SetAlpha(done and 0.45 or 1)
      pin.label:SetText((not done and b.stop) and tostring(b.stop) or "")
      pin:Show()
    end
  end

  if not db.lines then return end
  if not lineFrame then lineFrame = CreateFrame("Frame", nil, canvas) end
  lineFrame:SetParent(canvas)
  lineFrame:SetAllPoints(canvas)
  lineFrame:SetFrameLevel(base)
  lineFrame:Show()
  local n, prev = 0, nil
  for _, b in ipairs(route) do
    if not isDone(b) then
      if prev and prev.cont == b.cont and pos[prev] and pos[b] then
        n = n + 1
        local line = lines[n]
        if not line then
          line = lineFrame:CreateLine(nil, "ARTWORK")
          line:SetColorTexture(1, 0.82, 0, 0.75)
          lines[n] = line
        end
        line:SetThickness(2.5 * inv)
        line:SetStartPoint("TOPLEFT", lineFrame, pos[prev][1] * w, -pos[prev][2] * h)
        line:SetEndPoint("TOPLEFT", lineFrame, pos[b][1] * w, -pos[b][2] * h)
        line:Show()
      end
      prev = b
    end
  end
end

local hooked = false
local function hookMap()
  if hooked or not WorldMapFrame then return end
  hooked = true
  hooksecurefunc(WorldMapFrame, "OnMapChanged", refreshMap)
  WorldMapFrame:HookScript("OnShow", refreshMap)
  if WorldMapFrame.OnCanvasScaleChanged then hooksecurefunc(WorldMapFrame, "OnCanvasScaleChanged", refreshMap) end
  if WorldMapFrame.OnCanvasSizeChanged then hooksecurefunc(WorldMapFrame, "OnCanvasSizeChanged", refreshMap) end
end

----------------------------------------------------------------------------
-- Arrival detection
----------------------------------------------------------------------------
local arrivedAt
local function checkArrival()
  if not target or not target.cont then return end
  local me = playerWorldPos()
  if not me or me.cont ~= target.cont then return end
  if dist(me, target) <= ARRIVE_YARDS then
    if arrivedAt == target then return end
    arrivedAt = target
    if db.auto then
      msg("reached |cffffd100" .. target.title .. "|r — marked collected (right-click its pin to undo).")
      setDone(target, true)
    else
      msg("you're at |cffffd100" .. target.title .. "|r. /books done when you've got it.")
    end
  end
end

----------------------------------------------------------------------------
-- Slash commands
----------------------------------------------------------------------------
local function printRoute()
  for _, b in ipairs(route) do
    if not isDone(b) then
      print(("  %2d. %s — %s %.1f %.1f"):format(b.stop, b.title, b.zone, b.x, b.y))
    end
  end
end

local function replan(silent)
  local yards = buildRoute()
  if not silent then
    msg(("route planned: %d books left, ~%d yards of straight-line travel."):format(remaining(), math.floor(yards)))
  end
  refreshMap()
  return yards
end

SLASH_BOOKPINS1, SLASH_BOOKPINS2 = "/books", "/bookpins"
SlashCmdList.BOOKPINS = function(input)
  local cmd = strtrim(input or ""):lower()
  if cmd == "next" or cmd == "go" then
    local b = nextStop()
    if b then setWaypoint(b) else msg("nothing left to collect.") end
  elseif cmd == "route" then
    replan(); local b = nextStop(); if b then setWaypoint(b) end
  elseif cmd == "list" then
    msg(remaining() .. " books left in route order:"); printRoute()
  elseif cmd == "done" then
    if target then setDone(target, true) else msg("no active target. Use /books next.") end
  elseif cmd == "auto" then
    db.auto = not db.auto; msg("auto-collect on arrival: " .. (db.auto and "ON" or "OFF"))
  elseif cmd == "lines" then
    db.lines = not db.lines; refreshMap(); msg("route lines: " .. (db.lines and "ON" or "OFF"))
  elseif cmd == "collected" then
    db.showDone = not db.showDone; refreshMap(); msg("show collected pins: " .. (db.showDone and "ON" or "OFF"))
  elseif cmd == "toggle" then
    db.hidden = not db.hidden; refreshMap(); msg("pins " .. (db.hidden and "hidden" or "shown"))
  elseif cmd == "clear" then
    clearWaypoint(); msg("waypoint cleared.")
  elseif cmd == "reset" then
    wipe(db.done); replan(); msg("all books marked uncollected.")
  else
    msg(("%d/%d books left. Commands:"):format(remaining(), #books))
    print("  /books next — waypoint to the next stop on the route")
    print("  /books route — re-plan the shortest route from where you stand")
    print("  /books list — print the route")
    print("  /books done — mark the current target collected")
    print("  /books auto — toggle auto-collect when you reach a book (" .. (db.auto and "on" or "off") .. ")")
    print("  /books lines | collected | toggle — route lines / show collected / hide all pins")
    print("  /books clear | reset — clear waypoint / un-collect everything")
  end
end

----------------------------------------------------------------------------
-- Boot
----------------------------------------------------------------------------
local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
local planned = false
f:SetScript("OnEvent", function(_, event, arg1)
  if event == "ADDON_LOADED" then
    if arg1 == ADDON then
      BookPinsDB = BookPinsDB or {}
      db = BookPinsDB
      db.done = db.done or {}
      if db.auto == nil then db.auto = true end
      if db.lines == nil then db.lines = true end
      if db.showDone == nil then db.showDone = true end
    end
    if WorldMapFrame then hookMap() end
  elseif event == "PLAYER_LOGIN" then
    buildBooks()
    hookMap()
    C_Timer.NewTicker(1, checkArrival)
  elseif event == "PLAYER_ENTERING_WORLD" and not planned then
    planned = true
    C_Timer.After(2, function()
      replan(true)
      msg(("%d books left. /books next to start the route, /books for help."):format(remaining()))
    end)
  end
end)
