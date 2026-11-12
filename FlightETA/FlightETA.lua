local ADDON = ...

local DEFAULT_SPEED = 32    -- yards/sec, starting guess until real flights are timed
local PATH_FACTOR = 1.25    -- flight paths curve; straight-line distance * this
local PASS_RADIUS = 250     -- yards: how close the taxi must come to count as passing a stop
local TICK = 0.2

local db
local pending   -- route picked at the flight master, waiting for the taxi to start
local flight    -- active flight state

local function msg(text) DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffFlightETA|r: " .. text) end

local function fmt(sec)
  sec = math.max(0, math.floor(sec + 0.5))
  return ("%d:%02d"):format(math.floor(sec / 60), sec % 60)
end

local function dist(a, b)
  if not (a and b and a.wx and b.wx) or a.cont ~= b.cont then return end
  local dx, dy = a.wx - b.wx, a.wy - b.wy
  return math.sqrt(dx * dx + dy * dy)
end

local function playerPos()
  local mapID = C_Map.GetBestMapForUnit("player")
  if not mapID then return end
  local pos = C_Map.GetPlayerMapPosition(mapID, "player")
  if not pos then return end
  local cont, w = C_Map.GetWorldPosFromMapPos(mapID, pos)
  if not cont or not w then return end
  local x, y = w:GetXY()
  return { cont = cont, wx = x, wy = y }
end

----------------------------------------------------------------------------
-- Reading the route off the flight master
----------------------------------------------------------------------------
local function taxiNodePositions()
  local bySlot = {}
  local mapID = GetTaxiMapID and GetTaxiMapID()
  if mapID and C_TaxiMap and C_TaxiMap.GetAllTaxiNodes then
    for _, n in ipairs(C_TaxiMap.GetAllTaxiNodes(mapID) or {}) do
      if n.slotIndex and n.position then
        local cont, w = C_Map.GetWorldPosFromMapPos(mapID, n.position)
        if cont and w then
          local x, y = w:GetXY()
          bySlot[n.slotIndex] = { cont = cont, wx = x, wy = y }
        end
      end
    end
  end
  return bySlot
end

local function buildRoute(destSlot)
  local hops = GetNumRoutes and GetNumRoutes(destSlot) or 0
  if hops < 1 then return end
  local pos = taxiNodePositions()
  local function node(slot)
    local n = { name = TaxiNodeName(slot) or "?" }
    local p = pos[slot]
    if p then n.cont, n.wx, n.wy = p.cont, p.wx, p.wy end
    return n
  end
  local nodes = { [0] = node(TaxiGetNodeSlot(destSlot, 1, false)) }
  for i = 1, hops do nodes[i] = node(TaxiGetNodeSlot(destSlot, i, true)) end
  nodes[hops] = node(destSlot) -- make sure the final stop is exactly what was clicked
  local names = {}
  for i = 0, hops do names[#names + 1] = nodes[i].name end
  return { nodes = nodes, hops = hops, key = table.concat(names, ">") }
end

hooksecurefunc("TakeTaxiNode", function(slot)
  local ok, route = pcall(buildRoute, slot)
  if ok and route then
    route.at = GetTime()
    pending = route
  end
end)

----------------------------------------------------------------------------
-- Estimates and learning
----------------------------------------------------------------------------
local function legKey(r, i) return r.nodes[i - 1].name .. ">" .. r.nodes[i].name end

-- seconds for leg i, and whether it's a timed (learned) value
local function legTime(r, i)
  local t = db.legs[legKey(r, i)]
  if t then return t, true end
  local d = dist(r.nodes[i - 1], r.nodes[i])
  if d then return d * PATH_FACTOR / db.speed, false end
  return 60, false
end

local function learnLeg(r, i, seconds)
  if seconds < 3 then return end
  db.legs[legKey(r, i)] = seconds
  local d = dist(r.nodes[i - 1], r.nodes[i])
  if d and d > 200 then
    local speed = d * PATH_FACTOR / seconds
    if speed > 5 and speed < 200 then db.speed = db.speed * 0.7 + speed * 0.3 end
  end
end

----------------------------------------------------------------------------
-- Display
----------------------------------------------------------------------------
local frame = CreateFrame("Frame", "FlightETAFrame", UIParent, "BackdropTemplate")
frame:SetSize(230, 60)
frame:SetClampedToScreen(true)
frame:SetMovable(true)
frame:EnableMouse(true)
frame:RegisterForDrag("LeftButton")
frame:SetScript("OnDragStart", function(self) if not db.locked then self:StartMoving() end end)
frame:SetScript("OnDragStop", function(self)
  self:StopMovingOrSizing()
  local p, _, rp, x, y = self:GetPoint()
  db.point = { p, rp, x, y }
end)
if frame.SetBackdrop then
  frame:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
  frame:SetBackdropColor(0, 0, 0, 0.6)
  frame:SetBackdropBorderColor(0, 0, 0, 0.9)
end
frame:Hide()

local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
title:SetPoint("TOPLEFT", 8, -7)
title:SetPoint("TOPRIGHT", -50, -7)
title:SetJustifyH("LEFT")
title:SetWordWrap(false)

local timer = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
timer:SetPoint("TOPRIGHT", -8, -5)

local bar = CreateFrame("StatusBar", nil, frame)
bar:SetPoint("TOPLEFT", 8, -26)
bar:SetPoint("TOPRIGHT", -8, -26)
bar:SetHeight(6)
bar:SetStatusBarTexture("Interface\\Buttons\\WHITE8x8")
bar:SetStatusBarColor(0.25, 0.7, 1)
bar:SetMinMaxValues(0, 1)
local barBg = bar:CreateTexture(nil, "BACKGROUND")
barBg:SetAllPoints()
barBg:SetColorTexture(1, 1, 1, 0.12)

local stops = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
stops:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", 0, -6)
stops:SetPoint("TOPRIGHT", bar, "BOTTOMRIGHT", 0, -6)
stops:SetJustifyH("LEFT")
stops:SetSpacing(2)

local function render()
  local f = flight
  if not f then return end
  local r, now = f.route, GetTime()
  local elapsed = now - f.start

  -- per-stop ETAs from leg times
  local etas, t, exact = {}, 0, true
  for i = f.leg, r.hops do
    local lt, known = legTime(r, i)
    if i == f.leg then lt = math.max(lt - (now - f.legStart), 0) end
    if not known then exact = false end
    t = t + lt
    etas[i] = t
  end
  local remaining = t
  local full = db.routes[r.key]
  if full then remaining, exact = math.max(full - elapsed, 0), true end

  title:SetText(r.nodes[r.hops].name)
  timer:SetText((exact and "" or "~") .. fmt(remaining))
  bar:SetValue(elapsed / math.max(elapsed + remaining, 1))

  local lines = {}
  for i = 1, r.hops do
    local n = r.nodes[i].name
    if i < f.leg then
      lines[#lines + 1] = "|cff666666" .. n .. "|r"
    elseif i == r.hops then
      lines[#lines + 1] = "|cffffd100" .. n .. "|r  " .. fmt(remaining)
    else
      local eta = etas[i]
      if full and etas[r.hops] > 0 then eta = eta * remaining / etas[r.hops] end
      lines[#lines + 1] = (i == f.leg and "|cffffffff> " or "|cffbbbbbb  ") .. n .. "|r  " .. fmt(eta)
    end
  end
  stops:SetText(table.concat(lines, "\n"))
  frame:SetHeight(38 + stops:GetStringHeight())
end

----------------------------------------------------------------------------
-- Flight tracking
----------------------------------------------------------------------------
local function startFlight()
  local r = pending
  pending = nil
  if not r or GetTime() - r.at > 30 then
    r = nil
  end
  if not r then return end
  local now = GetTime()
  flight = { route = r, start = now, legStart = now, leg = 1, minD = math.huge }
  frame:Show()
  render()
end

local function endFlight()
  local f = flight
  flight = nil
  if db.locked then frame:Hide() end
  if not f then return end
  local r, now = f.route, GetTime()
  local d = dist(playerPos(), r.nodes[r.hops])
  if d and d < 300 then -- landed at the destination (not interrupted)
    if f.leg == r.hops then learnLeg(r, r.hops, now - f.legStart) end
    db.routes[r.key] = now - f.start
  end
end

local function tick()
  local onTaxi = UnitOnTaxi("player")
  if onTaxi and not flight then startFlight() end
  if not onTaxi and flight then endFlight() end
  local f = flight
  if not f then return end

  -- watch for passing intermediate stops (closest approach inside PASS_RADIUS)
  local r = f.route
  if f.leg < r.hops then
    local d = dist(playerPos(), r.nodes[f.leg])
    if d then
      local now = GetTime()
      if d < f.minD then f.minD, f.minT = d, now end
      -- passed it: we came close and are now moving away, or (if the stop's
      -- position is off) we're already nearer the following stop than it is
      local ahead = dist(playerPos(), r.nodes[f.leg + 1])
      local gap = dist(r.nodes[f.leg], r.nodes[f.leg + 1])
      local passed = (f.minD < PASS_RADIUS and d > f.minD + 40)
        or (ahead and gap and ahead < gap * 0.85 and d > f.minD + 40)
      if passed then
        learnLeg(r, f.leg, f.minT - f.legStart)
        f.legStart, f.leg, f.minD = f.minT, f.leg + 1, math.huge
      end
    end
  end
  render()
end

----------------------------------------------------------------------------
-- Boot + slash
----------------------------------------------------------------------------
local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:SetScript("OnEvent", function(_, _, name)
  if name ~= ADDON then return end
  FlightETADB = FlightETADB or {}
  db = FlightETADB
  db.legs = db.legs or {}
  db.routes = db.routes or {}
  db.speed = db.speed or DEFAULT_SPEED
  if db.locked == nil then db.locked = true end
  frame:ClearAllPoints()
  if db.point then
    frame:SetPoint(db.point[1], UIParent, db.point[2], db.point[3], db.point[4])
  else
    frame:SetPoint("TOP", UIParent, "TOP", 0, -120)
  end
  C_Timer.NewTicker(TICK, tick)
end)

SLASH_FLIGHTETA1, SLASH_FLIGHTETA2 = "/feta", "/flighteta"
SlashCmdList.FLIGHTETA = function(input)
  local cmd = strtrim(input or ""):lower()
  if cmd == "move" or cmd == "unlock" then
    db.locked = false
    if not flight then
      title:SetText("FlightETA — drag me")
      timer:SetText("0:00")
      stops:SetText("type /feta lock when done")
      frame:SetHeight(38 + stops:GetStringHeight())
      frame:Show()
    end
    msg("frame unlocked — drag it, then /feta lock.")
  elseif cmd == "lock" then
    db.locked = true
    if not flight then frame:Hide() end
    msg("frame locked.")
  elseif cmd == "reset" then
    wipe(db.legs); wipe(db.routes); db.speed = DEFAULT_SPEED
    msg("learned flight times cleared.")
  else
    local n = 0
    for _ in pairs(db.legs) do n = n + 1 end
    msg(("%d legs timed, avg speed %.1f yd/s. Times start as estimates (~) and become exact after you've flown a route once."):format(n, db.speed))
    print("  /feta move — unlock and drag the frame   /feta lock — lock it")
    print("  /feta reset — forget learned flight times")
  end
end
