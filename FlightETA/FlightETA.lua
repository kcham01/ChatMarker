local ADDON, ns = ...

local DEFAULT_SPEED = 32    -- yards/sec (without speed boosts), starting guess for unknown legs
local PATH_FACTOR = 1.25    -- flight paths curve; straight-line distance * this
local PASS_RADIUS = 250     -- yards: how close the taxi must come to count as passing a stop
local TICK = 0.2
local TRACE_EVERY = 2       -- seconds between position samples in the flight log

-- All stored times are "base" times: without speed boosts like Frequent Flier.
-- Shown time = base * speed factor; measured time / speed factor = base.

local db        -- FlightETADB: learned times, positions, settings
local log       -- FlightETALog: every flight taken, for building a database
local pending   -- route picked at the flight master, waiting for the taxi to start
local flight    -- active flight state

local function msg(text) DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffFlightETA|r: " .. text) end

local function fmt(sec)
  sec = math.max(0, math.floor(sec + 0.5))
  return ("%d:%02d"):format(math.floor(sec / 60), sec % 60)
end

local function r1(v) return v and math.floor(v * 10 + 0.5) / 10 end
local function r4(v) return v and math.floor(v * 10000 + 0.5) / 10000 end

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
  return { cont = cont, wx = x, wy = y, mapID = mapID, mx = pos.x, my = pos.y }
end

local function faction() return UnitFactionGroup("player") or "Alliance" end
local function charKey() return (UnitName("player") or "?") .. "-" .. (GetRealmName() or "?") end

----------------------------------------------------------------------------
-- Speed boosts: Frequent Flier (WoW Forever Legacy perk, +20% flight speed).
-- Detection follows InFlight: node 110300 of the Legacy Adventure tree.
----------------------------------------------------------------------------
local function hasFrequentFlier()
  local legacy = Constants and Constants.LegacyConsts
  if not (legacy and legacy.LEGACY_TREE_ADVENTURE_ID and C_Traits) then return false end
  local ok, active = pcall(function()
    local configID = C_Traits.GetConfigIDByTreeID(legacy.LEGACY_TREE_ADVENTURE_ID)
    local node = configID and C_Traits.GetNodeInfo(configID, 110300)
    return node and node.activeRank and node.activeRank > 0
  end)
  return ok and active or false
end

local function speedFactor()
  local override = db.ffChar[charKey()]
  local ff = override
  if ff == nil then ff = hasFrequentFlier() end
  return ff and (1 / 1.2) or 1
end

----------------------------------------------------------------------------
-- Flight point identity and positions
----------------------------------------------------------------------------
local function nodeKey(n) return n.nodeID and tostring(n.nodeID) or n.name end

local function continentOf(mapID)
  local guard = 0
  while mapID and guard < 10 do
    local info = C_Map.GetMapInfo(mapID)
    if not info then return end
    if info.mapType == Enum.UIMapType.Continent then return mapID end
    mapID, guard = info.parentMapID, guard + 1
  end
end

local function taxiMapID()
  local id = GetTaxiMapID and GetTaxiMapID()
  if id and id > 0 then return id end
  return continentOf(C_Map.GetBestMapForUnit("player"))
end

local function toWorld(mapID, x, y)
  if not (mapID and x and y) then return end
  local cont, w = C_Map.GetWorldPosFromMapPos(mapID, CreateVector2D(x, y))
  if cont and w then
    local wx, wy = w:GetXY()
    return cont, wx, wy
  end
end

-- slot -> { name, nodeID, mapID, mx, my, cont, wx, wy }
local function readTaxiNodes()
  local mapID = taxiMapID()
  local bySlot = {}
  local count = NumTaxiNodes and NumTaxiNodes() or 0
  for slot = 1, count do bySlot[slot] = { name = TaxiNodeName(slot) or "?", slot = slot } end

  -- modern API: nodeIDs and positions
  if mapID and C_TaxiMap and C_TaxiMap.GetAllTaxiNodes then
    local ok, list = pcall(C_TaxiMap.GetAllTaxiNodes, mapID)
    for _, n in ipairs(ok and list or {}) do
      local rec = n.slotIndex and bySlot[n.slotIndex]
      if rec then
        rec.nodeID = n.nodeID
        if n.position then rec.mapID, rec.mx, rec.my = mapID, n.position.x, n.position.y end
      end
    end
  end

  -- classic API fallback for positions
  for slot, rec in pairs(bySlot) do
    if not rec.mx and TaxiNodePosition then
      local x, y = TaxiNodePosition(slot)
      if x then rec.mapID, rec.mx, rec.my = mapID, x, y end
    end
    -- fallback nodeID: match the English name against the reference data
    if not rec.nodeID and ns.REFNAMES then
      local ids = ns.REFNAMES[faction()]
      rec.nodeID = ids and ids[(rec.name:gsub(",.*$", ""))]
    end
    rec.cont, rec.wx, rec.wy = toWorld(rec.mapID, rec.mx, rec.my)
    -- exact position, learned while standing at that flight master, beats the map
    local exact = db.fpPos[nodeKey(rec)]
    if exact then rec.cont, rec.wx, rec.wy = exact.cont, exact.wx, exact.wy end
  end
  return bySlot
end

-- When the flight map opens you're standing at a flight master: remember
-- exactly where it is, so stop-passing detection doesn't rely on the map.
local function learnCurrentNode(bySlot)
  if not TaxiNodeGetType then return end
  local p = playerPos()
  if not p then return end
  for slot, rec in pairs(bySlot) do
    if TaxiNodeGetType(slot) == "CURRENT" then
      db.fpPos[nodeKey(rec)] = { cont = p.cont, wx = r1(p.wx), wy = r1(p.wy), name = rec.name }
      return
    end
  end
end

----------------------------------------------------------------------------
-- Reading the route off the flight master
----------------------------------------------------------------------------
local function copyNode(rec)
  return { name = rec.name, nodeID = rec.nodeID, mapID = rec.mapID, mx = rec.mx, my = rec.my,
           cont = rec.cont, wx = rec.wx, wy = rec.wy }
end

local function buildRoute(destSlot)
  local hops = GetNumRoutes and GetNumRoutes(destSlot) or 0
  if hops < 1 then return end
  local bySlot = readTaxiNodes()
  local function node(slot) return copyNode(bySlot[slot] or { name = TaxiNodeName(slot) or "?" }) end
  -- The start is the flight master you're standing at. (On a nonstop route
  -- TaxiGetNodeSlot can report the destination as the start.)
  local src
  if TaxiNodeGetType then
    for slot in pairs(bySlot) do
      if TaxiNodeGetType(slot) == "CURRENT" then src = slot break end
    end
  end
  if not src then
    local s1 = TaxiGetNodeSlot(destSlot, 1, false)
    if s1 ~= destSlot then src = s1 end
  end
  local nodes = { [0] = src and node(src) or { name = "?" } }
  if not src then -- unknown start: use where you're standing
    local p = playerPos()
    if p then nodes[0].cont, nodes[0].wx, nodes[0].wy = p.cont, p.wx, p.wy end
  end
  for i = 1, hops do nodes[i] = node(TaxiGetNodeSlot(destSlot, i, true)) end
  nodes[hops] = node(destSlot) -- the final stop is exactly what was clicked
  -- The route is keyed by every stop on it, by nodeID: unlocking a flight
  -- point in between changes the route, so it gets its own time.
  local keys = {}
  for i = 0, hops do keys[#keys + 1] = nodeKey(nodes[i]) end
  return { nodes = nodes, hops = hops, key = faction() .. ":" .. table.concat(keys, ">"), faction = faction() }
end

hooksecurefunc("TakeTaxiNode", function(slot)
  local ok, route = pcall(buildRoute, slot)
  if ok and route then
    route.at = GetTime()
    pending = route
  end
end)

----------------------------------------------------------------------------
-- Estimates and learning (base times)
----------------------------------------------------------------------------
local function legKey(r, i) return r.faction .. ":" .. nodeKey(r.nodes[i - 1]) .. ">" .. nodeKey(r.nodes[i]) end

local function refTime(r, a, b)
  local ref = ns.REF and ns.REF[r.faction]
  local ia, ib = r.nodes[a].nodeID, r.nodes[b].nodeID
  return ref and ia and ib and ref[ia] and ref[ia][ib]
end

-- base seconds for leg i; source = "learned" | "reference" | "distance" | "guess".
-- Landing at a stop takes longer than flying past it (the descent), so the two
-- are learned separately.
local function legBase(r, i, landing)
  local t = landing and db.landLegs[legKey(r, i)] or db.legs[legKey(r, i)]
  if t then return t, "learned" end
  t = refTime(r, i - 1, i)
  if t then return t, "reference" end
  local d = dist(r.nodes[i - 1], r.nodes[i])
  if d and d > 50 then return d * PATH_FACTOR / db.speed, "distance" end
  return nil, "unknown"
end

-- base seconds for the whole route, if it has been flown as a whole. (The
-- reference data's start->destination times are not used: they were
-- recorded on whatever route the recorder had, which may not be this one.)
local function routeBase(r)
  local t = db.routes[r.key]
  if t then return t, "learned" end
end

local function learnLeg(r, i, base, landing)
  if base < 3 then return end
  if landing then db.landLegs[legKey(r, i)] = r1(base) return end
  db.legs[legKey(r, i)] = r1(base)
  local d = dist(r.nodes[i - 1], r.nodes[i])
  if d and d > 200 then
    local speed = d * PATH_FACTOR / base
    if speed > 5 and speed < 200 then db.speed = db.speed * 0.7 + speed * 0.3 end
  end
end

-- Stop-button deadline for landing at stop i: you must press at least
-- `cutoff` seconds before reaching it (base seconds), or the taxi has
-- already taken the fly-past path and lands at the stop after.
local function deadlineFor(r, i)
  local d = db.deadline[legKey(r, i)]
  return d and d.fail and (d.fail + 1) or nil
end

local function learnDeadline(r, i, secs, ok)
  local k = legKey(r, i)
  local d = db.deadline[k] or {}
  if ok then d.ok = math.min(d.ok or math.huge, r1(secs))
  else d.fail = math.max(d.fail or 0, r1(secs)) end
  db.deadline[k] = d
end

----------------------------------------------------------------------------
-- Display
----------------------------------------------------------------------------
local frame = CreateFrame("Frame", "FlightETAFrame", UIParent, "BackdropTemplate")
frame:SetSize(240, 60)
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

-- shown seconds to every remaining stop, plus whether the final time is exact
local function computeEtas(f, now)
  local r, k = f.route, f.factor
  local etas, t, exact, unknown = {}, 0, true, false
  local final = f.landAt or r.hops
  for i = f.leg, r.hops do
    local base, src = legBase(r, i, i == final)
    if not base then
      unknown = true -- no time for this leg: ETAs from here on are unknown
    elseif not unknown then
      local lt = base * k
      if i == f.leg then
        local over = (now - f.legStart) - lt
        lt = math.max(-over, 0)
        if i == final and over > 0 then f.over = over end
      end
      if src ~= "learned" and i <= final then exact = false end
      t = t + lt
      etas[i] = t
    end
  end
  -- a whole-route time beats summed legs; scale the stop ETAs to match it
  local full = not f.landAt and routeBase(r)
  if full then
    local left = full * k - (now - f.start)
    f.over = left < 0 and -left or nil
    if etas[r.hops] and etas[r.hops] > 0 then
      local scale = math.max(left, 0) / etas[r.hops]
      for i = f.leg, r.hops do if etas[i] then etas[i] = etas[i] * scale end end
    else
      etas[r.hops] = math.max(left, 0)
    end
    exact = true
  end
  return etas, exact
end

-- which stop the stop button would land you at right now, given learned deadlines
local function stopTarget(f, etas)
  local r = f.route
  for i = f.leg, r.hops - 1 do
    local cutoff = deadlineFor(r, i)
    if not cutoff or not etas[i] or etas[i] > cutoff * f.factor then return i, cutoff end
  end
end

local function render()
  local f = flight
  if not f then return end
  local r, now = f.route, GetTime()
  local elapsed = now - f.start
  local final = f.landAt or r.hops
  f.over = nil
  local etas, exact = computeEtas(f, now)
  f.etas = etas
  local remaining = etas[final]

  title:SetText((f.landAt and "|cffff8040Landing:|r " or "") .. r.nodes[final].name)
  if not remaining then
    -- never flown and nothing to estimate from: count up while timing it
    timer:SetText("|cff999999" .. fmt(elapsed) .. "|r")
    bar:SetValue(0)
  elseif remaining <= 0 and f.over then
    timer:SetText("|cffff8040+" .. fmt(f.over) .. "|r") -- running late
    bar:SetValue(1)
  else
    timer:SetText((exact and "" or "~") .. fmt(remaining))
    bar:SetValue(elapsed / math.max(elapsed + remaining, 1))
  end
  local function eta(i) return etas[i] and fmt(etas[i]) or "?" end

  local lines = {}
  if r.hops == 1 then
    lines[1] = "|cff888888Nonstop: the stop button won't land you early|r"
    if not remaining then lines[2] = "|cff888888First flight on this route: timing it|r" end
  else
    for i = 1, r.hops do
      local n = r.nodes[i].name
      if i < f.leg then
        lines[#lines + 1] = "|cff555555" .. n .. "  (passed)|r"
      elseif i > final then
        lines[#lines + 1] = "|cff555555" .. n .. "  (skipped)|r"
      elseif i == final then
        lines[#lines + 1] = "|cffffd100" .. n .. "|r  " .. eta(i)
      else
        lines[#lines + 1] = (i == f.leg and "|cffffffff> " or "|cffbbbbbb  ") .. n .. "|r  " .. eta(i)
      end
    end
    if not f.landAt then
      local target, cutoff = stopTarget(f, etas)
      if target then
        local line = ("|cff40c0ffStop button: %s in %s"):format(r.nodes[target].name, eta(target))
        if cutoff and etas[target] then line = line .. (" (press within %s)"):format(fmt(etas[target] - cutoff * f.factor)) end
        lines[#lines + 1] = line .. "|r"
      end
    end
  end
  if f.ported then lines[#lines + 1] = "|cff888888Teleport/summon taken: this flight won't be timed|r" end
  stops:SetText(table.concat(lines, "\n"))
  frame:SetHeight(38 + stops:GetStringHeight())
end

----------------------------------------------------------------------------
-- Flight log (dev): every flight is saved to FlightETALog for a database
----------------------------------------------------------------------------
local function nodeRec(n)
  return { name = n.name, nodeID = n.nodeID, mapID = n.mapID, x = r4(n.mx), y = r4(n.my),
           cont = n.cont, wx = r1(n.wx), wy = r1(n.wy) }
end

-- every flight master on the open taxi map
local function catalogNodes(bySlot)
  for slot, n in pairs(bySlot) do
    local key = nodeKey(n)
    local rec = log.nodes[key] or {}
    rec.name, rec.nodeID, rec.mapID, rec.x, rec.y = n.name, n.nodeID, n.mapID, r4(n.mx), r4(n.my)
    rec.cont, rec.wx, rec.wy = n.cont, r1(n.wx), r1(n.wy)
    rec.faction = faction()
    if TaxiNodeGetType then
      local t = TaxiNodeGetType(slot)
      if t == "CURRENT" then rec.exact = true end
    end
    log.nodes[key] = rec
  end
end

local function startLog(f)
  if not log.enabled then return end
  local r = f.route
  local list = {}
  for i = 1, r.hops do list[i] = nodeRec(r.nodes[i]) end
  local _, build = GetBuildInfo()
  local full = routeBase(r)
  f.log = {
    date = date("%Y-%m-%d %H:%M:%S"), build = build,
    char = UnitName("player"), realm = GetRealmName(), faction = r.faction,
    level = UnitLevel("player"), speedFactor = r4(f.factor), frequentFlier = f.factor < 1,
    route = r.key, from = nodeRec(r.nodes[0]), to = nodeRec(r.nodes[r.hops]), stops = list, hops = r.hops,
    expected = full and r1(full * f.factor), trace = {},
  }
  f.nextTrace = 0
end

local function sampleTrace(f, now)
  if not f.log or now < f.nextTrace then return end
  f.nextTrace = now + TRACE_EVERY
  local p = playerPos()
  if p then table.insert(f.log.trace, { r1(now - f.start), r1(p.wx), r1(p.wy) }) end
end

local function finishLog(f, how)
  local L = f.log
  if not L or L.saved then return end
  L.saved = true
  local now, p = GetTime(), playerPos()
  L.total = r1(now - f.start)
  L.ended = how -- "landed", "logout", "ported", "resumed"
  if p then
    L.landed = { cont = p.cont, wx = r1(p.wx), wy = r1(p.wy), mapID = p.mapID, x = r4(p.mx), y = r4(p.my) }
    local bestD, best
    for key, n in pairs(log.nodes) do
      local d = dist(p, n)
      if d and (not bestD or d < bestD) then bestD, best = d, key end
    end
    if best then
      L.landed.nearest = best
      L.landed.nearestName = log.nodes[best].name
      L.landed.nearestYards = r1(bestD)
    end
  end
  table.insert(log.flights, L)
end

----------------------------------------------------------------------------
-- Stop button and things that end a flight early
----------------------------------------------------------------------------
-- The stop button (TaxiRequestEarlyLanding) sets you down at the next
-- unlocked stop on the route, if you press before the taxi commits to
-- flying past it.
hooksecurefunc("TaxiRequestEarlyLanding", function()
  local f = flight
  if not f or f.landAt or f.leg >= f.route.hops then return end
  local secs = f.etas and f.etas[f.leg]
  f.landAt = f.leg
  f.press = { stop = f.leg, at = GetTime() - f.start, secsBefore = secs and secs / f.factor }
  if f.log then
    f.log.stopButton = { at = r1(f.press.at), expected = f.route.nodes[f.leg].name, expectedStop = f.leg,
                         secondsBeforeStop = r1(secs) }
  end
  msg("landing early at |cffffd100" .. f.route.nodes[f.leg].name .. "|r.")
  render()
end)

local function portTaken()
  if flight then flight.ported = true end
end
hooksecurefunc(C_SummonInfo, "ConfirmSummon", portTaken)
if AcceptBattlefieldPort then
  hooksecurefunc("AcceptBattlefieldPort", function(_, accept) if accept then portTaken() end end)
end
if CompleteLFGRoleCheck then
  hooksecurefunc("CompleteLFGRoleCheck", function(ok) if ok then portTaken() end end)
end
if CompleteLFGReadyCheck then
  hooksecurefunc("CompleteLFGReadyCheck", function(ok) if ok then portTaken() end end)
end

----------------------------------------------------------------------------
-- Flight tracking
----------------------------------------------------------------------------
local function startFlight()
  local r = pending
  pending = nil
  if not r or GetTime() - r.at > 30 then return end
  local now = GetTime()
  flight = { route = r, start = now, legStart = now, leg = 1, minD = math.huge, factor = speedFactor() }
  startLog(flight)
  frame:Show()
  render()
end

local function endFlight()
  local f = flight
  flight = nil
  db.active = nil
  if db.locked then frame:Hide() end
  if not f then return end
  local r, now = f.route, GetTime()
  local final = f.landAt or r.hops
  local d = dist(playerPos(), r.nodes[final])
  local arrived = (d and d < 300) or (not d and not r.nodes[final].wx)
  finishLog(f, f.ported and "ported" or (f.resumed and "resumed" or "landed"))
  if f.ported or f.resumed or not arrived then return end
  if f.leg == final and not f.blind then learnLeg(r, final, (now - f.legStart) / f.factor, true) end
  if final == r.hops then db.routes[r.key] = r1((now - f.start) / f.factor) end
  if f.press and f.press.secsBefore and f.press.stop == final then
    learnDeadline(r, final, f.press.secsBefore, true)
  end
end

local function passStop(f, when, yards, blind)
  local r = f.route
  if not blind and not f.blind then learnLeg(r, f.leg, (when - f.legStart) / f.factor) end
  if f.log then
    local st = f.log.stops[f.leg]
    st.passedAt, st.passedYards, st.estimated = r1(when - f.start), r1(yards), blind or nil
  end
  -- flew past the stop we asked to land at: pressed too late
  if f.landAt == f.leg then
    if f.press and f.press.secsBefore and not blind then learnDeadline(r, f.leg, f.press.secsBefore, false) end
    if f.log and f.log.stopButton then f.log.stopButton.missed = true end
    f.landAt = f.leg + 1
  end
  f.legStart, f.leg, f.minD = when, f.leg + 1, math.huge
  f.blind = blind
end

local function tick()
  local onTaxi = UnitOnTaxi("player")
  if onTaxi and not flight then startFlight() end
  if not onTaxi and flight then endFlight() end
  local f = flight
  if not f then return end

  local r, now = f.route, GetTime()
  if f.leg < r.hops then
    local me = playerPos()
    local d = dist(me, r.nodes[f.leg])
    if d then
      -- passed it: came close and now moving away, or (if the stop's map
      -- position is off) already nearer the next stop than it is
      if d < f.minD then f.minD, f.minT = d, now end
      local ahead = dist(me, r.nodes[f.leg + 1])
      local gap = dist(r.nodes[f.leg], r.nodes[f.leg + 1])
      if (f.minD < PASS_RADIUS and d > f.minD + 40) or (ahead and gap and ahead < gap * 0.85 and d > f.minD + 40) then
        passStop(f, f.minT, f.minD)
      end
    elseif f.landAt ~= f.leg and f.etas and f.etas[f.leg] and f.etas[f.leg] <= 0 then
      -- no position for this stop: fall back to the estimate
      passStop(f, now, nil, true)
    end
  end
  sampleTrace(f, now)
  render()
end

----------------------------------------------------------------------------
-- Surviving /reload and relog mid-flight
----------------------------------------------------------------------------
local function saveActive()
  local f = flight
  if not f then return end
  db.active = { route = f.route, start = f.start, legStart = f.legStart, leg = f.leg, landAt = f.landAt,
                factor = f.factor, ported = f.ported, press = f.press, log = f.log, savedAt = time(),
                savedClock = GetTime() }
end

local function restoreActive(isInitialLogin)
  local a = db.active
  db.active = nil
  if not (a and UnitOnTaxi("player") and time() - a.savedAt < 600) then return end
  local f = { route = a.route, start = a.start, legStart = a.legStart, leg = a.leg, landAt = a.landAt,
              factor = a.factor, ported = a.ported, press = a.press, log = a.log, minD = math.huge, nextTrace = 0 }
  if isInitialLogin then
    -- relog: the flight paused while you were offline; the game resumes it
    -- and lands you at the next unlocked stop
    f.resumed = true
    local shift = GetTime() - a.savedClock
    f.start, f.legStart = a.start + shift, a.legStart + shift
    if f.route.hops > f.leg then f.landAt = f.leg end
  end
  if f.log then f.log.saved = nil end
  flight = f
  frame:Show()
  render()
end

----------------------------------------------------------------------------
-- Boot + slash
----------------------------------------------------------------------------
local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("TAXIMAP_OPENED")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("PLAYER_LOGOUT")
ev:SetScript("OnEvent", function(_, event, name, arg2)
  if event == "TAXIMAP_OPENED" then
    local ok, bySlot = pcall(readTaxiNodes)
    if ok then
      pcall(learnCurrentNode, bySlot)
      if log.enabled then pcall(catalogNodes, bySlot) end
    end
    return
  elseif event == "PLAYER_LOGOUT" then
    saveActive() -- /reload or logout; the log entry is kept with the active flight
    return
  elseif event == "PLAYER_ENTERING_WORLD" then
    if db and db.active then restoreActive(name) end -- name = isInitialLogin here
    return
  end
  if name ~= ADDON then return end
  FlightETALog = FlightETALog or {}
  log = FlightETALog
  log.flights = log.flights or {}
  log.nodes = log.nodes or {}
  if log.enabled == nil then log.enabled = true end
  FlightETADB = FlightETADB or {}
  db = FlightETADB
  if db.version ~= 2 then -- v1 keyed times by name; start fresh
    db.legs, db.landLegs, db.routes, db.version = {}, {}, {}, 2
  end
  db.fpPos = db.fpPos or {}
  db.deadline = db.deadline or {}
  db.landLegs = db.landLegs or {}
  db.ffChar = db.ffChar or {}
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

local function count(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end

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
  elseif cmd:match("^ff") then
    local arg = cmd:match("^ff%s*(%a*)")
    if arg == "on" then db.ffChar[charKey()] = true
    elseif arg == "off" then db.ffChar[charKey()] = false
    else db.ffChar[charKey()] = nil end
    local o = db.ffChar[charKey()]
    msg(("Frequent Flier for this character: %s (%s)"):format(
      speedFactor() < 1 and "yes, flights 20% faster" or "no",
      o == nil and "auto-detected; /feta ff on|off to override" or "set by you; /feta ff auto to detect"))
  elseif cmd == "log" then
    log.enabled = not log.enabled
    msg("flight logging " .. (log.enabled and "ON" or "OFF") .. (" (%d flights saved)"):format(#log.flights))
  elseif cmd == "log clear" then
    wipe(log.flights)
    msg("flight log cleared (flight master list kept).")
  elseif cmd == "reset" then
    wipe(db.legs); wipe(db.landLegs); wipe(db.routes); wipe(db.deadline); db.speed = DEFAULT_SPEED
    msg("learned flight times and stop deadlines cleared.")
  else
    msg(("%d routes and %d legs timed, %d stop deadlines learned, %d flight master positions."):format(
      count(db.routes), count(db.legs), count(db.deadline), count(db.fpPos)))
    print(("  Frequent Flier: %s   (/feta ff on | off | auto)"):format(speedFactor() < 1 and "yes" or "no"))
    print(("  /feta log — logging is %s: %d flights, %d flight masters saved   /feta log clear"):format(
      log.enabled and "ON" or "OFF", #log.flights, count(log.nodes)))
    print("  /feta move | lock — position the frame   /feta reset — forget learned times")
  end
end
