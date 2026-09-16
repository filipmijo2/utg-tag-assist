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
    -- Der Bake laeuft EINMAL pro Map und beeinflusst die Laufzeit nicht —
    -- die Maps sind ein fester Pool in Rotation. Also wird gruendlich
    -- abgetastet statt sparsam: mit Raster 8 zerriss der Graph an schmalen
    -- Rampen (ueber 45 Studs Hoehe nur 1 von 12 Zielen erreicht), mit 6
    -- waren immer noch 35 % der Innenraum-Knoten unverbunden.
    cell = 4,
    maxLevels = 14,      -- Stockwerke pro Saeule
    agentHeight = 5,
    maxSlope = 50,
    stepUp = 3.0,        -- Hoehe, die Gehen noch schafft
    wallChainMax = 25,   -- wie hoch eine Wallride-Kette traegt
    nodeCap = 120000,   -- TeapotTemple riss 45000 -> Bake brach mittendrin ab
    -- Raycasts pro Frame waehrend des Backens. 2500 waren zwar schnell
    -- fertig, haben das Spiel aber fuer die ganze Bakedauer unspielbar
    -- gemacht. Der Bake laeuft nur einmal pro Map und darf deshalb ruhig
    -- laenger brauchen — spuerbar ruckeln soll er nicht.
    rayBudget = 450,
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
    -- Rasterweite an die Mapgroesse koppeln. Feiner ist nicht besser:
    -- mit festem Raster 4 kam TeapotTemple auf 51244 Knoten, und A* fand
    -- danach nur noch 4 von 15 Wegen bei 111 ms — gegenueber 20/20 bei
    -- 30 ms und 18000 Knoten. Ziel sind daher rund 20000 Knoten.
    local area = math.max((bb.max.X - bb.min.X) * (bb.max.Z - bb.min.Z), 1)
    local cell = math.clamp(math.sqrt(area / 8000), CFG.cell, 9)
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
                    -- Kopffreiheit messen statt nur pruefen: enge Stellen
                    -- wurden bisher komplett verworfen, dort gab es also gar
                    -- keinen Weg. Durch solche Luecken kommt man aber per
                    -- Rolle durch, und der Bot blieb genau daran haengen.
                    local ceil = cast(foot, Vector3.new(0, CFG.agentHeight, 0))
                    local low = false
                    if ceil then
                        local h = ceil.Position.Y - foot.Y
                        low = h >= 2.2
                    end
                    if (not ceil) or low then
                        -- Gefahrflaechen merken statt wegwerfen: der Weg
                        -- darueber bleibt moeglich, kostet aber so viel, dass
                        -- A* ihn nur nimmt, wenn es gar nicht anders geht.
                        local inst, mat = hit.Instance, hit.Material
                        local bad = (mat == Enum.Material.Water)
                            or (inst and (inst:GetAttribute("Lava")
                                          or inst:GetAttribute("ContactDamage")
                                          or inst:GetAttribute("Acid"))) and true or false
                        local nd = { p = foot, ix = ix, iz = iz, id = #nodes + 1, e = {},
                                     bad = bad, low = low }
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

-- Wasser und Saeure sind hier KEIN Terrain, sondern Teile mit
-- CanCollide = false (gemessen auf RavenRock: "Water", "WaterMainPart",
-- Material Plastic). Ein Raycast mit RespectCanCollide geht schlicht
-- hindurch und trifft den Grund darunter — die Erkennung ueber das
-- Material fand deshalb 6 von 27869 Knoten. Stattdessen werden die
-- Volumen dieser Teile direkt geprueft.
local function markHazards(nodes, mapRoot)
    local vols = {}
    for _, d in ipairs(mapRoot:GetDescendants()) do
        if d:IsA("BasePart") then
            local n = d.Name:lower()
            if n:find("water") or n:find("acid") or n:find("lava")
               or n:find("liquid") or n:find("slime") or n:find("poison")
               or d.Material == Enum.Material.Water
               or d:GetAttribute("Lava") or d:GetAttribute("ContactDamage")
               or d:GetAttribute("Acid") then
                -- Wolken und Deko ueber dem Wasser interessieren nicht
                if not n:find("cloud") and not n:find("splash") then
                    vols[#vols+1] = d
                end
            end
        end
    end
    if #vols == 0 then return 0, 0 end
    local marked = 0
    for i, nd in ipairs(nodes) do
        for _, v in ipairs(vols) do
            local lp = v.CFrame:PointToObjectSpace(nd.p)
            local h = v.Size * 0.5
            -- Nur was WIRKLICH unter der Oberflaeche liegt. Ein erster
            -- Versuch mit Puffer nach oben markierte 10794 von 27867 Knoten
            -- (39 % der Map) — diese Wasserteile sind grossflaechig, und
            -- alles knapp darueber ist trockenes Ufer.
            if math.abs(lp.X) <= h.X and math.abs(lp.Z) <= h.Z
               and lp.Y <= h.Y - 0.5 and lp.Y >= -h.Y - 2 then
                nd.bad = true
                marked = marked + 1
                break
            end
        end
        if i % 1500 == 0 then breathe() end
    end
    return marked, #vols
end

-- Knoten von Kanten wegschieben.
-- Die Abtastung laeuft auf einem map-globalen Raster, das sich nicht an
-- Treppen oder Rampen ausrichtet. Trifft ein Strahl gerade noch die
-- aeusserste Kante einer Stufe, liegt der Knoten genau dort — der Bot
-- laeuft hin, rutscht seitlich ab und verfehlt damit oft die ganze
-- Treppe. Also wird jeder Knoten von seinen Abbruchkanten weggeschoben,
-- solange darunter noch dieselbe Flaeche liegt.
local function nudgeFromEdges(nodes)
    local moved = 0
    for i, nd in ipairs(nodes) do
        local push, edges = Vector3.zero, 0
        for k = 0, 7 do
            local ang = k * math.pi / 4
            local dir = Vector3.new(math.cos(ang), 0, math.sin(ang))
            local probe = nd.p + dir * 2.0 + Vector3.new(0, 0.6, 0)
            local hit = cast(probe, Vector3.new(0, -3.5, 0))
            -- kein Boden daneben, oder er liegt deutlich tiefer: Abbruchkante
            if (not hit) or math.abs(hit.Position.Y - nd.p.Y) > 2.0 then
                push = push - dir
                edges = edges + 1
            end
        end
        -- 7 oder 8 Kanten heisst freistehender Pfosten, da hilft Schieben nicht
        if edges >= 1 and edges <= 6 and push.Magnitude > 0.1 then
            local target = nd.p + push.Unit * 1.6
            -- Nicht DURCH eine Wand schieben: geprueft wurde bisher nur, ob
            -- am Zielort Boden liegt. Hinter einer duennen Wand ist das der
            -- Fall, und der Knoten landete auf der falschen Seite - der Weg
            -- fuehrte dann mitten hindurch.
            if cast(nd.p + Vector3.new(0, 1.5, 0), push.Unit * 2.2) then
                target = nil
            end
            local under = target and cast(target + Vector3.new(0, 1.2, 0), Vector3.new(0, -4, 0))
            if under and math.abs(under.Position.Y - nd.p.Y) < 1.5 then
                local foot = under.Position + Vector3.new(0, 0.5, 0)
                if not cast(foot, Vector3.new(0, CFG.agentHeight * 0.6, 0)) then
                    nd.p = foot
                    moved = moved + 1
                end
            end
        end
        if i % 700 == 0 then breathe() end
    end
    return moved
end

------------------------------------------------------------------
-- 4) Kanten. Kosten sind SEKUNDEN.
------------------------------------------------------------------
-- Wasser und Schadensflaechen: Strafaufschlag auf jede Kante, die DORTHIN
-- fuehrt. In Sekunden gerechnet entspricht das einem langen Umweg, also
-- meidet A* sie zuverlaessig, ohne dass sie ganz unpassierbar werden.
local DANGER_COST = 25.0   -- Wasser wird damit praktisch immer umgangen
local function addEdge(a, b, kind, cost, via)
    if b.bad then cost = cost + DANGER_COST end
    -- Fuehrt die Kante in eine enge Stelle, muss dort gerollt werden
    if b.low and kind == "walk" then kind = "roll" ; cost = cost + 0.4 end
    a.e[#a.e+1] = { to = b.id, k = kind, c = cost, via = via }
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

-- 4a) GEHEN, STUFEN und ABSAETZE zwischen benachbarten Zellen.
-- Wichtig: Sprungkanten entstehen sonst nur zwischen RANDknoten. Eine
-- Treppenstufe mitten in einer Treppe ist kein Randknoten — Hoehen
-- zwischen stepUp und Sprunghoehe bekamen dadurch GAR KEINE Kante, und
-- genau daran zerreisst der Graph an jeder Treppe. Darum hier zusaetzlich
-- "hop" nach oben und "step" nach unten fuer alle Nachbarn.
-- Ist der Weg zwischen zwei Knoten begehbar? Ein einzelner Strahl von
-- Zellenmitte zu Zellenmitte reicht dafuer NICHT: eine Tuer ist schmaler
-- als das Raster und liegt selten genau auf der Verbindungslinie. Gemessen
-- auf CrossRoads waren dadurch nur 65 % der Innenknoten erreichbar
-- gegenueber 88 % draussen — ganze Raeume hingen unverbunden im Graphen.
-- Darum bei Blockade zusaetzlich quer versetzte Strahlen: findet den
-- Durchgang auch dann, wenn er seitlich der Ideallinie liegt.
-- Der Charakter ist rund 2 Studs breit und laeuft die Verbindungslinie
-- entlang. Ein EINZELNER freier Strahl reicht deshalb nicht als Beweis:
-- kommt nur ein seitlich versetzter Strahl durch, liegt die Oeffnung
-- neben der Laufspur und der Bot rennt gegen die Wand — genau das war
-- als "laeuft in Waende" sichtbar.
-- Geprueft wird daher ein KORRIDOR aus drei parallelen Strahlen, die alle
-- frei sein muessen. Ist er mittig blockiert, wird der Korridor seitlich
-- verschoben; klappt es dort, liefert die Funktion diesen Versatz als
-- Durchgangspunkt zurueck, den der Wegpunkt-Folger dann auch anlaeuft.
local CORRIDOR = 1.15
local function corridorFree(a, c, side, off)
    local o = side * off
    for _, w in ipairs({ 0, CORRIDOR, -CORRIDOR }) do
        local shift = o + side * w
        if cast(a + shift, (c + shift) - (a + shift)) then return false end
    end
    return true
end

-- Rueckgabe: begehbar?, optionaler Durchgangspunkt
local function passable(a, c)
    local flat = (c - a) * Vector3.new(1, 0, 1)
    if flat.Magnitude < 0.1 then return false, nil end
    local side = Vector3.new(-flat.Unit.Z, 0, flat.Unit.X)
    if corridorFree(a, c, side, 0) then return true, nil end
    -- mittig zu, aber vielleicht gibt es daneben eine Tuer
    for _, off in ipairs({ 1.6, -1.6, 2.6, -2.6 }) do
        if corridorFree(a, c, side, off) then
            -- Mitte des versetzten Korridors als Zwischenziel
            local mid = (a + c) * 0.5 + side * off
            return true, mid
        end
    end
    return false, nil
end

local function buildWalk(nodes, grid, prof)
    local dirs = { {1,0}, {0,1}, {1,1}, {1,-1}, {-1,1}, {-1,0}, {0,-1}, {-1,-1} }
    local walk, hop, step = 0, 0, 0
    for i, n in ipairs(nodes) do
        for _, d in ipairs(dirs) do
            local b = grid[(n.ix+d[1]) .. "," .. (n.iz+d[2])]
            if b then
                for _, o in ipairs(b) do
                    local dy = o.p.Y - n.p.Y
                    local dist = (o.p - n.p).Magnitude
                    local a = n.p + Vector3.new(0, 2.2, 0)
                    local c = o.p + Vector3.new(0, 2.2, 0)
                    local okPass, via = passable(a, c)
                    if not okPass then
                        -- nichts
                    elseif math.abs(dy) <= CFG.stepUp then
                        addEdge(n, o, "walk", dist / prof.speed, via)
                        walk = walk + 1
                    elseif dy > CFG.stepUp and dy <= prof.rise then
                        -- Stufe hoch: braucht einen Sprung, ist aber kurz.
                        -- Ein Ueberhang ueber der Kante macht das unmoeglich:
                        -- der Bot stoesst sich am Vorsprung den Kopf und
                        -- rutscht wieder ab. Also pruefen, ob ueber dem
                        -- Absprungpunkt ueberhaupt Platz zum Steigen ist.
                        -- Zwei Bedingungen, nicht eine: ueber dem Absprungpunkt
                        -- muss Platz zum Steigen sein UND der Anflug auf
                        -- Zielhoehe muss frei sein. Ein Ueberhang ragt ueber
                        -- das ZIEL, nicht ueber den Absprung — die alte
                        -- Pruefung sah ihn deshalb nur teilweise.
                        local headroom = not cast(n.p + Vector3.new(0, 1, 0),
                                                  Vector3.new(0, dy + 4.5, 0))
                        local lip = Vector3.new(n.p.X, o.p.Y + 1.8, n.p.Z)
                        local approach = not cast(lip,
                                                  (o.p + Vector3.new(0, 1.8, 0)) - lip)
                        if headroom and approach then
                            addEdge(n, o, "hop", dist / prof.speed + 0.15, via)
                            hop = hop + 1
                        end
                    elseif dy < -CFG.stepUp and dy > -30 then
                        -- Stufe runter: einfach fallen lassen
                        addEdge(n, o, "step",
                                dist / prof.speed + math.sqrt(2 * math.abs(dy) / prof.g), via)
                        step = step + 1
                    end
                end
            end
        end
        if i % 300 == 0 then breathe() end
    end
    return walk, hop, step
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
                                local lipJ = Vector3.new(a.p.X, o.p.Y + 1.8, a.p.Z)
                                if dy > 0 and dy <= prof.rise and arcClear(a.p, o.p, prof)
                                   and not cast(a.p + Vector3.new(0, 1, 0),
                                                Vector3.new(0, dy + 4.5, 0))
                                   and not cast(lipJ, (o.p + Vector3.new(0, 1.8, 0)) - lipJ) then
                                    -- kein Ueberhang, weder ueber dem Absprung
                                    -- noch ueber der Zielkante
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

-- 4d) WALLRIDE — als Vertikalmittel BEWUSST NICHT VERWENDET.
-- Es funktioniert nur an eigens markierten Waenden (Attribut "Wallrun"),
-- die in diesen Maps sehr selten sind — auf Area51 keine einzige. Ueberall
-- sonst braeuchte es shared.multipliers.EnableWallrunning, und auf einen
-- Exploit-Schalter darf sich eine Route nicht stuetzen. Die Funktion bleibt
-- fuer spaeter stehen, wird aber von NAV.bake nicht mehr aufgerufen.
-- Der Spielcode (Wallrun-Modul) laesst einen Wallrun nur zu, wenn das
-- getroffene Teil das Attribut "Wallrun" traegt — oder wenn
-- shared.multipliers.EnableWallrunning gesetzt ist, und das ist ein
-- Exploit-Schalter, auf den sich eine Route nicht stuetzen darf.
-- Ein frueherer Versuch, jede steile Flaeche als kletterbar zu werten,
-- hat 401 bis 953 Phantomkanten erzeugt.
local function buildWallrun(nodes, grid, bb, cell, mapRoot, prof)
    local walls = {}
    for _, d in ipairs(mapRoot:GetDescendants()) do
        if d:IsA("BasePart") and d:GetAttribute("Wallrun") then
            walls[#walls+1] = d
        end
    end
    local count = 0
    for _, w in ipairs(walls) do
        -- Fusspunkte entlang der Wandbasis abtasten, je Seite
        local cf, sz = w.CFrame, w.Size
        local along = (sz.X >= sz.Z) and cf.RightVector or cf.LookVector
        local len = math.max(sz.X, sz.Z)
        local normal = (sz.X >= sz.Z) and cf.LookVector or cf.RightVector
        for _, side in ipairs({ 1, -1 }) do
            local steps = math.max(1, math.floor(len / 10))
            for s = 0, steps do
                local along_off = (s / math.max(steps,1) - 0.5) * len
                local base = w.Position + along * along_off
                            + normal * side * (math.min(sz.X, sz.Z) * 0.5 + 2.5)
                local foot = nearest(grid, bb, cell,
                                     Vector3.new(base.X, w.Position.Y - sz.Y * 0.5 + 3, base.Z),
                                     12, 10)
                if foot then
                    local top = nearest(grid, bb, cell,
                                        Vector3.new(base.X, w.Position.Y + sz.Y * 0.5, base.Z),
                                        14, 8)
                    if top and top.id ~= foot.id then
                        local gain = top.p.Y - foot.p.Y
                        if gain > CFG.stepUp and gain <= CFG.wallChainMax then
                            addEdge(foot, top, "wallrun", gain / prof.wallSpeed + 0.5)
                            addEdge(top, foot, "drop", math.sqrt(2 * gain / prof.g))
                            count = count + 1
                        end
                    end
                end
            end
        end
        breathe()
    end
    return count, #walls
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
    -- Deckel gegen den teuersten Fall: gibt es gar keinen Weg, durchsucht
    -- A* sonst den kompletten Graphen — auf einer grossen Map ueber 100 ms
    -- pro vergeblicher Anfrage.
    local budget = 12000
    while visited < budget do
        local cur = pop()
        if not cur then break end
        if not closed[cur] then
            closed[cur] = true
            visited = visited + 1
            if cur == t.id then
                local path, at = {}, cur
                while at do
                    local cm = came[at]
                    table.insert(path, 1, { node = nodes[at], kind = cm and cm.k or "walk" })
                    -- Durchgangspunkt einer Tuer: liegt neben der Luftlinie
                    -- und muss eigens angelaufen werden
                    if cm and cm.via then
                        table.insert(path, 1, { node = { p = cm.via }, kind = "via" })
                    end
                    at = cm and cm.from or nil
                end
                return path, nil, visited
            end
            local n = nodes[cur]
            for _, e in ipairs(n.e) do
                local ng = gScore[cur] + e.c
                if not gScore[e.to] or ng < gScore[e.to] then
                    gScore[e.to] = ng
                    came[e.to] = { from = cur, k = e.k, via = e.via }
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
    -- Beide MUESSEN vor dem Kantenbau laufen: das Wegschieben aendert
    -- Knotenpositionen, addEdge liest nd.bad
    stats.nudged = nudgeFromEdges(nodes)
    stats.hazard, stats.hazardParts = markHazards(nodes, mapRoot)
    stats.walk, stats.hop, stats.step = buildWalk(nodes, grid, prof)
    stats.climb = buildClimb(nodes, grid, bb, cell, mapRoot, prof)
    local j, d, rim = buildJumpDrop(nodes, grid, cell, prof)
    stats.jump, stats.drop, stats.rim = j, d, #rim
    stats.wallrun, stats.wallParts = 0, 0   -- siehe 4d: bewusst ausgeschlossen
    stats.zip, stats.pad = buildHelpers(nodes, grid, bb, cell, mapRoot, prof)

    NAV.graph = { nodes = nodes, grid = grid, cell = cell, bb = bb,
                  prof = prof, map = mapRoot.Name, stats = stats }
    stats.nodes = #nodes
    stats.secs = os.clock() - t0
    return NAV.graph
end

local function navFileName(mapName)
    return "utg_nav_" .. tostring(mapName):gsub("[^%w_%-]", "_") .. ".json"
end

-- Graph aus der Datei holen. Der Bake dauert gruendlich ~30 s; das lohnt
-- sich einmal pro Map, aber nicht bei jedem Rundenwechsel — und die Maps
-- sind ein fester Pool, der sich nicht aendert.
-- Kompaktes Textformat statt JSON. Ein gruendlich gebackener Graph hat
-- ueber 400.000 Kanten; als JSON sind das zweistellige Megabyte, und
-- HttpService:JSONEncode scheitert daran stillschweigend. Hier steht je
-- Knoten eine Zeile "x,y,z>ziel:art:kosten,..." mit einem Buchstaben je
-- Kantenart — das ist rund ein Viertel so gross und laedt deutlich schneller.
local KIND2CH = { walk="w", hop="h", step="s", jump="j", drop="d",
                  climb="c", zip="z", pad="p", wallrun="r", roll="o" }
local CH2KIND = {}
for k, v in pairs(KIND2CH) do CH2KIND[v] = k end

function NAV.load(mapName)
    if type(readfile) ~= "function" or type(isfile) ~= "function" then return nil end
    local fn = navFileName(mapName)
    local ok, blob = pcall(function()
        if not isfile(fn) then return nil end
        return readfile(fn)
    end)
    if not ok or type(blob) ~= "string" or #blob < 50 then return nil end

    local lines = string.split(blob, "\n")
    local head = string.split(lines[1] or "", "|")
    if head[1] ~= "UTGNAV5" then return nil end
    local cell = tonumber(head[3])
    local bbv = string.split(head[4] or "", ",")
    if not cell or #bbv < 6 then return nil end
    local bb = { min = Vector3.new(tonumber(bbv[1]), tonumber(bbv[2]), tonumber(bbv[3])),
                 max = Vector3.new(tonumber(bbv[4]), tonumber(bbv[5]), tonumber(bbv[6])) }

    local nodes, grid = {}, {}
    for i = 2, #lines do
        local line = lines[i]
        if #line > 2 then
            local cut = string.find(line, ">", 1, true)
            local posPart = cut and string.sub(line, 1, cut - 1) or line
            local xyz = string.split(posPart, ",")
            local p = Vector3.new(tonumber(xyz[1]) or 0, tonumber(xyz[2]) or 0,
                                  tonumber(xyz[3]) or 0)
            local ix = math.floor((p.X - bb.min.X) / cell + 0.5)
            local iz = math.floor((p.Z - bb.min.Z) / cell + 0.5)
            local e = {}
            if cut then
                for _, chunk in ipairs(string.split(string.sub(line, cut + 1), ",")) do
                    if #chunk > 3 then
                        local f = string.split(chunk, ":")
                        local to = tonumber(f[1])
                        if to then
                            local via
                            if f[4] and f[5] and f[6] then
                                via = Vector3.new(tonumber(f[4]) or 0, tonumber(f[5]) or 0,
                                                  tonumber(f[6]) or 0)
                            end
                            e[#e+1] = { to = to, k = CH2KIND[f[2]] or "walk",
                                        c = tonumber(f[3]) or 1, via = via }
                        end
                    end
                end
            end
            local id = #nodes + 1
            local nd = { p = p, ix = ix, iz = iz, id = id, e = e }
            nodes[id] = nd
            local k = ix .. "," .. iz
            local b = grid[k] ; if not b then b = {} grid[k] = b end
            b[#b+1] = nd
        end
    end
    if #nodes < 50 then return nil end
    NAV.graph = { nodes = nodes, grid = grid, cell = cell, bb = bb,
                  prof = profile(), map = mapName,
                  stats = { nodes = #nodes }, fromFile = true }
    return NAV.graph
end

function NAV.save()
    local G = NAV.graph
    if not G or type(writefile) ~= "function" then return false, "kein writefile" end
    local function r1(v) return math.floor(v * 10 + 0.5) / 10 end
    local function r2(v) return math.floor(v * 100 + 0.5) / 100 end

    -- stueckweise zusammensetzen: ein einzelner String mit Millionen
    -- Verkettungen sprengt den Speicher
    local parts = {
        ("UTGNAV5|%s|%s|%s,%s,%s,%s,%s,%s"):format(tostring(G.map), tostring(G.cell),
            r1(G.bb.min.X), r1(G.bb.min.Y), r1(G.bb.min.Z),
            r1(G.bb.max.X), r1(G.bb.max.Y), r1(G.bb.max.Z))
    }
    local buf = {}
    for _, n in ipairs(G.nodes) do
        local es = {}
        for _, e in ipairs(n.e) do
            local s = e.to .. ":" .. (KIND2CH[e.k] or "w") .. ":" .. r2(e.c)
            if e.via then
                s = s .. ":" .. r1(e.via.X) .. ":" .. r1(e.via.Y) .. ":" .. r1(e.via.Z)
            end
            es[#es+1] = s
        end
        buf[#buf+1] = r1(n.p.X) .. "," .. r1(n.p.Y) .. "," .. r1(n.p.Z)
                      .. ">" .. table.concat(es, ",")
        if #buf >= 2000 then
            parts[#parts+1] = table.concat(buf, "\n")
            buf = {}
        end
    end
    if #buf > 0 then parts[#parts+1] = table.concat(buf, "\n") end

    local blob = table.concat(parts, "\n")
    local ok, err = pcall(writefile, navFileName(G.map), blob)
    if not ok then return false, tostring(err) end
    -- wirklich nachsehen statt dem pcall zu glauben
    if type(isfile) == "function" and not isfile(navFileName(G.map)) then
        return false, "Datei nach dem Schreiben nicht vorhanden"
    end
    return true, #blob
end

return NAV
