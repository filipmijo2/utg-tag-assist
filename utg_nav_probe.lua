--[[ ============================================================
     UTG NAV PROBE  —  Untitled Tag Game (PlaceId 14044547200)

     Vermisst die aktuelle Map und beantwortet EINE Frage:
     wie viel von der Map ist mit Roblox' Wegfindung ueberhaupt
     erreichbar, und wo muessten eigene Verbindungen (Leiter,
     Zipline, Jumppad, Sprung, Absprung) gesetzt werden.

     NUR MESSEN. Bewegt den Charakter nicht, feuert keine Remotes,
     hookt nichts. Laeuft von allein los, bei jedem Mapwechsel neu.

     ERGEBNIS  ->  utg_nav_<Map>.txt   (lesbarer Bericht)
                   utg_nav_<Map>.json  (der Graph, fuer spaeter)
     Der Bericht liegt am Ende ausserdem in der Zwischenablage.
     ============================================================ ]]

------------------------------------------------------------------
-- 0) Altes Exemplar sauber beenden
------------------------------------------------------------------
if getgenv().__UTG_NAV and getgenv().__UTG_NAV.cleanup then
    pcall(getgenv().__UTG_NAV.cleanup)
end
local ENV = {}
getgenv().__UTG_NAV = ENV

local Players      = game:GetService("Players")
local RunService   = game:GetService("RunService")
local HttpService  = game:GetService("HttpService")
local PathfindingService = game:GetService("PathfindingService")
local LP = Players.LocalPlayer

local conns = {}
local running = true

------------------------------------------------------------------
-- 1) Konfiguration
------------------------------------------------------------------
local CFG = {
    targetGrid   = 62,    -- Rasteraufloesung pro Achse (Zellen)
    minCell      = 4,     -- Zellweite nie feiner als das (Studs)
    maxCell      = 11,
    maxLevels    = 12,    -- wie viele Stockwerke pro Saeule maximal
    agentHeight  = 5.5,   -- Kopffreiheit, die ein Knoten braucht
    maxSlope     = 50,    -- steiler = keine Standflaeche (Grad)
    stepUp       = 3.0,   -- Hoehenunterschied, den Gehen noch schafft
    nodeCap      = 20000, -- Notbremse. 7000 war zu knapp: FactionAction hat
                          -- das Limit gerissen, der Rest der Map fiel weg.
    pfSamples    = 45,    -- Stichproben fuer den Wegfindungs-Test
    rayBudget    = 500,   -- Raycasts pro Frame, dann eine Pause (gegen Ruckeln)
}

------------------------------------------------------------------
-- 2) Ausgabe: Puffer, Datei, Zwischenablage, Status-Anzeige
--    Nie pro Ereignis schreiben — das killt den Executor.
------------------------------------------------------------------
local report = {}
local function say(fmt, ...)
    local line = select("#", ...) > 0 and string.format(fmt, ...) or fmt
    report[#report + 1] = line
    print("[NAV] " .. line)
end

local canWrite = (type(writefile) == "function")
local function saveFile(name, body)
    if not canWrite then return false end
    local ok = pcall(writefile, name, body)
    return ok
end

local gui, statusLabel, detailLabel
local function buildGui()
    local ok = pcall(function()
        local parent = (type(gethui) == "function" and gethui()) or game:GetService("CoreGui")
        gui = Instance.new("ScreenGui")
        gui.Name = "UTG_NavProbe"
        gui.ResetOnSpawn = false
        gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
        gui.Parent = parent

        local frame = Instance.new("Frame")
        frame.Size = UDim2.new(0, 340, 0, 96)
        frame.Position = UDim2.new(0.5, -170, 0, 12)
        frame.BackgroundColor3 = Color3.fromRGB(16, 18, 24)
        frame.BackgroundTransparency = 0.12
        frame.BorderSizePixel = 0
        frame.Parent = gui
        Instance.new("UICorner").Parent = frame

        local title = Instance.new("TextLabel")
        title.Size = UDim2.new(1, -16, 0, 22)
        title.Position = UDim2.new(0, 8, 0, 6)
        title.BackgroundTransparency = 1
        title.Font = Enum.Font.GothamBold
        title.TextSize = 14
        title.TextColor3 = Color3.fromRGB(150, 220, 255)
        title.TextXAlignment = Enum.TextXAlignment.Left
        title.Text = "UTG Nav-Probe"
        title.Parent = frame

        statusLabel = Instance.new("TextLabel")
        statusLabel.Size = UDim2.new(1, -16, 0, 20)
        statusLabel.Position = UDim2.new(0, 8, 0, 30)
        statusLabel.BackgroundTransparency = 1
        statusLabel.Font = Enum.Font.Gotham
        statusLabel.TextSize = 13
        statusLabel.TextColor3 = Color3.fromRGB(235, 235, 235)
        statusLabel.TextXAlignment = Enum.TextXAlignment.Left
        statusLabel.Text = "warte auf Map ..."
        statusLabel.Parent = frame

        detailLabel = Instance.new("TextLabel")
        detailLabel.Size = UDim2.new(1, -16, 0, 40)
        detailLabel.Position = UDim2.new(0, 8, 0, 50)
        detailLabel.BackgroundTransparency = 1
        detailLabel.Font = Enum.Font.Gotham
        detailLabel.TextSize = 12
        detailLabel.TextWrapped = true
        detailLabel.TextColor3 = Color3.fromRGB(170, 170, 180)
        detailLabel.TextXAlignment = Enum.TextXAlignment.Left
        detailLabel.TextYAlignment = Enum.TextYAlignment.Top
        detailLabel.Text = ""
        detailLabel.Parent = frame
    end)
    if not ok then gui = nil end
end

local function status(main, detail)
    if statusLabel then pcall(function() statusLabel.Text = main end) end
    if detailLabel and detail then pcall(function() detailLabel.Text = detail end) end
end

------------------------------------------------------------------
-- 3) Raycasts
--    RespectCanCollide ist Pflicht: sonst gelten unsichtbare
--    Zonen-Volumen als Wand und die halbe Map faellt weg.
------------------------------------------------------------------
local rp = RaycastParams.new()
rp.FilterType = Enum.RaycastFilterType.Exclude
rp.RespectCanCollide = true
rp.IgnoreWater = false

local function refreshFilter()
    local ignore = { workspace.CurrentCamera }
    for _, pl in ipairs(Players:GetPlayers()) do
        if pl.Character then ignore[#ignore + 1] = pl.Character end
    end
    for _, n in ipairs({ "EmotePuppets", "ragdolls", "bullets", "Displayed", "coins", "Debris" }) do
        local f = workspace:FindFirstChild(n)
        if f then ignore[#ignore + 1] = f end
    end
    rp.FilterDescendantsInstances = ignore
end

local rayCount, frameRays = 0, 0
local function cast(origin, dir)
    rayCount = rayCount + 1
    frameRays = frameRays + 1
    return workspace:Raycast(origin, dir, rp)
end
-- gibt die Kontrolle zurueck, bevor der Client haengt
local function breathe()
    if frameRays >= CFG.rayBudget then
        frameRays = 0
        RunService.Heartbeat:Wait()
        return true
    end
    return false
end

------------------------------------------------------------------
-- 4) Map und ihre Ausdehnung
--    Extremwerte sind unbrauchbar (Skybox, Deko weit draussen) —
--    deshalb Perzentile ueber die Teilepositionen.
------------------------------------------------------------------
local function currentMap()
    local cm = workspace:FindFirstChild("CurrentMap")
    return cm and cm:GetChildren()[1] or nil
end

local function percentile(sorted, p)
    if #sorted == 0 then return 0 end
    local i = math.clamp(math.floor(#sorted * p + 0.5), 1, #sorted)
    return sorted[i]
end

local function measureMap(mapRoot, playerY)
    local xs, ys, zs = {}, {}, {}
    local parts = 0
    for _, d in ipairs(mapRoot:GetDescendants()) do
        if d:IsA("BasePart") and d.CanCollide then
            parts = parts + 1
            local p = d.Position
            xs[#xs + 1] = p.X
            ys[#ys + 1] = p.Y
            zs[#zs + 1] = p.Z
        end
    end
    if parts < 20 then return nil end
    table.sort(xs) table.sort(ys) table.sort(zs)
    local minX, maxX = percentile(xs, 0.02), percentile(xs, 0.98)
    local minZ, maxZ = percentile(zs, 0.02), percentile(zs, 0.98)
    local minY, maxY = percentile(ys, 0.01), percentile(ys, 0.99)
    -- an der Spielerebene ausrichten: was 250 Studs darueber liegt, ist
    -- Dachkonstruktion und kein Spielfeld
    if playerY then
        minY = math.min(minY, playerY - 40)
        maxY = math.min(maxY + 30, playerY + 260)
    end
    return {
        min = Vector3.new(minX, minY, minZ),
        max = Vector3.new(maxX, maxY, maxZ),
        parts = parts,
    }
end

------------------------------------------------------------------
-- 5) PHASE A — Saeulen-Abtastung
--    Pro Rasterzelle wird die ganze Hoehe durchstochen, nicht nur
--    die oberste Flaeche. Genau daran scheitert der alte Ansatz:
--    von oben nach unten trifft man das Dach und sonst nichts.
------------------------------------------------------------------
local function sampleNodes(bounds)
    local spanX = math.max(bounds.max.X - bounds.min.X, 1)
    local spanZ = math.max(bounds.max.Z - bounds.min.Z, 1)
    local cell = math.clamp(math.max(spanX, spanZ) / CFG.targetGrid, CFG.minCell, CFG.maxCell)
    local nx = math.floor(spanX / cell)
    local nz = math.floor(spanZ / cell)

    local nodes = {}          -- { pos = Vector3, ix, iz, island = nil }
    local grid  = {}          -- "ix,iz" -> { node, node, ... }
    local lowClearance = 0
    local topY = bounds.max.Y + 8
    local depth = (bounds.max.Y - bounds.min.Y) + 16
    local cosLimit = math.cos(math.rad(CFG.maxSlope))

    for ix = 0, nx do
        for iz = 0, nz do
            local x = bounds.min.X + ix * cell
            local z = bounds.min.Z + iz * cell
            local y = topY
            local guard = 0
            local prevY = nil
            while guard < CFG.maxLevels do
                guard = guard + 1
                if y <= bounds.min.Y then break end
                local hit = cast(Vector3.new(x, y, z), Vector3.new(0, -(y - bounds.min.Y + 4), 0))
                if not hit then break end
                local hy = hit.Position.Y
                -- Fortschritt erzwingen, sonst bohrt man ewig im selben Block
                if prevY and hy > prevY - 0.4 then
                    y = hy - 4.0
                else
                    y = hy - 1.0
                end
                prevY = hy

                if hit.Normal.Y >= cosLimit then
                    local foot = hit.Position + Vector3.new(0, 0.5, 0)
                    local head = cast(foot, Vector3.new(0, CFG.agentHeight, 0))
                    if head then
                        lowClearance = lowClearance + 1
                    else
                        local node = {
                            pos = foot,
                            ix = ix, iz = iz,
                            mat = hit.Material,
                            inst = hit.Instance,
                        }
                        nodes[#nodes + 1] = node
                        local key = ix .. "," .. iz
                        local bucket = grid[key]
                        if not bucket then bucket = {} grid[key] = bucket end
                        bucket[#bucket + 1] = node
                    end
                end
                if #nodes >= CFG.nodeCap then break end
            end
            if #nodes >= CFG.nodeCap then break end
            breathe()
        end
        if #nodes >= CFG.nodeCap then break end
        if ix % 4 == 0 then
            status("Phase 1/4: Map abtasten",
                   string.format("%d%%  ·  %d Standflaechen gefunden",
                                 math.floor(ix / math.max(nx, 1) * 100), #nodes))
        end
    end
    return nodes, grid, cell, lowClearance
end

------------------------------------------------------------------
-- 6) PHASE B — Inseln
--    Zwei Knoten haengen zusammen, wenn man zwischen ihnen gehen
--    kann: kleiner Hoehenunterschied und freie Sicht auf Huefthoehe.
--    Die Zusammenhangskomponenten sind die "Inseln" der Map.
------------------------------------------------------------------
local function findIslands(nodes, grid, cell)
    local parent = {}
    for i = 1, #nodes do parent[i] = i nodes[i].id = i end
    local function root(a)
        while parent[a] ~= a do parent[a] = parent[parent[a]] a = parent[a] end
        return a
    end
    local function union(a, b)
        local ra, rb = root(a), root(b)
        if ra ~= rb then parent[ra] = rb end
    end

    -- nur halbe Nachbarschaft, die andere Haelfte ist symmetrisch
    local dirs = { {1, 0}, {0, 1}, {1, 1}, {1, -1} }
    local walkEdges = 0
    for i, node in ipairs(nodes) do
        for _, d in ipairs(dirs) do
            local bucket = grid[(node.ix + d[1]) .. "," .. (node.iz + d[2])]
            if bucket then
                for _, other in ipairs(bucket) do
                    local dy = other.pos.Y - node.pos.Y
                    if math.abs(dy) <= CFG.stepUp and root(i) ~= root(other.id) then
                        -- Sichtlinie auf Huefthoehe: trennt Boeden durch Waende
                        local a = node.pos + Vector3.new(0, 2.2, 0)
                        local b = other.pos + Vector3.new(0, 2.2, 0)
                        local blocked = cast(a, b - a)
                        if not blocked then
                            union(i, other.id)
                            walkEdges = walkEdges + 1
                        end
                    end
                end
            end
        end
        if i % 400 == 0 then
            status("Phase 2/4: Ebenen verbinden",
                   string.format("%d%%  ·  %d begehbare Kanten",
                                 math.floor(i / #nodes * 100), walkEdges))
        end
        breathe()
    end

    local islands, byRoot = {}, {}
    for i, node in ipairs(nodes) do
        local r = root(i)
        local isl = byRoot[r]
        if not isl then
            isl = { id = #islands + 1, nodes = {}, minY = math.huge, maxY = -math.huge,
                    sum = Vector3.zero }
            islands[#islands + 1] = isl
            byRoot[r] = isl
        end
        node.island = isl.id
        isl.nodes[#isl.nodes + 1] = node
        isl.minY = math.min(isl.minY, node.pos.Y)
        isl.maxY = math.max(isl.maxY, node.pos.Y)
        isl.sum = isl.sum + node.pos
    end
    for _, isl in ipairs(islands) do
        isl.center = isl.sum / #isl.nodes
        isl.sum = nil
    end
    table.sort(islands, function(a, b) return #a.nodes > #b.nodes end)
    -- nach der Sortierung stimmen die ids nicht mehr -> neu vergeben
    for newId, isl in ipairs(islands) do
        isl.id = newId
        for _, n in ipairs(isl.nodes) do n.island = newId end
    end
    return islands, walkEdges
end

------------------------------------------------------------------
-- 7) PHASE C — Verbindungen zwischen den Inseln
--    Das ist der eigentliche Punkt: was der Navmesh nicht kennt.
------------------------------------------------------------------
-- Raeumlicher Index ueber die XZ-Zellen. Ohne den wird jede Suche eine
-- Schleife ueber alle 7000 Knoten — bei 200 Leitern friert der Client ein.
local INDEX = { grid = nil, bounds = nil, cell = 1 }
local function cellOf(pos)
    return math.floor((pos.X - INDEX.bounds.min.X) / INDEX.cell + 0.5),
           math.floor((pos.Z - INDEX.bounds.min.Z) / INDEX.cell + 0.5)
end

local function nearestNode(pos, maxDist, maxDy)
    if not INDEX.grid then return nil end
    local ix, iz = cellOf(pos)
    local span = math.ceil(maxDist / INDEX.cell)
    local best, bestD
    for dx = -span, span do
        for dz = -span, span do
            local bucket = INDEX.grid[(ix + dx) .. "," .. (iz + dz)]
            if bucket then
                for _, n in ipairs(bucket) do
                    local d = (n.pos - pos).Magnitude
                    if d <= maxDist and (not maxDy or math.abs(n.pos.Y - pos.Y) <= maxDy) then
                        if not bestD or d < bestD then best, bestD = n, d end
                    end
                end
            end
        end
    end
    return best
end

local function jumpProfile()
    local char = LP.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    local g = workspace.Gravity
    local vy
    if hum then
        if hum.UseJumpPower then
            vy = hum.JumpPower
        else
            vy = math.sqrt(2 * g * math.max(hum.JumpHeight, 1))
        end
    else
        vy = 50
    end
    -- gemessene Spitzengeschwindigkeit des Bots, nicht die Standard-16
    local speed = 32
    local air = 2 * vy / g
    return {
        vy = vy, g = g, speed = speed, airTime = air,
        reach = speed * air,           -- flache Sprungweite
        rise  = (vy * vy) / (2 * g),   -- erreichbare Hoehe
    }
end

-- Fliegt eine Wurfparabel frei durch? (grobe Abtastung, 10 Schritte)
local function arcClear(from, to, jp)
    local flat = (to - from) * Vector3.new(1, 0, 1)
    local dist = flat.Magnitude
    if dist < 0.5 then return false end
    local t = dist / jp.speed
    if t > jp.airTime * 1.15 then return false end
    local dy = to.Y - from.Y
    -- benoetigte Startgeschwindigkeit nach oben fuer diese Wurfweite
    local vy = (dy + 0.5 * jp.g * t * t) / t
    if vy > jp.vy * 1.02 then return false end
    local dirUnit = flat.Unit
    local prev = from + Vector3.new(0, 1.5, 0)
    for s = 1, 10 do
        local tt = t * (s / 10)
        local p = from + dirUnit * (jp.speed * tt)
                       + Vector3.new(0, vy * tt - 0.5 * jp.g * tt * tt + 1.5, 0)
        if cast(prev, p - prev) then return false end
        prev = p
    end
    return true
end

local function findLinks(nodes, islands, jp, mapRoot)
    local links = {}
    local function addLink(kind, a, b, cost, note)
        if not a or not b then return end
        if a.island == b.island then return end
        links[#links + 1] = {
            kind = kind, from = a.island, to = b.island,
            fromPos = a.pos, toPos = b.pos, cost = cost, note = note,
        }
    end

    -- --- Bewegungshilfen der Map einsammeln (gleiche Attribute wie im Tool)
    local trusses, zips, pads, rails, bars = {}, {}, {}, {}, {}
    for _, d in ipairs(mapRoot:GetDescendants()) do
        if d:IsA("TrussPart") then
            trusses[#trusses + 1] = d
        elseif d:IsA("BasePart") then
            if d.Parent and d.Parent:GetAttribute("Zipline") then
                zips[#zips + 1] = d
            elseif d:GetAttribute("BounceAmount") or d:GetAttribute("RelativeBounceAmount") then
                pads[#pads + 1] = d
            elseif d:GetAttribute("RailGrind") then
                rails[#rails + 1] = d
            elseif d:GetAttribute("SwingBar") then
                bars[#bars + 1] = d
            end
        end
    end

    -- --- Leitern: Fuss und Kopf mit der jeweils naechsten Insel verbinden
    for _, t in ipairs(trusses) do
        local half = t.Size.Y * 0.5
        local foot = t.Position - Vector3.new(0, half, 0)
        local head = t.Position + Vector3.new(0, half, 0)
        local a = nearestNode(foot, 9, 6)
        local b = nearestNode(head, 9, 6)
        -- Klettern ist langsam: Zeitkosten ueber die Hoehe
        addLink("truss", a, b, (t.Size.Y / 8) + 0.6, t.Name)
        breathe()
    end

    -- --- Ziplines: Teile pro Elterngruppe zu einer Strecke zusammenfassen
    local zipGroups = {}
    for _, z in ipairs(zips) do
        local key = z.Parent
        local g = zipGroups[key]
        if not g then g = {} zipGroups[key] = g end
        g[#g + 1] = z
    end
    for _, group in pairs(zipGroups) do
        local lo, hi
        for _, part in ipairs(group) do
            if not lo or part.Position.Y < lo.Position.Y then lo = part end
            if not hi or part.Position.Y > hi.Position.Y then hi = part end
        end
        if lo and hi and lo ~= hi then
            local a = nearestNode(hi.Position, 22, 14)
            local b = nearestNode(lo.Position, 22, 14)
            local dist = (hi.Position - lo.Position).Magnitude
            addLink("zipline", a, b, dist / 40, "Zipline")
        end
        breathe()
    end

    -- --- Jumppads: Steighoehe aus dem Attribut, Landung in 8 Richtungen suchen
    for _, pad in ipairs(pads) do
        local amount = pad:GetAttribute("BounceAmount") or pad:GetAttribute("RelativeBounceAmount") or 0
        if type(amount) == "number" and amount > 0 then
            local rise = (amount * amount) / (2 * jp.g)
            local air  = 2 * amount / jp.g
            local reach = jp.speed * air
            local src = nearestNode(pad.Position + Vector3.new(0, pad.Size.Y * 0.5, 0), 10, 8)
            if src then
                for k = 0, 7 do
                    local ang = k * math.pi / 4
                    local landing = pad.Position + Vector3.new(math.cos(ang) * reach * 0.5,
                                                              rise * 0.8,
                                                              math.sin(ang) * reach * 0.5)
                    local dst = nearestNode(landing, 14, 12)
                    if dst then addLink("jumppad", src, dst, air, string.format("Pad %.0f", amount)) end
                end
            end
        end
        breathe()
    end

    -- --- Freie Spruenge und Absprünge zwischen Inselraendern
    -- Nur Randknoten betrachten: ein Knoten mitten auf einer Flaeche
    -- kann nichts verbinden, was sein Rand nicht auch verbindet.
    -- Randknoten: bei denen mindestens eine Nachbarzelle keinen Knoten
    -- derselben Insel hat. Ein Punkt mitten auf einer Flaeche kann nichts
    -- verbinden, was sein Rand nicht auch verbindet.
    local rim, rimGrid = {}, {}
    local sides = { {1, 0}, {-1, 0}, {0, 1}, {0, -1} }
    for _, isl in ipairs(islands) do
        if #isl.nodes >= 3 then
            for _, n in ipairs(isl.nodes) do
                local isEdge = false
                for _, d in ipairs(sides) do
                    local bucket = INDEX.grid[(n.ix + d[1]) .. "," .. (n.iz + d[2])]
                    local found = false
                    if bucket then
                        for _, o in ipairs(bucket) do
                            if o.island == n.island
                               and math.abs(o.pos.Y - n.pos.Y) <= CFG.stepUp then
                                found = true break
                            end
                        end
                    end
                    if not found then isEdge = true break end
                end
                if isEdge then
                    rim[#rim + 1] = n
                    local key = n.ix .. "," .. n.iz
                    local b = rimGrid[key]
                    if not b then b = {} rimGrid[key] = b end
                    b[#b + 1] = n
                end
            end
        end
    end

    local seenPair, triedPair = {}, {}
    local jumpReach = jp.reach * 0.9
    local span = math.ceil(jumpReach / INDEX.cell)
    for i, a in ipairs(rim) do
        for dx = -span, span do
            for dz = -span, span do
                local bucket = rimGrid[(a.ix + dx) .. "," .. (a.iz + dz)]
                if bucket then
                    for _, b in ipairs(bucket) do
                        if a.island ~= b.island then
                            local pairKey = a.island < b.island
                                and (a.island .. ">" .. b.island)
                                or  (b.island .. ">" .. a.island)
                            -- pro Inselpaar reichen ein paar Verbindungen, und
                            -- aussichtslose Paare nicht endlos durchrechnen
                            if (seenPair[pairKey] or 0) < 3
                               and (triedPair[pairKey] or 0) < 12 then
                                local flat = ((b.pos - a.pos) * Vector3.new(1, 0, 1)).Magnitude
                                local dy = b.pos.Y - a.pos.Y
                                if flat <= jumpReach then
                                    triedPair[pairKey] = (triedPair[pairKey] or 0) + 1
                                    if math.abs(dy) <= jp.rise and arcClear(a.pos, b.pos, jp) then
                                        seenPair[pairKey] = (seenPair[pairKey] or 0) + 1
                                        addLink("jump", a, b, flat / jp.speed + 0.2, nil)
                                    elseif dy < -jp.rise and flat <= 12 then
                                        -- deutlich tiefer: freier Fall, immer moeglich
                                        local down = cast(a.pos + Vector3.new(0, 1, 0),
                                                          (b.pos - a.pos) + Vector3.new(0, -2, 0))
                                        if not down or (down.Position - b.pos).Magnitude < 6 then
                                            seenPair[pairKey] = (seenPair[pairKey] or 0) + 1
                                            addLink("drop", a, b, math.sqrt(2 * math.abs(dy) / jp.g), nil)
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
        breathe()
        if i % 60 == 0 then
            status("Phase 3/4: Verbindungen suchen",
                   string.format("%d%%  ·  %d Verbindungen", math.floor(i / #rim * 100), #links))
        end
    end

    -- --- Wandflaechen inventarisieren (Wallride-Ketten, noch nicht verlinkt)
    local wallRim = 0
    for i = 1, #rim, 3 do
        local n = rim[i]
        for k = 0, 3 do
            local ang = k * math.pi / 2
            local dir = Vector3.new(math.cos(ang) * 4, 0, math.sin(ang) * 4)
            local h = cast(n.pos + Vector3.new(0, 3, 0), dir)
            if h and math.abs(h.Normal.Y) < 0.25 then wallRim = wallRim + 1 break end
        end
        breathe()
    end

    return links, {
        trusses = #trusses, zips = #zips, pads = #pads,
        rails = #rails, bars = #bars, wallRim = wallRim, rimNodes = #rim,
    }
end

------------------------------------------------------------------
-- 8) PHASE D — Realitaetstest gegen PathfindingService
--    Beweist (oder widerlegt) die Diagnose: wie viel erreicht die
--    eingebaute Wegfindung wirklich?
------------------------------------------------------------------
local function computePath(from, to, radius)
    local ok, res = pcall(function()
        local path = PathfindingService:CreatePath({
            AgentRadius = radius or 2,
            AgentHeight = 5,
            AgentCanJump = true,
            AgentCanClimb = true,
            AgentMaxSlope = 89,
            WaypointSpacing = 4,
        })
        path:ComputeAsync(from, to)
        if path.Status == Enum.PathStatus.Success then
            local wps = path:GetWaypoints()
            if #wps > 1 then
                local len, prev = 0, nil
                local jumps = 0
                for _, w in ipairs(wps) do
                    if prev then len = len + (w.Position - prev).Magnitude end
                    if w.Action == Enum.PathWaypointAction.Jump then jumps = jumps + 1 end
                    prev = w.Position
                end
                return { len = len, count = #wps, jumps = jumps }
            end
        end
        return nil
    end)
    return ok and res or nil
end

local function pathfindingCheck(islands, nodes)
    local origin = nil
    local hrp = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
    if hrp then origin = nearestNode(hrp.Position, 40) end
    origin = origin or (islands[1] and islands[1].nodes[1])
    if not origin then return nil end

    local res = { origin = origin, reached = 0, failed = 0, detour = {},
                  perIsland = {}, sampled = 0 }

    -- a) Erreichbarkeit jeder nennenswerten Insel von unserem Standort aus
    for _, isl in ipairs(islands) do
        if #isl.nodes >= 4 and isl.id <= 24 then
            local target = isl.nodes[math.ceil(#isl.nodes / 2)]
            local r = computePath(origin.pos, target.pos, 2) or computePath(origin.pos, target.pos, 1)
            res.perIsland[#res.perIsland + 1] = {
                island = isl.id, size = #isl.nodes,
                y = isl.center.Y, ok = r ~= nil,
                detour = r and (r.len / math.max((target.pos - origin.pos).Magnitude, 1)) or nil,
                jumps = r and r.jumps or 0,
            }
            if r then res.reached = res.reached + 1 else res.failed = res.failed + 1 end
            status("Phase 4/4: Wegfindung testen",
                   string.format("Insel %d von %d", #res.perIsland, math.min(#islands, 24)))
        end
    end

    -- b) Stichproben quer ueber die Map, unabhaengig von Inseln
    local okCount, failCount, detourSum = 0, 0, 0
    for _ = 1, CFG.pfSamples do
        local a = nodes[math.random(1, #nodes)]
        local b = nodes[math.random(1, #nodes)]
        local direct = (b.pos - a.pos).Magnitude
        if direct > 30 then
            res.sampled = res.sampled + 1
            local r = computePath(a.pos, b.pos, 2)
            if r then
                okCount = okCount + 1
                detourSum = detourSum + (r.len / direct)
            else
                failCount = failCount + 1
            end
        end
    end
    res.sampleOk, res.sampleFail = okCount, failCount
    res.avgDetour = okCount > 0 and (detourSum / okCount) or nil
    return res
end

------------------------------------------------------------------
-- 9) Bericht und Graph schreiben
------------------------------------------------------------------
local function writeReport(mapName, bounds, nodes, islands, cell, lowClearance,
                           walkEdges, links, inv, pf, seconds)
    report = {}
    say("================================================")
    say("UTG NAV PROBE  —  Map: %s", mapName)
    say("================================================")
    say("Messdauer %.1f s, %d Raycasts, Rasterweite %.1f Studs", seconds, rayCount, cell)
    say("Map-Ausdehnung %.0f x %.0f Studs, Hoehe %.0f..%.0f",
        bounds.max.X - bounds.min.X, bounds.max.Z - bounds.min.Z, bounds.min.Y, bounds.max.Y)
    say("")
    say("-- STANDFLAECHEN --------------------------------")
    say("%d begehbare Punkte, %d verworfen wegen zu wenig Kopffreiheit", #nodes, lowClearance)
    say("%d begehbare Kanten zwischen Nachbarpunkten", walkEdges)
    say("")
    say("-- INSELN (zusammenhaengende Ebenen) ------------")
    say("%d Inseln insgesamt", #islands)
    local big = 0
    for _, isl in ipairs(islands) do if #isl.nodes >= 4 then big = big + 1 end end
    say("davon %d mit mindestens 4 Punkten (der Rest ist Rauschen)", big)
    local shown = 0
    for _, isl in ipairs(islands) do
        if #isl.nodes >= 4 and shown < 15 then
            shown = shown + 1
            say("   Insel %2d: %4d Punkte, Hoehe %.0f..%.0f, Mitte %d/%d",
                isl.id, #isl.nodes, isl.minY, isl.maxY,
                math.floor(isl.center.X), math.floor(isl.center.Z))
        end
    end
    local top = islands[1] and #islands[1].nodes or 0
    say("groesste Insel deckt %.0f%% aller Punkte ab", top / math.max(#nodes, 1) * 100)
    say("")
    say("-- BEWEGUNGSHILFEN IN DER MAP -------------------")
    say("%d Leiterteile, %d Zipline-Teile, %d Jumppads, %d Rails, %d SwingBars",
        inv.trusses, inv.zips, inv.pads, inv.rails, inv.bars)
    say("%d von %d Randpunkten haben eine kletterbare Wand daneben (Wallride-Potenzial)",
        inv.wallRim, math.ceil(inv.rimNodes / 3))
    say("")
    say("-- GEFUNDENE VERBINDUNGEN ZWISCHEN INSELN -------")
    local byKind = {}
    for _, l in ipairs(links) do byKind[l.kind] = (byKind[l.kind] or 0) + 1 end
    say("%d Verbindungen insgesamt", #links)
    for _, k in ipairs({ "truss", "zipline", "jumppad", "jump", "drop" }) do
        say("   %-8s %d", k, byKind[k] or 0)
    end
    -- wie viele Inseln haengen nach dem Verlinken zusammen?
    local par = {}
    for _, isl in ipairs(islands) do par[isl.id] = isl.id end
    local function rt(a) while par[a] ~= a do par[a] = par[par[a]] a = par[a] end return a end
    for _, l in ipairs(links) do
        local ra, rb = rt(l.from), rt(l.to)
        if ra ~= rb then par[ra] = rb end
    end
    local comps = {}
    local biggestComp, compSize = nil, {}
    for _, isl in ipairs(islands) do
        if #isl.nodes >= 4 then
            local r = rt(isl.id)
            comps[r] = true
            compSize[r] = (compSize[r] or 0) + #isl.nodes
        end
    end
    local compCount = 0
    local bestSize = 0
    for r in pairs(comps) do
        compCount = compCount + 1
        if compSize[r] > bestSize then bestSize, biggestComp = compSize[r], r end
    end
    say("nach dem Verlinken bleiben %d getrennte Bereiche (vorher %d Inseln)", compCount, big)
    say("groesster verbundener Bereich: %.0f%% aller Punkte", bestSize / math.max(#nodes, 1) * 100)
    say("")
    say("-- REALITAETSTEST: ROBLOX-WEGFINDUNG ------------")
    if pf then
        say("Startpunkt: eigene Position, Hoehe %.0f", pf.origin.pos.Y)
        say("Inseln direkt anpfadbar: %d erreicht, %d gescheitert", pf.reached, pf.failed)
        for _, e in ipairs(pf.perIsland) do
            if e.ok then
                say("   Insel %2d (%4d Punkte, Hoehe %5.0f): OK, Umweg x%.2f, %d Spruenge",
                    e.island, e.size, e.y, e.detour or 0, e.jumps)
            else
                say("   Insel %2d (%4d Punkte, Hoehe %5.0f): KEIN PFAD",
                    e.island, e.size, e.y)
            end
        end
        say("Stichproben quer ueber die Map: %d von %d erfolgreich",
            pf.sampleOk, pf.sampleOk + pf.sampleFail)
        if pf.avgDetour then say("durchschnittlicher Umweg dabei: x%.2f der Luftlinie", pf.avgDetour) end
    else
        say("konnte nicht getestet werden (kein Charakter?)")
    end
    say("")
    say("-- FAZIT ----------------------------------------")
    if pf and (pf.reached + pf.failed) > 0 then
        local rate = pf.reached / (pf.reached + pf.failed)
        if rate < 0.6 then
            say("Die eingebaute Wegfindung erreicht nur %.0f%% der Ebenen dieser Map.", rate * 100)
            say("Eigener Verbindungsgraph ist noetig — die Kandidaten stehen oben.")
        elseif rate < 0.9 then
            say("Die eingebaute Wegfindung deckt %.0f%% der Ebenen ab, der Rest braucht", rate * 100)
            say("eigene Verbindungen (Leiter/Zipline/Pad/Sprung).")
        else
            say("Die eingebaute Wegfindung erreicht %.0f%% der Ebenen — das Problem liegt", rate * 100)
            say("dann eher im Abfahren der Wegpunkte als im Finden des Weges.")
        end
    end
    say("================================================")

    local body = table.concat(report, "\n")
    local safeName = mapName:gsub("[^%w_%- ]", "_")
    local wroteTxt = saveFile("utg_nav_" .. safeName .. ".txt", body)

    -- Graph als JSON, Positionen auf eine Nachkommastelle gerundet
    local wroteJson = false
    pcall(function()
        local function r1(v) return math.floor(v * 10 + 0.5) / 10 end
        local jIslands = {}
        for _, isl in ipairs(islands) do
            if #isl.nodes >= 4 then
                local pts = {}
                for _, n in ipairs(isl.nodes) do
                    pts[#pts + 1] = { r1(n.pos.X), r1(n.pos.Y), r1(n.pos.Z) }
                end
                jIslands[#jIslands + 1] = {
                    id = isl.id, size = #isl.nodes,
                    center = { r1(isl.center.X), r1(isl.center.Y), r1(isl.center.Z) },
                    minY = r1(isl.minY), maxY = r1(isl.maxY),
                    nodes = pts,
                }
            end
        end
        local jLinks = {}
        for _, l in ipairs(links) do
            jLinks[#jLinks + 1] = {
                kind = l.kind, from = l.from, to = l.to, cost = r1(l.cost or 1),
                a = { r1(l.fromPos.X), r1(l.fromPos.Y), r1(l.fromPos.Z) },
                b = { r1(l.toPos.X), r1(l.toPos.Y), r1(l.toPos.Z) },
            }
        end
        local blob = HttpService:JSONEncode({
            map = mapName, cell = cell, version = 1,
            islands = jIslands, links = jLinks, inventory = inv,
        })
        wroteJson = saveFile("utg_nav_" .. safeName .. ".json", blob)
    end)

    if type(setclipboard) == "function" then pcall(setclipboard, body) end
    return body, wroteTxt, wroteJson
end

------------------------------------------------------------------
-- 10) Ablauf fuer eine Map
------------------------------------------------------------------
local done = {}

local function probeMap(mapRoot)
    local mapName = mapRoot.Name
    local t0 = os.clock()
    rayCount, frameRays = 0, 0

    status("Phase 1/4: Map abtasten", mapName)
    refreshFilter()

    local hrp = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
    local bounds = measureMap(mapRoot, hrp and hrp.Position.Y or nil)
    if not bounds then
        status("Map zu klein / noch nicht geladen", mapName)
        return false
    end

    local nodes, grid, cell, lowClearance = sampleNodes(bounds)
    if #nodes < 40 then
        status("zu wenige Standflaechen gefunden", string.format("%d Punkte — Map geladen?", #nodes))
        return false
    end

    INDEX.grid, INDEX.bounds, INDEX.cell = grid, bounds, cell
    local islands, walkEdges = findIslands(nodes, grid, cell)
    local jp = jumpProfile()
    local links, inv = findLinks(nodes, islands, jp, mapRoot)

    status("Phase 4/4: Wegfindung testen", "das dauert ein paar Sekunden")
    local pf = pathfindingCheck(islands, nodes)

    local body, wroteTxt, wroteJson = writeReport(mapName, bounds, nodes, islands, cell,
        lowClearance, walkEdges, links, inv, pf, os.clock() - t0)

    local where = wroteTxt and ("utg_nav_" .. mapName .. ".txt") or "nur Zwischenablage"
    local rate = pf and (pf.reached + pf.failed) > 0
        and string.format("%.0f%% der Ebenen anpfadbar", pf.reached / (pf.reached + pf.failed) * 100)
        or ""
    status("FERTIG: " .. mapName,
           string.format("%d Punkte · %d Inseln · %d Verbindungen\n%s\nBericht: %s (auch in der Zwischenablage)",
                         #nodes, #islands, #links, rate, where))
    if not wroteJson then print("[NAV] JSON konnte nicht geschrieben werden") end
    return true
end

------------------------------------------------------------------
-- 11) Hauptschleife: wartet auf Maps, misst jede genau einmal
------------------------------------------------------------------
ENV.cleanup = function()
    running = false
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    conns = {}
    if gui then pcall(function() gui:Destroy() end) end
    gui = nil
end

buildGui()
say("Nav-Probe gestartet")

task.spawn(function()
    -- kurz warten, bis Charakter und Map wirklich stehen
    if not LP.Character then LP.CharacterAdded:Wait() end
    task.wait(3)
    while running do
        local ok, err = pcall(function()
            local mapRoot = currentMap()
            if mapRoot then
                -- Schluessel ist der Map-NAME: jede Map der Rotation wird
                -- genau einmal vermessen, egal wie oft sie drankommt.
                local key = mapRoot.Name
                if not done[key] then
                    done[key] = true
                    local success = probeMap(mapRoot)
                    if not success then
                        done[key] = nil     -- spaeter nochmal versuchen
                        task.wait(5)
                    end
                end
            else
                status("warte auf Map ...", "")
            end
        end)
        if not ok then
            status("Fehler", tostring(err))
            print("[NAV] Fehler: " .. tostring(err))
            task.wait(5)
        end
        task.wait(2)
    end
end)
