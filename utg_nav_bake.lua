--[[ ============================================================
     UTG NAV BAKE  —  Untitled Tag Game (PlaceId 14044547200)

     Eigener Navigationsgraph statt PathfindingService.

     Warum ueberhaupt: gemessen auf UltimatePaintball findet die
     eingebaute Wegfindung Ziele ueber 25 Studs Hoehenunterschied
     praktisch nie (0/8, 2/14, 0/6, 0/8), AgentCanClimb ist
     wirkungslos, und sie kennt keine der Fortbewegungsarten dieses
     Spiels — Wallrun, Zipline, Jumppad, Rail, SwingBar, Vault.

     Dieser Graph kennt sie als TYPISIERTE KANTEN, und seine Kosten
     sind SEKUNDEN statt Studs: eine Zipline mit 40 Studs/s ist
     billiger als derselbe Weg zu Fuss, Klettern mit 8 Studs/s teuer.

     Maps sind ein fester Pool in Rotation -> einmal backen, als
     Datei ablegen, danach nur noch laden.
     ============================================================ ]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local LP = Players.LocalPlayer

local NAV = {}
getgenv().__UTG_NAV_GRAPH = NAV

------------------------------------------------------------------
-- 1) Bewegungsprofil — aus dem Spiel gelesen, nicht geraten
------------------------------------------------------------------
local function profile()
    local char = LP.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    local g = math.max(workspace.Gravity, 1)          -- gemessen 71.25
    local vy = 28
    if hum then
        vy = hum.UseJumpPower and hum.JumpPower
             or math.sqrt(2 * g * math.max(hum.JumpHeight, 1))
    end
    local speed = 32                                   -- Renntempo des Bots
    local air = 2 * vy / g
    return {
        g = g, vy = vy, speed = speed,
        air = air,
        reach = speed * air,      -- flache Sprungweite, hier ~25 Studs
        rise = (vy * vy) / (2 * g),  -- Sprunghoehe, hier ~5.5 Studs
        climbSpeed = 8,           -- Leiter
        wallSpeed = 38,           -- gemessene Wallride-Steigkette
        zipSpeed = 40,
    }
end

local CFG = {
    cell = 8,            -- Rasterweite; groeber als die Probe, der Graph
                         -- muss zur Laufzeit durchsuchbar bleiben
    maxLevels = 10,
    agentHeight = 5,
    maxSlope = 50,
    stepUp = 3.0,        -- Hoehe, die Gehen noch schafft
    wallChainMax = 25,   -- wie hoch eine Wallride-Kette traegt
    nodeCap = 9000,
    rayBudget = 600,
}

------------------------------------------------------------------
-- 2) Raycasts
------------------------------------------------------------------
local rp = RaycastParams.new()
rp.FilterType = Enum.RaycastFilterType.Exclude
rp.RespectCanCollide = true

local frameRays = 0
local function cast(o, d)
    frameRays = frameRays + 1
    return workspace:Raycast(o, d, rp)
end
local function breathe()
    if frameRays >= CFG.rayBudget then
        frameRays = 0
        RunService.Heartbeat:Wait()
    end
end
local function refreshFilter()
    local ig = { workspace.CurrentCamera }
    for _, pl in ipairs(Players:GetPlayers()) do
        if pl.Character then ig[#ig + 1] = pl.Character end
    end
    for _, n in ipairs({ "EmotePuppets", "ragdolls", "bullets", "Displayed", "coins", "Debris" }) do
        local f = workspace:FindFirstChild(n)
        if f then ig[#ig + 1] = f end
    end
    rp.FilterDescendantsInstances = ig
end

local function currentMap()
    local cm = workspace:FindFirstChild("CurrentMap")
    return cm and cm:GetChildren()[1] or nil
end

------------------------------------------------------------------
-- 3) Knoten: Saeulen-Abtastung ueber die ganze Hoehe
------------------------------------------------------------------
local function bounds(mapRoot, playerY)
    local xs, ys, zs, n = {}, {}, {}, 0
    for _, d in ipairs(mapRoot:GetDescendants()) do
        if d:IsA("BasePart") and d.CanCollide then
            n = n + 1
            xs[#xs+1], ys[#ys+1], zs[#zs+1] = d.Position.X, d.Position.Y, d.Position.Z
        end
    end
    if n < 20 then return nil end
    table.sort(xs) table.sort(ys) table.sort(zs)
    local function pc(t, p) return t[math.clamp(math.floor(#t*p+0.5), 1, #t)] end
    local minY, maxY = pc(ys, 0.01), pc(ys, 0.99)
    if playerY then
        minY = math.min(minY, playerY - 40)
        maxY = math.min(maxY + 30, playerY + 260)
    end
    return { min = Vector3.new(pc(xs,0.02), minY, pc(zs,0.02)),
             max = Vector3.new(pc(xs,0.98), maxY, pc(zs,0.98)) }
end

local function sampleNodes(bb, onProgress)
    local nodes, grid = {}, {}
    local cell = CFG.cell
    local nx = math.floor((bb.max.X - bb.min.X) / cell)
    local nz = math.floor((bb.max.Z - bb.min.Z) / cell)
    local cosLimit = math.cos(math.rad(CFG.maxSlope))
    local topY = bb.max.Y + 8
    for ix = 0, nx do
        for iz = 0, nz do
            local x = bb.min.X + ix * cell
            local z = bb.min.Z + iz * cell
            local y, guard, prevY = topY, 0, nil
            while guard < CFG.maxLevels and y > bb.min.Y do
                guard = guard + 1
                local hit = cast(Vector3.new(x, y, z), Vector3.new(0, -(y - bb.min.Y + 4), 0))
                if not hit then break end
                local hy = hit.Position.Y
                y = (prevY and hy > prevY - 0.4) and (hy - 4.0) or (hy - 1.0)
                prevY = hy
                if hit.Normal.Y >= cosLimit then
                    local foot = hit.Position + Vector3.new(0, 0.5, 0)
                    if not cast(foot, Vector3.new(0, CFG.agentHeight, 0)) then
                        local nd = { p = foot, ix = ix, iz = iz, id = #nodes + 1, e = {} }
                        nodes[#nodes+1] = nd
                        local k = ix .. "," .. iz
                        local b = grid[k] ; if not b then b = {} grid[k] = b end
                        b[#b+1] = nd
                    end
                end
                if #nodes >= CFG.nodeCap then break end
            end
            if #nodes >= CFG.nodeCap then break end
            breathe()
        end
        if #nodes >= CFG.nodeCap then break end
        if onProgress and ix % 5 == 0 then
            onProgress(ix / math.max(nx,1), #nodes)
        end
    end
    return nodes, grid, cell
end

------------------------------------------------------------------
-- 4) Kanten. Kosten sind SEKUNDEN.
------------------------------------------------------------------
local function addEdge(a, b, kind, cost)
    a.e[#a.e+1] = { to = b.id, k = kind, c = cost }
end

-- naechster Knoten zu einer Position, ueber das Raster
local function nearest(grid, bb, cell, pos, maxDist, maxDy)
    local ix = math.floor((pos.X - bb.min.X) / cell + 0.5)
    local iz = math.floor((pos.Z - bb.min.Z) / cell + 0.5)
    local span = math.ceil(maxDist / cell)
    local best, bd
    for dx = -span, span do
        for dz = -span, span do
            local b = grid[(ix+dx) .. "," .. (iz+dz)]
            if b then
                for _, n in ipairs(b) do
                    local d = (n.p - pos).Magnitude
                    if d <= maxDist and (not maxDy or math.abs(n.p.Y - pos.Y) <= maxDy) then
                        if not bd or d < bd then best, bd = n, d end
                    end
                end
            end
        end
    end
    return best
end

-- 4a) GEHEN
local function buildWalk(nodes, grid, prof)
    local dirs = { {1,0}, {0,1}, {1,1}, {1,-1}, {-1,1}, {-1,0}, {0,-1}, {-1,-1} }
    local count = 0
    for i, n in ipairs(nodes) do
        for _, d in ipairs(dirs) do
            local b = grid[(n.ix+d[1]) .. "," .. (n.iz+d[2])]
            if b then
                for _, o in ipairs(b) do
                    local dy = o.p.Y - n.p.Y
                    if math.abs(dy) <= CFG.stepUp then
                        local a = n.p + Vector3.new(0, 2.2, 0)
                        local c = o.p + Vector3.new(0, 2.2, 0)
                        if not cast(a, c - a) then
                            addEdge(n, o, "walk", (o.p - n.p).Magnitude / prof.speed)
                            count = count + 1
                        end
                    end
                end
            end
        end
        if i % 300 == 0 then breathe() end
    end
    return count
end

-- 4b) KLETTERN an Leitern — das, was PathfindingService gar nicht kann
local function buildClimb(nodes, grid, bb, cell, mapRoot, prof)
    local count = 0
    for _, t in ipairs(mapRoot:GetDescendants()) do
        if t:IsA("TrussPart") then
            local half = t.Size.Y * 0.5
            local foot = t.Position - Vector3.new(0, half - 2.5, 0)
            local top  = t.Position + Vector3.new(0, half, 0)
            local a = nearest(grid, bb, cell, foot, 10, 8)
            local b = nearest(grid, bb, cell, top, 12, 10)
            if a and b and a ~= b then
                local cost = (t.Size.Y / prof.climbSpeed) + 0.6
                addEdge(a, b, "climb", cost)
                addEdge(b, a, "drop", math.sqrt(2 * math.max(t.Size.Y,1) / prof.g))
                count = count + 1
            end
            breathe()
        end
    end
    return count
end

-- 4c) SPRINGEN und FALLEN zwischen Kanten verschiedener Ebenen
local function isRim(n, grid)
    for _, d in ipairs({ {1,0}, {-1,0}, {0,1}, {0,-1} }) do
        local b = grid[(n.ix+d[1]) .. "," .. (n.iz+d[2])]
        local found = false
        if b then
            for _, o in ipairs(b) do
                if math.abs(o.p.Y - n.p.Y) <= CFG.stepUp then found = true break end
            end
        end
        if not found then return true end
    end
    return false
end

local function arcClear(from, to, prof)
    local flat = (to - from) * Vector3.new(1,0,1)
    local dist = flat.Magnitude
    if dist < 0.5 then return false end
    local t = dist / prof.speed
    if t > prof.air * 1.15 then return false end
    local vy = ((to.Y - from.Y) + 0.5 * prof.g * t * t) / t
    if vy > prof.vy * 1.02 then return false end
    local u = flat.Unit
    local prev = from + Vector3.new(0, 1.5, 0)
    for s = 1, 8 do
        local tt = t * (s/8)
        local p = from + u * (prof.speed * tt)
                + Vector3.new(0, vy*tt - 0.5*prof.g*tt*tt + 1.5, 0)
        if cast(prev, p - prev) then return false end
        prev = p
    end
    return true
end

local function buildJumpDrop(nodes, grid, cell, prof)
    local rim, rimGrid = {}, {}
    for _, n in ipairs(nodes) do
        if isRim(n, grid) then
            rim[#rim+1] = n
            local k = n.ix .. "," .. n.iz
            local b = rimGrid[k] ; if not b then b = {} rimGrid[k] = b end
            b[#b+1] = n
        end
    end
    local span = math.ceil((prof.reach * 0.9) / cell)
    local jumps, drops = 0, 0
    for i, a in ipairs(rim) do
        for dx = -span, span do
            for dz = -span, span do
                local b = rimGrid[(a.ix+dx) .. "," .. (a.iz+dz)]
                if b then
                    for _, o in ipairs(b) do
                        if o.id ~= a.id then
                            local flat = ((o.p - a.p) * Vector3.new(1,0,1)).Magnitude
                            local dy = o.p.Y - a.p.Y
                            if flat <= prof.reach * 0.9 and math.abs(dy) > CFG.stepUp then
                                if dy > 0 and dy <= prof.rise and arcClear(a.p, o.p, prof) then
                                    addEdge(a, o, "jump", flat / prof.speed + 0.25)
                                    jumps = jumps + 1
                                elseif dy < 0 then
                                    -- runterfallen geht fast immer
                                    local d = cast(a.p + Vector3.new(0,1,0),
                                                   (o.p - a.p) + Vector3.new(0,-2,0))
                                    if not d or (d.Position - o.p).Magnitude < 7 then
                                        addEdge(a, o, "drop",
                                                math.sqrt(2 * math.abs(dy) / prof.g) + flat/prof.speed)
                                        drops = drops + 1
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
        if i % 40 == 0 then breathe() end
    end
    return jumps, drops, rim
end

-- 4d) WALLRIDE-STEIGKETTE — der eigentliche Vertikal-Motor dieses Spiels.
-- Jeder Wallrun-Start gibt Auftrieb; die Kette traegt gemessen bis ~25 Studs.
local function buildWallrun(nodes, grid, bb, cell, rim, prof)
    local count = 0
    for i, n in ipairs(rim) do
        -- steile Wand in Reichweite?
        local wallAt
        for k = 0, 7 do
            local ang = k * math.pi / 4
            local dir = Vector3.new(math.cos(ang), 0, math.sin(ang)) * 5
            local h = cast(n.p + Vector3.new(0, 3, 0), dir)
            if h and math.abs(h.Normal.Y) < 0.25 then wallAt = h break end
        end
        if wallAt then
            -- gibt es oberhalb eine Standflaeche in Kettenreichweite?
            for _, up in ipairs({ 10, 16, 22, CFG.wallChainMax }) do
                local probe = n.p + Vector3.new(0, up, 0)
                local o = nearest(grid, bb, cell, probe, 14, 6)
                if o and o.id ~= n.id then
                    local gain = o.p.Y - n.p.Y
                    if gain > CFG.stepUp and gain <= CFG.wallChainMax then
                        -- Weg an der Wand hoch muss frei sein
                        if not cast(n.p + Vector3.new(0, 2, 0), Vector3.new(0, gain, 0)) then
                            addEdge(n, o, "wallrun", gain / prof.wallSpeed + 0.5)
                            count = count + 1
                            break
                        end
                    end
                end
            end
        end
        if i % 60 == 0 then breathe() end
    end
    return count
end

-- 4e) Zipline und Jumppad
local function buildHelpers(nodes, grid, bb, cell, mapRoot, prof)
    local zips, pads = 0, 0
    local zipGroups = {}
    for _, d in ipairs(mapRoot:GetDescendants()) do
        if d:IsA("BasePart") then
            if d.Parent and d.Parent:GetAttribute("Zipline") then
                local g = zipGroups[d.Parent]
                if not g then g = {} zipGroups[d.Parent] = g end
                g[#g+1] = d
            else
                local amount = d:GetAttribute("BounceAmount") or d:GetAttribute("RelativeBounceAmount")
                if type(amount) == "number" and amount > 0 then
                    local rise = (amount * amount) / (2 * prof.g)
                    local air = 2 * amount / prof.g
                    local src = nearest(grid, bb, cell, d.Position + Vector3.new(0, d.Size.Y*0.5, 0), 10, 8)
                    if src then
                        for k = 0, 7 do
                            local ang = k * math.pi / 4
                            local land = d.Position + Vector3.new(
                                math.cos(ang) * prof.speed * air * 0.5,
                                rise * 0.8,
                                math.sin(ang) * prof.speed * air * 0.5)
                            local dst = nearest(grid, bb, cell, land, 14, 12)
                            if dst and dst.id ~= src.id and dst.p.Y > src.p.Y + CFG.stepUp then
                                addEdge(src, dst, "pad", air)
                                pads = pads + 1
                            end
                        end
                    end
                end
            end
        end
    end
    for _, group in pairs(zipGroups) do
        local lo, hi
        for _, part in ipairs(group) do
            if not lo or part.Position.Y < lo.Position.Y then lo = part end
            if not hi or part.Position.Y > hi.Position.Y then hi = part end
        end
        if lo and hi and lo ~= hi then
            local a = nearest(grid, bb, cell, hi.Position, 22, 14)
            local b = nearest(grid, bb, cell, lo.Position, 22, 14)
            if a and b and a.id ~= b.id then
                addEdge(a, b, "zip", (hi.Position - lo.Position).Magnitude / prof.zipSpeed)
                zips = zips + 1
            end
        end
        breathe()
    end
    return zips, pads
end

------------------------------------------------------------------
-- 5) A* ueber den Graphen. Kosten in Sekunden, Heuristik ebenso.
------------------------------------------------------------------
function NAV.findPath(startPos, goalPos)
    local G = NAV.graph
    if not G then return nil, "kein Graph" end
    local s = nearest(G.grid, G.bb, G.cell, startPos, 30, 14)
    local t = nearest(G.grid, G.bb, G.cell, goalPos, 30, 18)
    if not s then return nil, "Start nicht im Graph" end
    if not t then return nil, "Ziel nicht im Graph" end
    if s.id == t.id then return { s }, nil end

    local nodes = G.nodes
    local speed = G.prof.speed
    local function h(n)
        return (n.p - t.p).Magnitude / speed
    end

    local gScore, came, closed = {}, {}, {}
    gScore[s.id] = 0
    -- einfacher binaerer Heap
    local heap, hn = {}, 0
    local function push(id, f)
        hn = hn + 1 ; heap[hn] = { id = id, f = f }
        local i = hn
        while i > 1 do
            local p = math.floor(i/2)
            if heap[p].f <= heap[i].f then break end
            heap[p], heap[i] = heap[i], heap[p] ; i = p
        end
    end
    local function pop()
        if hn == 0 then return nil end
        local top = heap[1]
        heap[1] = heap[hn] ; heap[hn] = nil ; hn = hn - 1
        local i = 1
        while true do
            local l, r, m = i*2, i*2+1, i
            if l <= hn and heap[l].f < heap[m].f then m = l end
            if r <= hn and heap[r].f < heap[m].f then m = r end
            if m == i then break end
            heap[m], heap[i] = heap[i], heap[m] ; i = m
        end
        return top.id
    end

    push(s.id, h(s))
    local visited = 0
    while true do
        local cur = pop()
        if not cur then break end
        if not closed[cur] then
            closed[cur] = true
            visited = visited + 1
            if cur == t.id then
                local path, at = {}, cur
                while at do
                    table.insert(path, 1, { node = nodes[at], kind = came[at] and came[at].k or "walk" })
                    at = came[at] and came[at].from or nil
                end
                return path, nil, visited
            end
            local n = nodes[cur]
            for _, e in ipairs(n.e) do
                local ng = gScore[cur] + e.c
                if not gScore[e.to] or ng < gScore[e.to] then
                    gScore[e.to] = ng
                    came[e.to] = { from = cur, k = e.k }
                    push(e.to, ng + h(nodes[e.to]))
                end
            end
        end
    end
    return nil, "kein Weg im Graphen", visited
end

------------------------------------------------------------------
-- 6) Backen
------------------------------------------------------------------
function NAV.bake(onProgress)
    local mapRoot = currentMap()
    if not mapRoot then return nil, "keine Map" end
    refreshFilter()
    local prof = profile()
    local hrp = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
    local bb = bounds(mapRoot, hrp and hrp.Position.Y or nil)
    if not bb then return nil, "Map zu klein" end

    local t0 = os.clock()
    local nodes, grid, cell = sampleNodes(bb, onProgress)
    if #nodes < 50 then return nil, "zu wenige Knoten: " .. #nodes end

    local stats = {}
    stats.walk = buildWalk(nodes, grid, prof)
    stats.climb = buildClimb(nodes, grid, bb, cell, mapRoot, prof)
    local j, d, rim = buildJumpDrop(nodes, grid, cell, prof)
    stats.jump, stats.drop, stats.rim = j, d, #rim
    stats.wallrun = buildWallrun(nodes, grid, bb, cell, rim, prof)
    stats.zip, stats.pad = buildHelpers(nodes, grid, bb, cell, mapRoot, prof)

    NAV.graph = { nodes = nodes, grid = grid, cell = cell, bb = bb,
                  prof = prof, map = mapRoot.Name, stats = stats }
    stats.nodes = #nodes
    stats.secs = os.clock() - t0
    return NAV.graph
end

function NAV.save()
    local G = NAV.graph
    if not G then return false end
    local function r1(v) return math.floor(v*10+0.5)/10 end
    local out = { map = G.map, cell = G.cell, version = 2,
                  bb = { r1(G.bb.min.X), r1(G.bb.min.Y), r1(G.bb.min.Z),
                         r1(G.bb.max.X), r1(G.bb.max.Y), r1(G.bb.max.Z) },
                  nodes = {}, stats = G.stats }
    for _, n in ipairs(G.nodes) do
        local es = {}
        for _, e in ipairs(n.e) do es[#es+1] = { e.to, e.k, r1(e.c) } end
        out.nodes[#out.nodes+1] = { r1(n.p.X), r1(n.p.Y), r1(n.p.Z), es }
    end
    local ok = pcall(function()
        writefile("utg_nav_" .. G.map:gsub("[^%w_%-]", "_") .. ".json",
                  HttpService:JSONEncode(out))
    end)
    return ok
end

return NAV
