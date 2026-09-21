--[[ ============================================================
     UTG TAG ASSIST  —  Untitled Tag Game (PlaceId 14044547200)
     Reine Mechanik-Manipulation, kein Teleport, keine Fly-Hacks.

     WEGLAUFEN : je naeher ein Faenger, desto (leicht) schneller.
                 Laeuft ueber shared.boosts — das spieleigene Boost-System,
                 dadurch normale Beschleunigung/Momentum, kein Speed-Sprung.
     FANGEN    : Reichweite + Trefferkegel wachsen weich an, wenn ein Opfer
                 nah ist. Basis ist 7 Studs, Server akzeptiert bis ~30.
     PARKOUR   : Wallrun / Tic-Tacs / Wallclimb / Slide-Tuning freischalten.
     ============================================================ ]]

------------------------------------------------------------------
-- 0) Altes Exemplar sauber killen
------------------------------------------------------------------
if getgenv().__UTG_TAG and getgenv().__UTG_TAG.cleanup then
    pcall(getgenv().__UTG_TAG.cleanup)
end
local ENV = {}
getgenv().__UTG_TAG = ENV
local conns = {}

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local LP = Players.LocalPlayer

-- Bei Runden-/Mapwechseln ist Utils kurzzeitig nicht ladbar. Frueher ist das
-- Tool dabei kommentarlos gestorben — jetzt wird gewartet.
local Utils
for attempt = 1, 40 do
    local okU, res = pcall(function() return require(game.ReplicatedFirst.Utils) end)
    if okU and type(res) == "table" then Utils = res break end
    task.wait(0.5)
end
if not Utils then warn("[UTG] Utils nicht ladbar") return end
local SerialisedData = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("SerialisedData"))
local RENV = getrenv()

------------------------------------------------------------------
-- 1) Konfiguration
------------------------------------------------------------------
local CFG = {
    -- EIN Schalter fuer das gesamte Spielverhalten: Weglaufen, Fangen,
    -- Reichweite, Auto-Tag, Parkour, Blickrichtung, Wegfindung.
    autopilot   = true,
    -- AYIP: 0 = aus, 1/2/3 = Juke-Stufen (entspricht frueher Ankles 6 / 8 / 10)
    ayip        = 0,   -- aus = altes Standardverhalten
    -- Mindestabstand fuer Finten: fest, der Regler dafuer ist entfallen
    feintDist   = 29,
    thirdPerson = false,   -- Taste T
    preset      = 3,       -- fest auf Maximum (kein Umschalten mehr)
    -- Sound nach einer gelungenen Finte (rein lokal, siehe Abschnitt 5c)
    jukeSound   = false,
    -- Die beiden Wege sind getrennt schaltbar: der eine spielt den Sound
    -- im Spiel (nur man selbst hoert ihn), der andere schickt ihn ueber das
    -- virtuelle Mikrofon in den Voicechat (nur die anderen hoeren ihn).
    jukeSoundSelf = true,   -- selbst mithoeren
    jukeSoundVC = true,     -- braucht das Begleitprogramm utg_vc_player.py
    -- Deutlich ueber voll: der Sound soll den Moment markieren und sich
    -- gegen den Spielton durchsetzen. Er laeuft ohnehin nur beim eigenen
    -- Spieler, und Roblox laesst Volume bis 10 zu.
    jukeSoundVol = 1.6,
}

-- Die frueheren Einzelschalter haengen jetzt alle am Autopilot-Schalter.
setmetatable(CFG, { __index = function(t, k)
    if k == "escape" or k == "chase" or k == "parkour"
       or k == "faceRun" or k == "autotag" then
        return rawget(t, "autopilot")
    end
    if k == "ankles" then
        -- Waehrend einer Verfolgung sind Finten grundsaetzlich aus: sie
        -- kosten Weg und Tempo, wenn man hinterherlaeuft statt wegzulaufen.
        -- Das gilt auch dann, wenn man selbst gerade gejagt wird.
        if rawget(t, "__chasing") then return 3 end
        -- AYIP aus -> das fruehere Standardverhalten (Stufe 3):
        -- massvolle Haken. Erst beim Einschalten greifen die drei Stufen.
        local map = { [0] = 3, [1] = 6, [2] = 8, [3] = 10 }
        return map[rawget(t, "ayip") or 0] or 3
    end
    return nil
end })

local PRESETS = {
    { name = "Subtil",
      escBoost = 0.05, escRadius = 70, escJump = 1.02, escAccel = 1.08,
      chsBoost = 0.07, chsRadius = 90,
      reachMax = 8.1,  reachFrom = 12, spreadMax = 1.6,
      cdMul = 1.00, gravity = 1.00, fleeR = 44, chaseR = 45, panicR = 12 },
    { name = "Mittel",
      escBoost = 0.09, escRadius = 90, escJump = 1.05, escAccel = 1.15,
      chsBoost = 0.12, chsRadius = 140,
      reachMax = 10.5, reachFrom = 14, spreadMax = 2.2,
      cdMul = 0.92, gravity = 0.98, fleeR = 58, chaseR = 60, panicR = 16 },
    { name = "Stark",
      escBoost = 0.14, escRadius = 110, escJump = 1.10, escAccel = 1.28,
      chsBoost = 0.15, chsRadius = 200,
      reachMax = 15.4, reachFrom = 21, spreadMax = 3.2,
      cdMul = 0.80, gravity = 0.95, fleeR = 75, chaseR = 90, panicR = 20 },
}
local function P() return PRESETS[CFG.preset] end

-- ANKLES: ein Regler, der das Antaeuschen steuert.
--   0 = gar keine Haken (schnurgerade)
--   3 = Standard: kurze Haken bis 82 Grad, erst ab 9 Studs Abstand
--  10 = volle Kehren bis 180 Grad direkt vor der Nase des Verfolgers
-- Balance: je hoeher, desto naeher darf gejukt werden und desto groesser der
-- Winkel. Ab 6 darf der Haken auch quer am Verfolger vorbei gehen, WENN der
-- gerade schnell auf uns zulaeuft (dann laeuft er ins Leere) — darunter bleibt
-- die harte Regel "nie in Richtung eines Jaegers".
local function ankles()
    local a = math.clamp(CFG.ankles or 3, 0, 10)
    return {
        on       = a > 0,
        level    = a,
        -- Seitliche Haken: bewusst im Seitenbereich halten (50-100 Grad).
        -- Die harten Kehren sind allein die Burner, sonst gibt es bei hoher
        -- Stufe nur noch 180er und keine echten Seitenfinten mehr.
        maxAngle = 50 + 5 * a,           -- 3 -> 65 Grad, 10 -> 100 Grad
        dur      = 0.12 + 0.022 * a,     -- 3 -> 0.19 s, 10 -> 0.27 s
        -- Pause zwischen Haken: ohne AYIP (Stufe 3) sehr ruhig, mit AYIP
        -- immer dichter getaktet.
        gap      = math.max(3.6 - 0.31 * a, 0.5),
        -- und nicht jede Gelegenheit wird genutzt, je niedriger desto seltener
        chance   = math.min(0.3 + 0.075 * a, 1),
        -- Mindestabstand fuer Haken kommt ausschliesslich vom Regler —
        -- die AYIP-Stufe aendert daran bewusst nichts.
        minDist  = CFG.feintDist or 15,
        cross    = a >= 6,               -- darf quer am Verfolger vorbei
        -- Die folgenden Einzelmanoever sind durch das Juke-Repertoire
        -- (Abschnitt 5b) abgeloest und bleiben aus, damit sich beide
        -- Systeme nicht gegenseitig die Richtung ueberschreiben.
        burner   = false,
        -- Mischung: rund die Haelfte Kehren, der Rest Seitenfinten
        burnerP  = math.min(0.28 + 0.032 * a, 0.62),
        doubleBack = false,
        squeeze  = false,
        rollcut  = false,
        cornerPeel = a >= 6,             -- eng um die Ecke und dahinter abbiegen
        bamboozle = false,
    }
end



------------------------------------------------------------------
-- 2) Logging (gepuffert — nie pro Event schreiben)
------------------------------------------------------------------
local LOGFILE = "utg_tag_log.txt"
local logbuf, lastFlush = {}, 0
local function LOG(s)
    logbuf[#logbuf + 1] = os.date("%H:%M:%S ") .. s
end
local function flushLog(force)
    if #logbuf == 0 then return end
    if not force and tick() - lastFlush < 1.5 then return end
    lastFlush = tick()
    local chunk = table.concat(logbuf, "\n") .. "\n"
    logbuf = {}
    pcall(function()
        if appendfile then appendfile(LOGFILE, chunk)
        else writefile(LOGFILE, (isfile(LOGFILE) and readfile(LOGFILE) or "") .. chunk) end
    end)
end
pcall(function() writefile(LOGFILE, "=== UTG Tag Assist gestartet " .. os.date("%d.%m. %H:%M:%S") .. " ===\n") end)

------------------------------------------------------------------
-- 2b) DAUER-DIAGNOSE
--     Laeuft immer mit und misst die beiden Fehlerbilder, die sich im
--     Spiel schlecht beobachten lassen:
--       1. UEBERSCHIESSEN — wie weit faehrt der Bot ueber einen Wegpunkt
--          hinaus, mit welchem Tempo und wie schief lief er ihn an?
--       2. LEITERN — wie nah kam er an den Truss, hat das Spiel
--          touchingTruss gesetzt, wie viel Hoehe kam dabei heraus?
--     Geschrieben wird gepuffert in utg_diag.txt (nie pro Ereignis), die
--     Datei bleibt auf die letzten 600 Zeilen begrenzt. Auswertung ueber
--     ENV.diag() — die Zusammenfassung landet auch in der Datei.
------------------------------------------------------------------
------------------------------------------------------------------
-- 2c) ERGEBNISMESSUNG — wie schwer bin ich zu fangen?
--     Das ist das eigentliche Mass. Alles andere (Wegtreue,
--     Trefferquoten) ist nur Mittel zum Zweck. Gemessen wird:
--       * wie lange ich am Stueck ungefangen bleibe
--       * wie oft ich gefangen werde, je Minute Fluchtzeit
--       * wie nah die Verfolger im Schnitt kommen und wie lange sie
--         in Greifweite bleiben (Gefahrzeit)
--       * wie oft eine schon gewonnene Verfolgung wieder abgeschuettelt
--         wird (Ausbruch) und wie oft nicht
--       * welche Fortbewegungsarten dabei benutzt wurden — nur so laesst
--         sich sagen, ob Vertikalitaet wirklich hilft
------------------------------------------------------------------
local SURV = {
    on = true,
    t0 = tick(),
    fleeTime = 0, dangerTime = 0, sampleAt = 0,
    dSum = 0, dN = 0, dMin = 1e9,
    tags = 0, lastTag = tick(), bestStreak = 0,
    close = nil,            -- laufende Nahverfolgung
    escapes = 0, caught = 0,
    used = {},              -- Kantenarten waehrend der Flucht
    role = nil,
}
ENV.surv = SURV

local DIAGFILE  = "utg_diag.txt"      -- menschenlesbarer Auszug (Ringpuffer)
local STATSFILE = "utg_stats.json"    -- Summen, ueber Sitzungen hinweg
local EVENTFILE = "utg_events.csv"    -- jedes Ereignis einzeln, zum Auswerten
local DIAG = {
    on = true,
    ring = {},         -- letzte Zeilen, Ringpuffer
    dirty = false, lastWrite = 0,
    stat = {},         -- Zaehler und Mittelwerte je Ereignisart
    wp = nil,          -- laufende Messung am aktuellen Wegpunkt
    lad = nil,         -- laufende Messung an einer Leiter
}
local DIAG_MAX = 600

local function diagStat(kind)
    local s = DIAG.stat[kind]
    if not s then s = { n = 0 } DIAG.stat[kind] = s end
    return s
end

-- Mittelwert und Maximum einer Groesse mitfuehren
local function diagVal(kind, key, v)
    local s = diagStat(kind)
    s[key .. "_sum"] = (s[key .. "_sum"] or 0) + v
    s[key .. "_n"] = (s[key .. "_n"] or 0) + 1
    if not s[key .. "_max"] or v > s[key .. "_max"] then s[key .. "_max"] = v end
end

-- EREIGNISDATEI. Eine Zeile je Ereignis, mit Semikolon getrennt, damit
-- sich grosse Mengen spaeter auswerten lassen. Gepuffert geschrieben — nie
-- eine Datei je Ereignis, das bringt das Spiel zum Stocken.
local evBuf, evAt, evCount = {}, 0, 0
local function evMap()
    local cm = workspace:FindFirstChild("CurrentMap")
    local c = cm and cm:GetChildren()[1]
    return c and c.Name or "?"
end
local function diagEvent(typ, a, b, c, text)
    if not DIAG.on then return end
    evCount = evCount + 1
    -- ENV.ap statt AP: das lokale AP steht weiter unten in der Datei und
    -- waere hier ein globaler nil-Wert.
    local mode = (ENV.ap and ENV.ap.mode) or "-"
    evBuf[#evBuf + 1] = table.concat({
        os.date("%H:%M:%S"), evMap(), tostring(mode), tostring(typ),
        tostring(a or ""), tostring(b or ""), tostring(c or ""),
        -- Klammern noetig: gsub liefert zwei Werte, und der letzte Eintrag
        -- eines Tabellenkonstruktors wuerde beide aufnehmen (haengte eine
        -- ueberzaehlige Spalte an jede Zeile).
        (tostring(text or ""):gsub(";", ",")),
    }, ";")
end
ENV.diagEvent = diagEvent

local function evFlush(force)
    if #evBuf == 0 then return end
    local now = tick()
    if not force and now - evAt < 5 then return end
    evAt = now
    local chunk = table.concat(evBuf, string.char(10)) .. string.char(10)
    evBuf = {}
    -- Groesse im Griff behalten: ab acht Megabyte wird die Datei einmal
    -- weggesichert und frisch begonnen, damit sie nicht endlos waechst.
    pcall(function()
        if type(isfile) == "function" and isfile(EVENTFILE) then
            local sz = #readfile(EVENTFILE)
            if sz > 8 * 1024 * 1024 then
                if type(writefile) == "function" then
                    writefile("utg_events_alt.csv", readfile(EVENTFILE))
                    writefile(EVENTFILE, "zeit;map;modus;typ;a;b;c;text" .. string.char(10))
                end
            end
        end
    end)
    pcall(function()
        if type(appendfile) == "function" then
            appendfile(EVENTFILE, chunk)
        elseif type(writefile) == "function" then
            local old = (type(isfile) == "function" and isfile(EVENTFILE))
                        and readfile(EVENTFILE) or ""
            writefile(EVENTFILE, old .. chunk)
        end
    end)
end

-- SUMMEN DAUERHAFT HALTEN. Ohne das faengt jede Neuinjektion bei null an,
-- und ueber eine Spielsitzung kommt nie genug Material zusammen.
function statsSave()
    if type(writefile) ~= "function" then return end
    local ok, txt = pcall(function()
        return game:GetService("HttpService"):JSONEncode({
            stat = DIAG.stat,
            surv = { fleeTime = SURV.fleeTime, dangerTime = SURV.dangerTime,
                     dSum = SURV.dSum, dN = SURV.dN, dMin = SURV.dMin,
                     tags = SURV.tags, bestStreak = SURV.bestStreak,
                     escapes = SURV.escapes, caught = SURV.caught,
                     used = SURV.used },
            events = evCount, saved = os.time(),
        })
    end)
    if ok then pcall(writefile, STATSFILE, txt) end
end

function statsLoad()
    if type(isfile) ~= "function" or not isfile(STATSFILE) then return end
    pcall(function()
        local d = game:GetService("HttpService"):JSONDecode(readfile(STATSFILE))
        if type(d) ~= "table" then return end
        if type(d.stat) == "table" then
            for k, v in pairs(d.stat) do DIAG.stat[k] = v end
        end
        if type(d.surv) == "table" then
            for k, v in pairs(d.surv) do SURV[k] = v end
            SURV.dMin = SURV.dMin or 1e9
            SURV.used = SURV.used or {}
        end
        evCount = tonumber(d.events) or 0
    end)
end

-- beim Start: Summen der bisherigen Sitzungen uebernehmen und die
-- Ereignisdatei anlegen, falls sie noch fehlt
pcall(statsLoad)
pcall(function()
    if type(isfile) == "function" and not isfile(EVENTFILE)
       and type(writefile) == "function" then
        writefile(EVENTFILE, "zeit;map;modus;typ;a;b;c;text" .. string.char(10))
    end
end)

local function diagLine(kind, fmt, ...)
    if not DIAG.on then return end
    diagStat(kind).n = diagStat(kind).n + 1
    local ok, txt = pcall(string.format, fmt, ...)
    local line = os.date("%H:%M:%S ") .. kind .. "  " .. (ok and txt or "?")
    DIAG.ring[#DIAG.ring + 1] = line
    if #DIAG.ring > DIAG_MAX then table.remove(DIAG.ring, 1) end
    DIAG.dirty = true
end

-- Ganze Datei neu schreiben statt anzuhaengen: so bleibt sie klein und es
-- gibt keinen Lesevorgang ueber eine wachsende Datei.
local statsAt = 0
local function diagFlush(force)
    pcall(evFlush, force)
    local nowF = tick()
    -- Summen alle 20 Sekunden sichern, damit ein Neuladen oder ein Absturz
    -- nicht die Ausbeute der ganzen Sitzung kostet
    if force or nowF - statsAt > 20 then
        statsAt = nowF
        pcall(statsSave)
    end
    if not DIAG.dirty or type(writefile) ~= "function" then return end
    local now = tick()
    if not force and now - DIAG.lastWrite < 3 then return end
    DIAG.lastWrite, DIAG.dirty = now, false
    pcall(writefile, DIAGFILE, table.concat(DIAG.ring, "\n") .. "\n")
end

local function diagAvgTxt(kind, key, unit)
    local s = DIAG.stat[kind]
    if not s or not s[key .. "_n"] or s[key .. "_n"] == 0 then return "-" end
    return ("%.1f%s (max %.1f)"):format(s[key .. "_sum"] / s[key .. "_n"],
                                        unit or "", s[key .. "_max"] or 0)
end

function ENV.diag()
    local out = { "=== DIAGNOSE " .. os.date("%H:%M:%S") .. " ===" }
    local order = { "wegpunkt", "ueberschossen", "leiter_ok", "leiter_daneben",
                    "leiter_abbruch" }
    local seen = {}
    local function row(k)
        local s = DIAG.stat[k]
        if not s or seen[k] then return end
        seen[k] = true
        out[#out + 1] = ("%-16s n=%d"):format(k, s.n)
    end
    for _, k in ipairs(order) do row(k) end
    -- alles, was unten eigene Abschnitte hat, hier nicht noch einmal
    for k in pairs(DIAG.stat) do
        if not (k:match("^art_") or k:match("^wegquelle_") or k:match("^wegende_")
                or k:match("^graphgrund_") or k:match("^graph_")
                or k:match("^neu_") or k == "wegstart") then
            row(k)
        end
    end
    local wp = DIAG.stat.wegpunkt
    if wp and (wp.n or 0) > 0 then
        out[#out + 1] = "-- Wegpunkte --"
        out[#out + 1] = "  dichteste Annaeherung  " .. diagAvgTxt("wegpunkt", "min", " Studs")
        out[#out + 1] = "  Ueberschuss danach     " .. diagAvgTxt("wegpunkt", "over", " Studs")
        out[#out + 1] = "  seitlicher Versatz     " .. diagAvgTxt("wegpunkt", "side", " Studs")
        out[#out + 1] = "  Tempo am Punkt         " .. diagAvgTxt("wegpunkt", "spd", " Studs/s")
    end
    -- JE FORTBEWEGUNGSART: Trefferquote und wie nah er herankam
    local arts = {}
    for k, v in pairs(DIAG.stat) do
        local kind = k:match("^art_([%w_]+)$")
        if kind and not kind:match("_ok$") then arts[#arts + 1] = kind end
    end
    table.sort(arts)
    if #arts > 0 then
        out[#out + 1] = "-- nach Fortbewegungsart (erreicht = unter 4 Studs) --"
        for _, kind in ipairs(arts) do
            local a = DIAG.stat["art_" .. kind]
            local ok = DIAG.stat["art_" .. kind .. "_ok"]
            local okN = ok and ok.n or 0
            out[#out + 1] = ("  %-6s n=%-4d erreicht %3d%%   naechste %s  Tempo %s  Dauer %s")
                :format(kind, a.n, math.floor(okN * 100 / math.max(a.n, 1)),
                        diagAvgTxt("art_" .. kind, "min", ""),
                        diagAvgTxt("art_" .. kind, "spd", ""),
                        diagAvgTxt("art_" .. kind, "zeit", "s"))
        end
    end

    local ws = DIAG.stat.wegstart
    if ws and ws.n > 0 then
        out[#out + 1] = "-- Wegbeginn --"
        out[#out + 1] = "  Abstand zum ersten Punkt  " .. diagAvgTxt("wegstart", "abstand", " Studs")
        out[#out + 1] = "  uebersprungene Punkte     " .. diagAvgTxt("wegstart", "uebersprungen", "")
    end

    -- WARUM WIRD NEU GERECHNET?
    local nk = {}
    for k, v in pairs(DIAG.stat) do
        local t = k:match("^neu_([%w_]+)$")
        if t then nk[#nk + 1] = { t, v.n } end
    end
    if #nk > 0 then
        table.sort(nk, function(a, b) return a[2] > b[2] end)
        local parts = {}
        for _, e in ipairs(nk) do parts[#parts + 1] = ("%s=%d"):format(e[1], e[2]) end
        out[#out + 1] = "-- Ausloeser der Neuberechnung --"
        out[#out + 1] = "  " .. table.concat(parts, "  ")
        if DIAG.stat.neu_ziel_bewegt then
            out[#out + 1] = "  Zielsprung dabei  " .. diagAvgTxt("neu_ziel_bewegt", "studs", " Studs")
        end
    end

    -- GRAPH GEGEN PATHFINDINGSERVICE
    local go, gf = DIAG.stat.graph_ok, DIAG.stat.graph_fehler
    if (go and go.n or 0) + (gf and gf.n or 0) > 0 then
        local nOk, nF = go and go.n or 0, gf and gf.n or 0
        out[#out + 1] = "-- Graph-Abfragen --"
        local nNear = (DIAG.stat.graph_zu_nah or {}).n or 0
        out[#out + 1] = ("  %d erfolgreich, %d gescheitert (%d%% Trefferquote), "
                         .. "%d mal Ziel schon im Startknoten")
            :format(nOk, nF, math.floor(nOk * 100 / math.max(nOk + nF, 1)), nNear)
        local noA = (DIAG.stat.graph_bot_ohne_knoten or {}).n or 0
        local noB = (DIAG.stat.graph_ziel_ohne_knoten or {}).n or 0
        if noA + noB > 0 then
            out[#out + 1] = ("  ohne Knoten in Reichweite: Bot %dx, Ziel %dx"):format(noA, noB)
        end
        out[#out + 1] = "  Abstand Bot->Knoten bei Erfolg   " .. diagAvgTxt("graph_ok", "start", " Studs")
        out[#out + 1] = "  Abstand Ziel->Knoten bei Erfolg  " .. diagAvgTxt("graph_ok", "ziel", " Studs")
        if nF > 0 then
            out[#out + 1] = "  bei Fehlschlag Bot->Knoten       " .. diagAvgTxt("graph_fehler", "start", " Studs")
            out[#out + 1] = "  bei Fehlschlag Ziel->Knoten      " .. diagAvgTxt("graph_fehler", "ziel", " Studs")
            local gr = {}
            for k, v in pairs(DIAG.stat) do
                local r = k:match("^graphgrund_(.+)$")
                if r then gr[#gr + 1] = ("%s=%d"):format(r, v.n) end
            end
            table.sort(gr)
            if #gr > 0 then out[#out + 1] = "  Gruende: " .. table.concat(gr, "  ") end
        end
    end

    -- GANZE WEGE: wie viel davon wird tatsaechlich gefahren?
    local wg = DIAG.stat.weg
    if wg and wg.n > 0 then
        out[#out + 1] = "-- Wege --"
        out[#out + 1] = ("  %d Wege, im Schnitt %s abgefahren, %s Punkte, %s")
            :format(wg.n, diagAvgTxt("weg", "anteil", "%"),
                    diagAvgTxt("weg", "punkte", ""), diagAvgTxt("weg", "dauer", "s"))
        local q = {}
        for k, v in pairs(DIAG.stat) do
            local src = k:match("^wegquelle_(%w+)$")
            if src then q[#q + 1] = ("%s=%d"):format(src, v.n) end
        end
        table.sort(q)
        if #q > 0 then out[#out + 1] = "  Quelle: " .. table.concat(q, "  ") end
        local e = {}
        for k, v in pairs(DIAG.stat) do
            local w2 = k:match("^wegende_([%w_]+)$")
            if w2 then e[#e + 1] = ("%s=%d"):format(w2, v.n) end
        end
        table.sort(e)
        if #e > 0 then out[#out + 1] = "  Ende: " .. table.concat(e, "  ") end
    end

    local lo, ld = DIAG.stat.leiter_ok, DIAG.stat.leiter_daneben
    if (lo and lo.n or 0) + (ld and ld.n or 0) > 0 then
        out[#out + 1] = "-- Leitern --"
        out[#out + 1] = ("  geklettert %d, danebengelaufen %d, abgebrochen %d")
            :format(lo and lo.n or 0, ld and ld.n or 0,
                    (DIAG.stat.leiter_abbruch or {}).n or 0)
        out[#out + 1] = "  dichteste Annaeherung  " .. diagAvgTxt("leiter_daneben", "min", " Studs")
        out[#out + 1] = "  Tempo dabei            " .. diagAvgTxt("leiter_daneben", "spd", " Studs/s")
        out[#out + 1] = "  Tempo beim Greifen     " .. diagAvgTxt("leiter_ok", "spd", " Studs/s")
    end
    out[#out + 1] = "-- letzte Ereignisse --"
    for i = math.max(1, #DIAG.ring - 25), #DIAG.ring do
        out[#out + 1] = "  " .. DIAG.ring[i]
    end
    local txt = table.concat(out, "\n")
    DIAG.ring[#DIAG.ring + 1] = txt
    DIAG.dirty = true
    diagFlush(true)
    return txt
end

function ENV.diagReset()
    DIAG.stat, DIAG.ring, DIAG.wp, DIAG.lad = {}, {}, nil, nil
    DIAG.dirty = true
    diagFlush(true)
    return "Diagnose zurueckgesetzt"
end

------------------------------------------------------------------
-- 3) Rollen-Logik: wer darf wen taggen?
------------------------------------------------------------------
local function myRole()
    local r = LP:FindFirstChild("PlayerRole")
    return r and r.Value or nil
end

local function tagTablesOf(role)
    local gd = RENV.shared.gamemodeData
    local rd = gd and gd.Roles and gd.Roles[role]
    return rd and rd.TagTables or nil
end

-- true wenn Rolle A die Rolle B taggen darf.
-- Jeder Gamemode definiert das in gamemodeData.Roles[A].TagTables; GetTagTable
-- loest dabei auch "Not-<Rolle>" (Team-Modi) und RoleTags korrekt auf.
-- Keine TagTables = diese Rolle taggt niemanden (z.B. Crown im Crown-Modus).
local function canTag(a, b)
    if not a or not b or a == "" or b == "" then return false end
    local gd = RENV.shared.gamemodeData
    -- Ohne passende Gamemode-Daten wird NICHTS angenommen. Sonst gilt beim
    -- Voting/Rundenwechsel (alte Rollen, neuer Mode) jeder als Faenger UND Opfer.
    if not (gd and gd.Roles) then return false end
    if not (gd.Roles[a] and gd.Roles[b]) then return false end
    local tt = tagTablesOf(a)
    if not tt then return false end
    return Utils.GetTagTable(tt, b) ~= nil
end

-- gehoert meine Rolle ueberhaupt zum laufenden Modus? (sonst: alles neutral)
local function inLiveRound()
    local gd = RENV.shared.gamemodeData
    local r = myRole()
    return (gd and gd.Roles and r and gd.Roles[r] ~= nil) and true or false
end

local function hrpOf(pl)
    local c = pl.Character
    return c and c:FindFirstChild("HumanoidRootPart")
end

-- Laufender Zustand (frueh deklariert: scanField schreibt hier mit)
local state = {
    speedMul = 1, reach = 7, spread = 1,
    threatD = nil, preyD = nil, lastTag = 0,
    role = nil, nThreat = 0, nPrey = 0,
}
ENV.state = state

-- Fremde Charaktere melden auf dem Client fast immer Velocity 0. Deshalb wird
-- die tatsaechliche Geschwindigkeit ueber Positionsdeltas selbst gemessen —
-- entscheidend, um echte Verfolger von stehenden (eingefroren/AFK) zu trennen.
local velTrack = {}
local function speedOf(pl, hrp)
    local e = velTrack[pl]
    local now = tick()
    if not e then
        velTrack[pl] = { pos = hrp.Position, t = now, sp = 0 }
        return 0
    end
    local dt = now - e.t
    if dt >= 0.25 then
        local d = ((hrp.Position - e.pos) * Vector3.new(1, 0, 1)).Magnitude
        -- geglättet, damit einzelne Replikationsspruenge nicht durchschlagen
        e.sp = e.sp * 0.4 + (d / dt) * 0.6
        e.pos, e.t = hrp.Position, now
    end
    return e.sp
end

-- naechster Faenger (kann MICH taggen) und naechstes Opfer (kann ICH taggen)
local function scanField()
    -- Die eigene Rolle wechselt mitten in der Runde (getaggt werden, Infected,
    -- Freeze, Crown weitergeben ...) — deshalb wird sie hier JEDEN Frame neu
    -- gelesen und die Beziehungen komplett neu bestimmt.
    local me = hrpOf(LP)
    local mine = myRole()
    if not me or not mine or not inLiveRound() then
        state.role, state.nThreat, state.nPrey = nil, 0, 0
        return nil, nil, nil, nil
    end
    local myPos = me.Position
    local threat, threatD, prey, preyD
    local nThreat, nPrey = 0, 0
    local threats = {}
    local preys = {}
    for _, pl in ipairs(Players:GetPlayers()) do
        if pl ~= LP then
            local rv = pl:FindFirstChild("PlayerRole")
            local h  = hrpOf(pl)
            if rv and h then
                local their = rv.Value
                local d = (h.Position - myPos).Magnitude
                if canTag(their, mine) then
                    nThreat = nThreat + 1
                    if not threatD or d < threatD then threat, threatD = pl, d end
                    -- alle Faenger in der Naehe merken: die Fluchtrichtung wird
                    -- aus der Summe aller Verfolger gebildet, nicht nur aus dem
                    -- naechsten (sonst laeuft man dem zweiten direkt vors Messer)
                    if d < 90 then
                        -- Ein Verfolger, der sich nicht bewegt (eingefroren,
                        -- gefangen, AFK), ist keine echte Gefahr. Im Freeze-Modus
                        -- ist das entscheidend: Frozen duerfen von Runnern
                        -- getaggt (aufgetaut) werden und stehen dabei still.
                        local vel = speedOf(pl, h)
                        threats[#threats + 1] = { pos = h.Position, d = d, mobile = vel > 4, sp = vel }
                    end
                end
                -- NoTagBack schliesst das Ziel NICHT vom Verfolgen aus (sonst
                -- verliert der Autopilot die Krone direkt nach jedem Wechsel) —
                -- es verhindert nur das Zuschlagen, siehe Auto-Tag.
                if canTag(mine, their) then
                    nPrey = nPrey + 1
                    -- Ziele, an die er nachweislich nicht herankommt (z.B. weit
                    -- oben ohne Weg), werden kurz uebersprungen statt endlos
                    -- gegen eine Wand zu laufen.
                    local skipUntil = state.skipPrey and state.skipPrey[pl]
                    if skipUntil and tick() > skipUntil then
                        state.skipPrey[pl] = nil       -- abgelaufen: aufraeumen
                        skipUntil = nil
                    end
                    if not (skipUntil and tick() < skipUntil) then
                        if not preyD or d < preyD then prey, preyD = pl, d end
                    end
                    -- fuer die Fluchtroute: Ziele, die man im Vorbeigehen
                    -- mitnehmen kann. Wer selbst taggen darf, ist riskanter.
                    if d < 120 then
                        preys[#preys + 1] = {
                            pos = h.Position, d = d, pl = pl,
                            -- ein eingefrorenes/stehendes Ziel ist nie riskant,
                            -- auch wenn die Tabelle sagt, es duerfte taggen
                            risky = canTag(their, mine) and speedOf(pl, h) > 4,
                        }
                    end
                end
            end
        end
    end
    state.role, state.nThreat, state.nPrey = mine, nThreat, nPrey
    state.threats = threats
    state.preys = preys
    return threat, threatD, prey, preyD
end

------------------------------------------------------------------
-- 3b) AUTOPILOT: selbst weglaufen bzw. verfolgen
--     Steuert ueber den ganz normalen Bewegungs-Input des Spiels
--     (controlModule:GetMoveVector) — kein Teleport, kein CFrame-Setzen.
------------------------------------------------------------------
local AP = {
    mode = nil,            -- "FLUCHT" | "JAGD" | nil
    vec = nil,             -- kamerarelativer Move-Vektor
    manualUntil = 0,       -- eigener Input hat Vorrang
    lastJump = 0,
    rp = RaycastParams.new(),
    rpAt = 0,
}
AP.rp.FilterType = Enum.RaycastFilterType.Exclude
AP.rp.RespectCanCollide = true   -- unsichtbare Zonen sind keine Waende
ENV.ap = AP

local NODES = { inst = nil, list = {}, busy = false, minY = 0, maxY = 0 }

-- Mittelpunkt und Radius der aktuellen Map (gecacht, neu bei Map-Wechsel).
-- Dient dazu, beim Weglaufen nicht in Ecken/an den Rand zu geraten.
local mapCache = { inst = nil, center = nil, radius = nil, busy = false }
local function playfield()
    if NODES and NODES.center then return NODES.center, NODES.radius end
    return nil
end

local function mapCenterRadius()
    local cm = workspace:FindFirstChild("CurrentMap")
    local child = cm and cm:GetChildren()[1]
    if not child then return nil end
    if mapCache.inst == child and mapCache.center then
        return mapCache.center, mapCache.radius
    end
    -- Schnellweg: Engine-Boundingbox (kein Durchlaufen tausender Teile)
    if child:IsA("Model") then
        local ok, cf, size = pcall(function()
            local a, b = child:GetBoundingBox()
            return a, b
        end)
        if ok and cf and size and size.Magnitude > 1 then
            local span = size * Vector3.new(1, 0, 1)
            mapCache.inst = child
            mapCache.center = cf.Position
            mapCache.radius = math.max(span.Magnitude * 0.5, 40)
            mapCache.min = cf.Position - size * 0.5
            mapCache.max = cf.Position + size * 0.5
            LOG(("Map vermessen: Radius %.0f Studs (Boundingbox)"):format(mapCache.radius))
            return mapCache.center, mapCache.radius
        end
    end
    -- Langweg (Folder statt Model): asynchron, damit der Frame nicht haengt
    if mapCache.busy then return nil end
    mapCache.busy = true
    task.spawn(function()
    local minv, maxv
    local n = 0
    for _, d in ipairs(child:GetDescendants()) do
        if d:IsA("BasePart") and d.Size.Magnitude < 3000 then
            n = n + 1
            local pmin = d.Position - d.Size * 0.5
            local pmax = d.Position + d.Size * 0.5
            minv = minv and Vector3.new(math.min(minv.X, pmin.X), math.min(minv.Y, pmin.Y), math.min(minv.Z, pmin.Z)) or pmin
            maxv = maxv and Vector3.new(math.max(maxv.X, pmax.X), math.max(maxv.Y, pmax.Y), math.max(maxv.Z, pmax.Z)) or pmax
            if n > 6000 then break end
        end
    end
    if minv then
        local center = (minv + maxv) * 0.5
        local span = (maxv - minv) * Vector3.new(1, 0, 1)
        mapCache.inst, mapCache.center, mapCache.radius = child, center, math.max(span.Magnitude * 0.5, 40)
        mapCache.min, mapCache.max = minv, maxv
        LOG(("Map vermessen: Radius %.0f Studs (%d Teile)"):format(mapCache.radius, n))
    end
    mapCache.busy = false
    end)
    return nil
end

------------------------------------------------------------------
-- 3c) PATHFINDING
--     Die lokale Steuerung ist gierig und kommt aus konkaver Geometrie
--     (Hoehle, Raum mit einem Ausgang) prinzipiell nicht heraus. Fuer weite
--     Wege und beim Haengenbleiben uebernimmt deshalb ein echter Pfad.
------------------------------------------------------------------
-- Leitern der Map (TrussPart) einmal pro Map einsammeln
local ladderCache = { inst = nil, list = {}, busy = false }
local function ladders()
    local cm = workspace:FindFirstChild("CurrentMap")
    local child = cm and cm:GetChildren()[1]
    if not child then return {} end
    if ladderCache.inst == child then return ladderCache.list end
    if ladderCache.busy then return {} end
    ladderCache.busy = true
    task.spawn(function()
        local list = {}
        for _, d in ipairs(child:GetDescendants()) do
            if d:IsA("TrussPart") then list[#list + 1] = d end
        end
        ladderCache.inst, ladderCache.list = child, list
        ladderCache.busy = false
        LOG(("Leitern in der Map: %d"):format(#list))
    end)
    return {}
end

------------------------------------------------------------------
-- 3d) FLUCHT-ROUTENPLANUNG
--     Statt stur in die Gegenrichtung zu rennen (Beeline, endet in Ecken und
--     Kartenraendern) wird die Map einmal in ein Punktraster vermessen und
--     beim Fliehen ein ZIELPUNKT gewaehlt: weit weg von allen Verfolgern,
--     moeglichst mittig und moeglichst hoch. Dorthin wird gepfadet.
------------------------------------------------------------------


local function buildNodes()
    local cm = workspace:FindFirstChild("CurrentMap")
    local child = cm and cm:GetChildren()[1]
    if not child then return end
    local hrpNow = hrpOf(LP)
    local levelChanged = NODES.refY and hrpNow
        and math.abs(hrpNow.Position.Y - NODES.refY) > 70
    if (NODES.inst == child and not levelChanged) or NODES.busy then return end
    if not (mapCache.min and mapCache.max and mapCache.inst == child) then return end
    -- Bezugshoehe = die Ebene, auf der wir gerade spielen. Von der Map-Oberkante
    -- nach unten zu strahlen trifft in vielen Maps nur die Dachkonstruktion —
    -- die Punkte liegen dann hunderte Studs ueber dem Spielfeld und jeder Pfad
    -- dorthin scheitert.
    local meHrp = hrpOf(LP)
    if not meHrp then return end
    local refY = meHrp.Position.Y
    NODES.busy = true
    local mn, mx = mapCache.min, mapCache.max
    task.spawn(function()
        local list = {}
        -- feines Raster: sonst landen die Punkte nur auf freiem Boden und
        -- Daecher/Plattformen (das "oben bleiben") fallen komplett durch
        local steps = 34
        local topY = math.min(refY + 70, mx.Y + 60)
        local reach = 220
        local rp = RaycastParams.new()
        rp.FilterType = Enum.RaycastFilterType.Exclude
        rp.RespectCanCollide = true
        local ig = { workspace.CurrentCamera }
        for _, pl in ipairs(Players:GetPlayers()) do
            if pl.Character then ig[#ig + 1] = pl.Character end
        end
        rp.FilterDescendantsInstances = ig
        local minY, maxY
        for ix = 0, steps do
            for iz = 0, steps do
                local x = mn.X + (mx.X - mn.X) * (ix / steps)
                local z = mn.Z + (mx.Z - mn.Z) * (iz / steps)
                -- zusaetzlich von weiter oben strahlen, damit auch Daecher und
                -- Plattformen ueber der eigenen Ebene als Punkte auftauchen
                local hiHit = workspace:Raycast(Vector3.new(x, math.min(refY + 190, mx.Y + 40), z),
                                                Vector3.new(0, -120, 0), rp)
                if hiHit and hiHit.Position.Y > refY + 12 then
                    local hp = hiHit.Position + Vector3.new(0, 2.5, 0)
                    list[#list + 1] = hp
                    minY = minY and math.min(minY, hp.Y) or hp.Y
                    maxY = maxY and math.max(maxY, hp.Y) or hp.Y
                end
                local hit = workspace:Raycast(Vector3.new(x, topY, z),
                                              Vector3.new(0, -reach, 0), rp)
                if hit then
                    local pnt = hit.Position + Vector3.new(0, 2.5, 0)
                    list[#list + 1] = pnt
                    minY = minY and math.min(minY, pnt.Y) or pnt.Y
                    maxY = maxY and math.max(maxY, pnt.Y) or pnt.Y
                end
            end
            if ix % 2 == 0 then task.wait() end   -- haeppchenweise, kein Frame-Hitch
        end
        NODES.inst, NODES.list, NODES.refY = child, list, refY
        NODES.minY, NODES.maxY = minY or 0, math.max(maxY or 1, (minY or 0) + 1)
        -- Schwerpunkt und Radius der BEGEHBAREN Flaeche. Die Bounding-Box aller
        -- Map-Teile ist dafuer unbrauchbar (Deko, Skybox) — der Mitte-Zug
        -- wuerde erst weit ausserhalb des Spielfelds anspringen.
        if #list > 8 then
            local sum = Vector3.zero
            for _, n in ipairs(list) do sum = sum + n end
            local c = sum / #list
            local ds = {}
            for _, n in ipairs(list) do
                ds[#ds + 1] = ((n - c) * Vector3.new(1, 0, 1)).Magnitude
            end
            table.sort(ds)
            NODES.center = c
            NODES.radius = math.max(ds[math.floor(#ds * 0.85)] or 60, 40)
            LOG(("Spielfeld: Mitte bei %d/%d, Radius %.0f Studs")
                :format(math.floor(c.X), math.floor(c.Z), NODES.radius))
        end
        NODES.busy = false
        LOG(("Fluchtpunkte vermessen: %d Punkte, Hoehe %.0f..%.0f (Ebene %.0f)")
            :format(#list, NODES.minY, NODES.maxY, refY))
    end)
end

-- bester Fluchtpunkt: weit weg von allen Verfolgern, mittig, hoch, erreichbar
-- Fluchtziel aus dem NAVIGATIONSGRAPHEN.
-- Das alte Punktraster kannte nur Positionen. Der Graph kennt auch, wie
-- viele Wege von einem Punkt wegfuehren — und genau das fehlte: ohne
-- dieses Wissen landete der Bot regelmaessig in Ecken und lief davor hin
-- und her. Bewertet wird deshalb nach Hoehe (oben ist man schwerer zu
-- fangen), Abstand zu den Verfolgern und Anzahl der Auswege.
-- HOEHE IST DER BESTE ABSTAND.
-- Zehn Studs horizontal sind bei 32 Studs/s in einer Drittelsekunde weg. Zehn
-- Studs HOEHE muss ein Verfolger dagegen erst einmal ueberwinden: er braucht
-- eine Leiter, ein Trampolin oder einen weiten Umweg, und auf dem Weg dorthin
-- verliert er die Sichtlinie. Deshalb zaehlt der Hoehenunterschied im
-- Fluchtabstand ein Vielfaches des horizontalen.
local VERT_W = 3.5
local function threatGap(a, b)
    local dxz = ((a - b) * Vector3.new(1, 0, 1)).Magnitude
    local dy = (a.Y - b.Y) * VERT_W
    return math.sqrt(dxz * dxz + dy * dy)
end

-- VORSPRUNGSFELD. Zwei Kostenfelder ueber denselben Graphen: eines von mir
-- aus, eines vom naechsten Verfolger aus. Die Differenz je Knoten sagt, wie
-- viele Sekunden Vorsprung ich dort haette. Genau das ist "unfangbar": nicht
-- weit weg sein, sondern an einem Punkt stehen, den der andere nur ueber
-- einen langen Umweg erreicht.
-- Gerechnet wird im Hintergrund und hoechstens alle 2.5 Sekunden, ein Feld
-- kostet rund 40 ms.
local LEAD = { at = 0, mine = nil, theirs = nil, from = nil, busy = false }
local function leadField(pos, threats)
    local NG = getgenv().__UTG_NAV_GRAPH
    if not NG or not NG.graph or not NG.costField then return nil end
    local t = threats and threats[1]
    if not t then return nil end
    -- naechsten Verfolger nehmen
    local best, bd = nil, 1e9
    for _, x in ipairs(threats) do
        local dd = (x.pos - pos).Magnitude
        if dd < bd then best, bd = x, dd end
    end
    if not best then return nil end
    local now = tick()
    local stale = (now - LEAD.at > 2.5)
        or (LEAD.from and (LEAD.from - best.pos).Magnitude > 40)
    if not stale or LEAD.busy then return LEAD.mine and LEAD end
    LEAD.busy = true
    task.spawn(function()
        local okA, mine = pcall(NG.costField, pos, 6000)
        local okB, theirs = pcall(NG.costField, best.pos, 6000)
        if okA and okB and mine and theirs then
            LEAD.mine, LEAD.theirs, LEAD.from, LEAD.at = mine, theirs, best.pos, tick()
        end
        LEAD.busy = false
    end)
    return LEAD.mine and LEAD or nil
end

local function pickEscapeGraph(pos, threats)
    local NG = getgenv().__UTG_NAV_GRAPH
    local G = NG and NG.graph
    if not G or #G.nodes < 50 then return nil end
    local lead = leadField(pos, threats)
    local bestLead = 0
    local best, bestScore
    local n = #G.nodes
    -- Stichprobe statt aller Knoten: bei 28000 waere das jede Sekunde zu teuer
    local tries = math.min(260, n)
    for _ = 1, tries do
        local nd = G.nodes[math.random(1, n)]
        if not nd.bad then
            local flat = (nd.p - pos) * Vector3.new(1, 0, 1)
            local dist = flat.Magnitude
            if dist > 25 and dist < 320 then
                -- Auswege zaehlen: ein Punkt mit zwei Kanten ist eine Ecke
                local ways = #nd.e
                if ways >= 4 then
                    -- Abstand zum naechsten Verfolger, und niemand darf
                    -- naeher am Ziel sein als wir
                    local nearestThreat, blockedBy = math.huge, false
                    local overThreat = 0
                    for _, t in ipairs(threats or {}) do
                        -- Hoehe zaehlt im Abstand mit (siehe threatGap)
                        local dt = threatGap(nd.p, t.pos)
                        if dt < nearestThreat then
                            nearestThreat = dt
                            overThreat = nd.p.Y - t.pos.Y
                        end
                        if dt < dist * 0.75 then blockedBy = true end
                    end
                    if not blockedBy then
                        local up = nd.p.Y - pos.Y
                        -- VORSPRUNG IN SEKUNDEN: was braucht er dorthin,
                        -- was brauche ich? Das ist der staerkste Term im
                        -- ganzen Urteil — ein Punkt mit zehn Sekunden
                        -- Vorsprung schlaegt jeden, der nur hoch liegt.
                        local leadSec = 0
                        if lead and lead.mine and lead.theirs then
                            local a, b = lead.mine[nd.id], lead.theirs[nd.id]
                            if a and b then
                                leadSec = b - a
                            elseif a and not b then
                                -- er kommt ueberhaupt nicht hin
                                leadSec = 20
                            end
                        end
                        local score =
                              math.clamp(leadSec, -10, 25) * 6.0
                            + math.min(up, 60) * 2.2          -- Hoehe zaehlt stark
                            -- und noch staerker: wie hoch liegt der Punkt
                            -- UEBER dem naechsten Verfolger. Darauf kommt es
                            -- an, nicht auf die eigene Ausgangshoehe.
                            + math.clamp(overThreat, -40, 70) * 4.0
                            + math.min(nearestThreat, 200) * 0.9
                            + math.min(ways, 12) * 3.0        -- viele Auswege
                            - dist * 0.25                     -- nicht ans Kartenende
                        if not bestScore or score > bestScore then
                            best, bestScore, bestLead = nd.p, score, leadSec
                        end
                    end
                end
            end
        end
    end
    if best and ENV.diagEvent then
        ENV.diagEvent("fluchtziel", ("%.1f"):format(bestLead),
                      ("%.0f"):format(best.Y - pos.Y),
                      ("%.0f"):format((best - pos).Magnitude),
                      lead and "mit Vorsprungsfeld" or "ohne Feld")
    end
    return best
end

local function pickEscapeNode(pos, threats, preys)
    local list = NODES.list
    if not list or #list < 8 then return nil end
    local center, radius = mapCache.center, mapCache.radius
    if not center then return nil end
    local hSpan = math.max(NODES.maxY - NODES.minY, 1)
    local best, bestScore
    for _, n in ipairs(list) do
        local toNode = (n - pos) * Vector3.new(1, 0, 1)
        local dMe = toNode.Magnitude
        local dY = n.Y - pos.Y
        if dMe > 25 and dMe < 320 and dY > -60 and dY < 45 then
            -- Abstand zum naechsten Verfolger an diesem Punkt
            local dThreat, overThreat = 1e9, 0
            for _, t in ipairs(threats) do
                local d = threatGap(n, t.pos)      -- Hoehe zaehlt mit
                if d < dThreat then
                    dThreat = d
                    overThreat = n.Y - t.pos.Y
                end
            end
            -- laeuft der Weg dorthin an einem Verfolger vorbei? (grober Test)
            local pass = 0
            for _, t in ipairs(threats) do
                local v = (t.pos - pos) * Vector3.new(1, 0, 1)
                local proj = v:Dot(toNode.Unit)
                if proj > 0 and proj < dMe then
                    local perp = (v - toNode.Unit * proj).Magnitude
                    if perp < 22 then pass = pass + (22 - perp) / 22 end
                end
            end
            -- Mitnahme-Bonus: liegt ein taggbares Ziel am/neben dem Punkt,
            -- wird er attraktiver (sicheres Ziel staerker als eines, das
            -- selbst taggen darf)
            local grab = 0
            for _, q in ipairs(preys or {}) do
                local dq = ((n - q.pos) * Vector3.new(1, 0, 1)).Magnitude
                if dq < 45 then
                    local w = (45 - dq) / 45
                    grab = math.max(grab, q.risky and w * 0.45 or w)
                end
            end
            local centrality = 1 - math.clamp(((n - center) * Vector3.new(1, 0, 1)).Magnitude / radius, 0, 1)
            local height = (n.Y - NODES.minY) / hSpan
            -- Punkte, an denen ein Jaeger schon fast klebt, fallen ganz raus
            local tooClose = (dThreat < 45) and 1 or 0
            local score = math.min(dThreat, 220) / 220 * 4.5   -- Abstand zu Jaegern
                        - tooClose * 3.0
                        + centrality * 2.2                      -- mittig bleiben
                        + height * 1.8                          -- hoch bleiben
                        -- entscheidend: ueber dem Verfolger stehen
                        + math.clamp(overThreat / 20, -2, 3.5) * 3.2
                        - math.clamp(dMe / 320, 0, 1) * 0.8     -- nicht unnoetig weit
                        - pass * 2.5                            -- nicht am Jaeger vorbei
                        + grab * 1.6                            -- Opfer im Vorbeigehen mitnehmen
            if not bestScore or score > bestScore then best, bestScore = n, score end
        end
    end
    return best, bestScore
end

-- Bewegungs-Hilfen der Map. Ausloeser laut Spielcode:
--   Zipline  : Parent-Attribut "Zipline", greift automatisch ab 5 Studs Naehe
--   Jumppad  : Attribut BounceAmount / RelativeBounceAmount, wirkt bei Kontakt
--   Rail     : Attribut RailGrind, greift beim Landen darauf
--   SwingBar : Attribut SwingBar, greift bei Kontakt
local helpCache = { inst = nil, list = {}, busy = false }
local function helpers()
    local cm = workspace:FindFirstChild("CurrentMap")
    local child = cm and cm:GetChildren()[1]
    if not child then return {} end
    if helpCache.inst == child then return helpCache.list end
    if helpCache.busy then return {} end
    helpCache.busy = true
    task.spawn(function()
        local list = {}
        local nz, np, nr, ns = 0, 0, 0, 0
        for _, d in ipairs(child:GetDescendants()) do
            if d:IsA("BasePart") then
                local kind, weight
                if d.Parent and d.Parent:GetAttribute("Zipline") then
                    kind, weight = "zip", 2.6 ; nz = nz + 1
                elseif d:GetAttribute("BounceAmount") or d:GetAttribute("RelativeBounceAmount") then
                    kind, weight = "pad", 2.2 ; np = np + 1
                elseif d:GetAttribute("RailGrind") then
                    kind, weight = "rail", 1.6 ; nr = nr + 1
                elseif d:GetAttribute("SwingBar") then
                    kind, weight = "bar", 1.2 ; ns = ns + 1
                end
                if kind then list[#list + 1] = { part = d, kind = kind, w = weight } end
            end
        end
        helpCache.inst, helpCache.list, helpCache.busy = child, list, false
        LOG(("Bewegungshilfen: %d Zipline-Teile, %d Jumppads, %d Rails, %d SwingBars"):format(nz, np, nr, ns))
    end)
    return {}
end

-- Sprung ausloesen, aber niemals waehrend des Kletterns: ein Sprung an der
-- Leiter/Wand bedeutet loslassen — genau davon faellt er runter.
local function tryJump(force)
    local char = LP.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if hum and hum:GetState() == Enum.HumanoidStateType.Climbing and not force then return end
    if RENV.shared.touchingTruss and not force then return end
    -- Gemessen: 22 Spruenge pro Minute, davon 20 von 29 ohne jeden
    -- Wegbezug — die freie Steuerung sprang praktisch dauernd. Ergebnis
    -- waren 42 % Luftzeit, und in der Luft ist die Steuerung traege: genau
    -- daher die vielen kleinen Haenger. Ein Sprung ohne konkreten Anlass
    -- braucht deshalb Abstand zum vorigen; erzwungene Spruenge (Parkour,
    -- Wegpunkte mit Sprungmarke) bleiben unberuehrt.
    if not force then
        local nowJ = time()
        if AP.lastFreeJump and nowJ - AP.lastFreeJump < 0.85 then return end
        AP.lastFreeJump = nowJ
    end
    RENV.shared.jumpMobileTap = time() + 0.12
end


------------------------------------------------------------------

------------------------------------------------------------------

------------------------------------------------------------------

------------------------------------------------------------------

------------------------------------------------------------------

------------------------------------------------------------------

------------------------------------------------------------------

------------------------------------------------------------------

------------------------------------------------------------------

------------------------------------------------------------------

------------------------------------------------------------------

------------------------------------------------------------------

------------------------------------------------------------------

------------------------------------------------------------------

------------------------------------------------------------------

------------------------------------------------------------------

------------------------------------------------------------------

------------------------------------------------------------------

------------------------------------------------------------------

------------------------------------------------------------------

------------------------------------------------------------------
-- 3c-2) EIGENER NAVIGATIONSGRAPH
--     PathfindingService kennt keine der Fortbewegungsarten dieses
--     Spiels (Wallrun, Zipline, Jumppad, Rail, SwingBar) und findet
--     Ziele ueber 25 Studs Hoehenunterschied so gut wie nie.
--     Gemessen auf CrossPaths gegen 14 hoch gelegene Ziele:
--         PathfindingService   5/14, 100-160 ms je Anfrage
--         dieser Graph        14/14,   12 ms je Anfrage
--     Kanten sind typisiert (walk/jump/drop/climb/wallrun/zip/pad),
--     die Kosten sind SEKUNDEN statt Studs — eine Zipline mit 40
--     Studs/s ist damit billiger als derselbe Weg zu Fuss.
--     Der do-Block kapselt alle Hilfsnamen des Graphen ab.
------------------------------------------------------------------
local NAV
do
    NAV = {}
    getgenv().__UTG_NAV_GRAPH = NAV
    
    ------------------------------------------------------------------
    -- 1) Bewegungsprofil — aus dem Spiel gelesen, nicht geraten
    ------------------------------------------------------------------
    -- SPRUNGKRAFT HAENGT AN DER LAUFGESCHWINDIGKEIT.
    -- Gemessen (260 Proben, 2026-09-18): JumpPower folgt der WalkSpeed mit
    -- einem Verhaeltnis von 0.79 bis 0.91, im Mittel 0.86 —
    --     WalkSpeed 31-36 -> JumpPower 28.8 bis 30.1
    --     WalkSpeed 44    -> JumpPower 36.4
    -- Weil die Flugzeit an vy haengt und die Weite an Tempo mal Flugzeit,
    -- waechst die Sprungweite QUADRATISCH mit dem Tempo:
    --     reach = speed * 2*vy/g = 1.72 * speed^2 / g
    -- Bei 32 Studs/s sind das 25 Studs, bei 37 schon 33. Wird das Profil im
    -- Stand gelesen (JumpPower ~28.5), faellt der Graph zu vorsichtig aus:
    -- Sprungkanten, die der Bot im Lauf locker schafft, entstehen nie.
    local JP_PER_WS = 0.86

    local function profile()
        local char = LP.Character
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        local g = math.max(workspace.Gravity, 1)          -- gemessen 71.25
        -- Renntempo: was der Charakter wirklich laeuft, nicht die feste 32
        local speed = 32
        if hum and hum.WalkSpeed and hum.WalkSpeed > 8 then
            speed = math.clamp(hum.WalkSpeed, 24, 44)
        end
        local vy = speed * JP_PER_WS
        if hum and hum.UseJumpPower and hum.JumpPower then
            vy = math.max(vy, hum.JumpPower)
        elseif hum then
            vy = math.max(vy, math.sqrt(2 * g * math.max(hum.JumpHeight, 1)))
        end
        local air = 2 * vy / g
        return {
            g = g, vy = vy, speed = speed,
            air = air,
            reach = speed * air,      -- flache Sprungweite, hier ~25 Studs
            rise = (vy * vy) / (2 * g),  -- Sprunghoehe, hier ~5.5 Studs
            climbSpeed = 8,           -- Leiter
            railSpeed = 42,           -- Grindschiene (geschaetzt, wie Zipline)
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
    
    local SIDE4 = { Vector3.new(1,0,0), Vector3.new(-1,0,0),
                    Vector3.new(0,0,1), Vector3.new(0,0,-1) }

    local function sampleNodes(bb, onProgress)
        local nodes, grid = {}, {}
        local narrow = 0        -- wegen zu wenig Platz verworfen
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
                        -- PASST DER CHARAKTER DORT UEBERHAUPT HIN?
                        -- Ein Strahl von oben trifft jede nach oben zeigende
                        -- Flaeche — auch die Oberkante einer Mauer, den Boden
                        -- einer Nische hinter Deko oder eine Luecke zwischen
                        -- zwei Teilen. Bisher wurde nur die Kopffreiheit
                        -- geprueft, nicht die Breite: genau daher stammen die
                        -- Wegpunkte, die im Spiel in einer Wand stecken.
                        -- Geprueft wird auf Huefthoehe nach vier Seiten; sind
                        -- drei davon naeher als 1.3 Studs zu, steht dort kein
                        -- Charakter (er ist rund zwei Studs breit). Eine Wand
                        -- an einer oder zwei Seiten ist normal und bleibt.
                        local fits = true
                        if (not ceil) or low then
                            local body = foot + Vector3.new(0, 2.2, 0)
                            local blocked = 0
                            for _, sd in ipairs(SIDE4) do
                                if cast(body, sd * 1.3) then blocked = blocked + 1 end
                            end
                            fits = blocked < 3
                            if not fits then narrow = narrow + 1 end
                        end
                        if ((not ceil) or low) and fits then
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
        return nodes, grid, cell, narrow
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
        local moved, offWall = 0, 0
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
            -- Faellt der Boden nach SECHS oder mehr Seiten weg, ist das keine
            -- Standflaeche mehr, sondern eine Mauerkrone oder ein Pfosten. Der
            -- Knoten bleibt (manchmal fuehrt oben herum wirklich der einzige
            -- Weg), wird aber so teuer, dass A* ihn nur im Notfall nimmt —
            -- sonst laufen Wege ueber Mauerkronen, und im Spiel sieht das aus
            -- wie ein Punkt in der Wand.
            if edges >= 6 then nd.bad = true end
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
            -- VON WAENDEN WEGSCHIEBEN. Das Abtastraster ist map-global und
            -- nicht an Waenden ausgerichtet: ein Knoten kann einen halben Stud
            -- vor einer Wand liegen. Der Charakter ist rund zwei Studs breit,
            -- sein Mittelpunkt kommt dort nie hin — im Spiel sieht so ein
            -- Wegpunkt aus, als steckte er in der Wand, und getroffen wird er
            -- nie. Also auf Koerperhoehe messen und so weit wegschieben, dass
            -- mindestens 1.4 Studs Luft bleiben, solange darunter dieselbe
            -- Flaeche liegt.
            local body = nd.p + Vector3.new(0, 2.2, 0)
            local away, walls = Vector3.zero, 0
            for _, sd in ipairs(SIDE4) do
                local h = cast(body, sd * 1.4)
                if h then
                    away = away - sd * (1.4 - (h.Position - body).Magnitude)
                    walls = walls + 1
                end
            end
            -- drei oder vier Seiten zu heisst Nische: da hilft Schieben nicht
            if walls >= 1 and walls <= 2 and away.Magnitude > 0.15 then
                local tgt = nd.p + away
                local under = cast(tgt + Vector3.new(0, 1.2, 0), Vector3.new(0, -4, 0))
                if under and math.abs(under.Position.Y - nd.p.Y) < 1.5 then
                    nd.p = under.Position + Vector3.new(0, 0.5, 0)
                    offWall = offWall + 1
                end
            end
            if i % 500 == 0 then breathe() end
        end
        return moved, offWall
    end
    
    ------------------------------------------------------------------
    -- 4) Kanten. Kosten sind SEKUNDEN.
    ------------------------------------------------------------------
    -- Wasser und Schadensflaechen: Strafaufschlag auf jede Kante, die DORTHIN
    -- fuehrt. In Sekunden gerechnet entspricht das einem langen Umweg, also
    -- meidet A* sie zuverlaessig, ohne dass sie ganz unpassierbar werden.
    local DANGER_COST = 25.0   -- Wasser wird damit praktisch immer umgangen
    local JUMP_EDGE_MAX = 10      -- flach; darueber landet er gemessen nicht
    local function addEdge(a, b, kind, cost, via)
        -- HARTE SICHERUNG. Im fertigen Graphen standen Sprungkanten von bis
        -- zu 204 Studs — irgendein Bauteil hat die Laengengrenze umgangen.
        -- Statt jede Stelle einzeln zu pruefen, faengt es die eine Stelle
        -- ab, durch die alle Kanten laufen: zu weit nach oben oder zur
        -- Seite gibt es keinen Sprung, nach unten wird daraus ein Fall.
        if kind == "jump" or kind == "hop" or kind == "vault" then
            local flat = ((b.p - a.p) * Vector3.new(1, 0, 1)).Magnitude
            if flat > JUMP_EDGE_MAX then
                if b.p.Y < a.p.Y - 2 then kind = "drop" else return end
            end
        end
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
        -- Auf DREI Hoehen pruefen, nicht nur auf Huefthoehe. In Hoehlen und an
        -- unregelmaessigen Waenden sitzen die Hindernisse ueber oder unter der
        -- Huefte - der Weg galt dann als frei und fuehrte mitten hindurch.
        for _, h in ipairs({ 0, -1.5, 1.6 }) do
            local lift = Vector3.new(0, h, 0)
            for _, w in ipairs({ 0, CORRIDOR, -CORRIDOR }) do
                local shift = o + side * w + lift
                if cast(a + shift, (c + shift) - (a + shift)) then return false end
            end
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
        local walk, hop, step, vault = 0, 0, 0, 0
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
                        elseif dy > prof.rise and dy <= prof.rise + 9
                               and ((o.p - n.p) * Vector3.new(1,0,1)).Magnitude <= 6 then
                            -- VAULT. Das Spiel zieht einen ueber eine Kante,
                            -- gegen die man im Sprung laeuft, und gibt dabei
                            -- das 2.4-fache Momentum (VaultMomentumMultiplier).
                            -- Damit sind Absaetze erreichbar, die fuer einen
                            -- blossen Sprung zu hoch sind — genau die
                            -- Vertikalitaet, die den Verfolger abhaengt.
                            -- Bedingung: zwischen beiden Knoten steht eine
                            -- Wand (sonst gibt es nichts zu greifen), und
                            -- ueber dem Ziel ist Platz.
                            local face = cast(n.p + Vector3.new(0, 2.2, 0),
                                              ((o.p - n.p) * Vector3.new(1,0,1)))
                            local headroom = not cast(o.p + Vector3.new(0, 0.5, 0),
                                                      Vector3.new(0, CFG.agentHeight, 0))
                            if face and headroom then
                                addEdge(n, o, "vault", dist / prof.speed + 0.45, via)
                                vault = vault + 1
                            end
                        elseif dy > CFG.stepUp and dy <= prof.rise
                               and ((o.p - n.p) * Vector3.new(1,0,1)).Magnitude <= 9 then
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
        return walk, hop, step, vault
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
        -- WEITE SPRUENGE TRAGEN NICHT — GEMESSEN.
        -- Ueber 176 Spruenge aus echten Runden: bis 8 Studs Luecke landen
        -- 96 bis 100 Prozent, 8 bis 14 Studs noch ordentlich, ab 14 Studs
        -- nur noch 16 bis 18 Prozent. Die Physik gaebe mehr her (reach
        -- rechnet 33 Studs), die Steuerung aber nicht: in der Luft driftet
        -- er, und der Landeknoten liegt oft auf einer schmalen Kante.
        -- Der Graph bekommt deshalb nur Sprungkanten, die auch ankommen —
        -- alles Weitere geht ueber Umwege, Leitern oder Faelle.
        -- Nachgemessen an 3666 Ereignissen: bis 8 Studs landen 96 Prozent,
        -- 8 bis 14 Studs nur 31, darueber 18. Und jeder misslungene Sprung
        -- kostet den ganzen Weg: "absprung_verpasst" und "sprung_daneben"
        -- zusammen waren 20 Prozent aller Wegenden. Der Deckel geht deshalb
        -- auf 9 Studs — das ist der Bereich, in dem es wirklich klappt.
        local JUMP_MAX = 9
        local reachCap = math.min(prof.reach * 0.9, JUMP_MAX)
        local span = math.ceil(reachCap / cell)
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
                                if flat <= reachCap and math.abs(dy) > CFG.stepUp then
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
        -- 4f) RAILS (Grindschienen).
        -- Gemessen auf Craigville: 15 Gruppen "RailgrindBeam" (Model) mit je
        -- ein bis sieben Teilen "RailPart", lange duenne Balken von 14 bis 57
        -- Studs entlang ihrer laengsten Achse, CanCollide = false. Das
        -- Attribut RailGrind traegt wie bei der Zipline das ELTERNTEIL.
        -- Ausgeloest wird der Grind, indem man auf der Schiene landet — also
        -- wird ihr Ende als Knoten angebunden und der Weg dorthin gesprungen.
        local rails = 0
        for _, d in ipairs(mapRoot:GetDescendants()) do
            if d:IsA("BasePart") and d.Parent
               and d.Parent:GetAttribute("RailGrind") ~= nil then
                -- laengste Achse ist die Fahrtrichtung
                local sz, cf = d.Size, d.CFrame
                local axis, len = cf.RightVector, sz.X
                if sz.Y > len then axis, len = cf.UpVector, sz.Y end
                if sz.Z > len then axis, len = cf.LookVector, sz.Z end
                if len > 6 then
                    local e1 = d.Position + axis * (len * 0.5)
                    local e2 = d.Position - axis * (len * 0.5)
                    -- etwas ueber der Schiene ansetzen: dort steht man beim
                    -- Grinden, und dort liegen auch die Knoten
                    local up = Vector3.new(0, 2, 0)
                    local n1 = nearest(grid, bb, cell, e1 + up, 16, 12)
                    local n2 = nearest(grid, bb, cell, e2 + up, 16, 12)
                    if n1 and n2 and n1.id ~= n2.id then
                        local t = len / prof.railSpeed
                        -- bergab ist die Schiene schneller und sicherer als
                        -- bergauf; hoch geht nur mit Schwung
                        if n2.p.Y < n1.p.Y then
                            addEdge(n1, n2, "rail", t)
                            addEdge(n2, n1, "rail", t * 1.8)
                        else
                            addEdge(n2, n1, "rail", t)
                            addEdge(n1, n2, "rail", t * 1.8)
                        end
                        rails = rails + 1
                    end
                end
            end
            breathe()
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
        return zips, pads, rails
    end
    
    -- 4g) INSELN VERBINDEN.
    -- Gemessen auf UltimatePaintball: 23086 Knoten in 390 nicht verbundenen
    -- Inseln, die groesste mit 70 Prozent der Knoten — 30 Prozent hingen voellig
    -- ab. Von dort fand A* nie einen Weg ("kein Weg im Graphen" war mit Abstand
    -- der haeufigste Fehlschlag). Die Ursachen sind Kanten, die knapp ausserhalb
    -- der Reichweiten liegen: ein Absatz einen Tick zu hoch, eine Luecke einen
    -- Tick zu weit, ein Dach, das man nur im Fallen erreicht.
    -- Deshalb nach dem Kantenbau: Inseln bestimmen, und von jeder kleinen Insel
    -- zur naechstgelegenen anderen eine Verbindung suchen — fallen, wenn es
    -- abwaerts geht, springen, wenn der Bogen frei ist.
    local function components(nodes)
        local comp, count = {}, 0
        for i = 1, #nodes do
            if not comp[i] then
                count = count + 1
                local stack, seen = { i }, 0
                comp[i] = count
                while #stack > 0 do
                    local id = table.remove(stack)
                    seen = seen + 1
                    for _, e in ipairs(nodes[id].e) do
                        if not comp[e.to] then
                            comp[e.to] = count
                            stack[#stack + 1] = e.to
                        end
                    end
                    if seen % 3000 == 0 then breathe() end
                end
            end
        end
        return comp, count
    end

    local function linkIslands(nodes, grid, bb, cell, prof)
        local comp, nComp = components(nodes)
        if nComp < 2 then return 0, nComp, nComp end
        -- Groesse je Insel
        local size = {}
        for i = 1, #nodes do size[comp[i]] = (size[comp[i]] or 0) + 1 end
        -- Knoten nach Insel sammeln
        local byComp = {}
        for i = 1, #nodes do
            local c = comp[i]
            local t = byComp[c] ; if not t then t = {} byComp[c] = t end
            t[#t + 1] = i
        end
        -- FALLEN TRAEGT WEITER ALS SPRINGEN. Seit die Sprungkanten auf 14
        -- Studs gedeckelt sind (weil weite Spruenge gemessen nur zu 18
        -- Prozent ankommen), fehlen Bruecken. Ein Fall nach unten ist aber
        -- immer zuverlaessig — dafuer darf die Suche deutlich weiter reichen.
        local linked = 0
        local span = math.ceil(46 / cell)
        for c, ids in pairs(byComp) do
            -- die groesste Insel selbst nicht behandeln
            local isBiggest = true
            for c2, s2 in pairs(size) do
                if s2 > size[c] then isBiggest = false break end
            end
            if not isBiggest then
                local made = 0
                for _, id in ipairs(ids) do
                    if made >= 5 then break end
                    local a = nodes[id]
                    for dx = -span, span do
                        for dz = -span, span do
                            local b = grid[(a.ix + dx) .. "," .. (a.iz + dz)]
                            if b then
                                for _, o in ipairs(b) do
                                    if comp[o.id] ~= c and size[comp[o.id]] > size[c] then
                                        local flat = ((o.p - a.p) * Vector3.new(1,0,1)).Magnitude
                                        local dy = o.p.Y - a.p.Y
                                        if flat < 46 then
                                            if dy < -1 and dy > -70
                                               and flat <= math.max(14, math.abs(dy) * 0.9)
                                               and not cast(a.p + Vector3.new(0,1,0),
                                                            (o.p - a.p) + Vector3.new(0,-1,0)) then
                                                addEdge(a, o, "drop",
                                                        math.sqrt(2*math.abs(dy)/prof.g) + flat/prof.speed)
                                                linked = linked + 1 ; made = made + 1
                                            elseif flat <= math.min(prof.reach * 0.9, 14)
                                                   and dy <= prof.rise
                                                   and arcClear(a.p, o.p, prof) then
                                                addEdge(a, o, "jump", flat/prof.speed + 0.25)
                                                addEdge(o, a, "jump", flat/prof.speed + 0.25)
                                                linked = linked + 1 ; made = made + 1
                                            end
                                        end
                                    end
                                    if made >= 5 then break end
                                end
                            end
                            if made >= 5 then break end
                        end
                        if made >= 5 then break end
                    end
                end
            end
            breathe()
        end
        local _, after = components(nodes)
        return linked, nComp, after
    end

    ------------------------------------------------------------------
    -- 5) A* ueber den Graphen. Kosten in Sekunden, Heuristik ebenso.
    ------------------------------------------------------------------
    -- KOSTENGEWICHTE JE KANTENART, zur Laufzeit angewandt.
    -- Bewusst NICHT beim Backen eingerechnet: so wirken Aenderungen sofort,
    -- ohne dass jede Map neu gebacken werden muss, und die Werte bleiben an
    -- einer Stelle sichtbar.
    -- Vertikalitaet ist im Weglaufen mehr wert als die reine Zeit, die sie
    -- kostet: oben ist man schwerer zu erreichen, und Trampolin wie Zipline
    -- bringen Hoehe und Strecke, ohne dass ein Verfolger mitkommt.
    NAV.KINDW = {
        walk = 1.00, roll = 1.00, step = 1.00, drop = 0.95,
        -- Vertikalitaet noch einmal guenstiger: oben ist man schwerer zu
        -- erreichen, und ein Verfolger, der klettern muss, verliert die
        -- Sichtlinie. Das ist der Kern des Unfangbar-Modus.
        hop  = 0.55,        -- Stufe hoch
        -- VAULT IST DIE STAERKSTE OPTION IM GANZEN REPERTOIRE.
        -- Gemessen auf ToyArena: 620 Vault-Kanten, hoechster Absatz 12.0
        -- Studs — bei einer blossen Sprunghoehe von 3.1. Dazu das 2.4-fache
        -- Momentum, und Ketten aus mehreren Vaults gehen ohne Bodenkontakt.
        -- Deshalb billiger als alles andere, auch als die Zipline.
        vault = 0.15,       -- ueber eine Kante ziehen, auch aus der Luft
        jump = 0.60,        -- Sprung ueber eine Luecke
        climb = 0.30,       -- Leiter
        -- Wallride bewusst TEUER: er braucht eigens markierte Waende, bricht
        -- oft ab und kostet dann das ganze Tempo. Nur wenn es sonst keinen
        -- Weg gibt.
        wallrun = 1.60,
        pad  = 0.22,        -- Trampolin
        zip  = 0.20,        -- Zipline
        rail = 0.24,        -- Grindschiene
    }
    -- HOEHE ZAEHLT DREIFACH (Nutzer-Vorgabe).
    -- Einen Stud Hoehe zu gewinnen ist dreimal so wertvoll wie einen Stud
    -- horizontal zurueckzulegen — egal ob geklettert oder gesprungen. Der
    -- Abschlag waechst deshalb MIT dem Hoehengewinn, statt pauschal zu sein:
    -- eine Kante, die sieben Studs hochfuehrt, kostet nur noch ein Drittel.
    -- Gedeckelt, damit die Kosten nicht gegen null laufen und A* nicht
    -- anfaengt, sinnlos auf und ab zu klettern.
    -- SCHWUNG WIRKT NACH. Ein Vault gibt das 2.4-fache Momentum, Trampolin,
    -- Zipline und Schiene ebenfalls Tempo. Die naechste Kante wird damit
    -- schneller gefahren, als ihre Grundkosten sagen — also bekommt sie
    -- einen Abschlag. Das ist der Unterschied zwischen "einmal hoch" und
    -- einer Kette, die in Fahrt bleibt.
    NAV.BOOST_AFTER = { vault = 0.55, pad = 0.6, zip = 0.65, rail = 0.6 }

    NAV.RISE_PER_STUD = 0.10     -- je Stud Hoehe zehn Prozent billiger
    NAV.RISE_FLOOR    = 0.30     -- hoechstens auf ein Drittel herunter
    NAV.RISE_DISCOUNT = 0.62     -- Grundabschlag fuer jede steigende Kante

    -- KOSTENFELD: wie lange braucht jemand von einem Punkt aus zu jedem
    -- Knoten? Ein Dijkstra ohne Ziel, mit Deckel. Damit laesst sich fuer
    -- jeden Fluchtpunkt vergleichen, was ER braucht und was ICH brauche —
    -- und genau diese Differenz ist das Mass fuer "schwer zu fangen".
    -- Ein Punkt, den ich in drei und mein Verfolger erst in fuenfzehn
    -- Sekunden erreicht, ist mehr wert als einer, der nur weit weg ist.
    function NAV.costField(fromPos, budget)
        local G = NAV.graph
        if not G then return nil end
        local s = nearest(G.grid, G.bb, G.cell, fromPos, 30, 14)
        if not s then return nil end
        local nodes = G.nodes
        local dist, closed, fromK = { [s.id] = 0 }, {}, {}
        local heap, hn = {}, 0
        local function push(id, f)
            hn = hn + 1 ; heap[hn] = { id = id, f = f }
            local i = hn
            while i > 1 do
                local pa = math.floor(i / 2)
                if heap[pa].f <= heap[i].f then break end
                heap[pa], heap[i] = heap[i], heap[pa] ; i = pa
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
        push(s.id, 0)
        local seen = 0
        budget = budget or 7000
        while seen < budget do
            local cur = pop()
            if not cur then break end
            if not closed[cur] then
                closed[cur] = true
                seen = seen + 1
                if seen % 2000 == 0 then RunService.Heartbeat:Wait() end
                local n = nodes[cur]
                local boost = fromK[cur] and NAV.BOOST_AFTER[fromK[cur]] or 1
                for _, e in ipairs(n.e) do
                    local w = NAV.KINDW[e.k] or 1
                    local tn = nodes[e.to]
                    if tn then
                        local dy = tn.p.Y - n.p.Y
                        if dy > 1 then
                            w = w * math.max(NAV.RISE_FLOOR,
                                             NAV.RISE_DISCOUNT - NAV.RISE_PER_STUD * dy)
                        end
                    end
                    local ng = dist[cur] + e.c * w * boost
                    if not dist[e.to] or ng < dist[e.to] then
                        dist[e.to] = ng
                        fromK[e.to] = e.k
                        push(e.to, ng)
                    end
                end
            end
        end
        return dist, seen
    end

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
        -- Gerechnet wird in einem eigenen Thread (requestPath), also darf
        -- zwischendurch abgegeben werden. Ein Lauf kostet 12 bis 30 ms — am
        -- Stueck ist das ein sichtbarer Ruckler, in Haeppchen nicht.
        local yieldAt = 2500
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
                if visited >= yieldAt then
                    yieldAt = yieldAt + 2500
                    RunService.Heartbeat:Wait()
                end
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
                -- mit welchem Schwung bin ich hier angekommen?
                local inK = came[cur] and came[cur].k
                local boost = inK and NAV.BOOST_AFTER[inK] or 1
                for _, e in ipairs(n.e) do
                    local w = NAV.KINDW[e.k] or 1
                    local tn = nodes[e.to]
                    if tn then
                        local dy = tn.p.Y - n.p.Y
                        if dy > 1 then
                            w = w * math.max(NAV.RISE_FLOOR,
                                             NAV.RISE_DISCOUNT - NAV.RISE_PER_STUD * dy)
                        end
                    end
                    local ng = gScore[cur] + e.c * w * boost
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
        local nodes, grid, cell, narrow = sampleNodes(bb, onProgress)
        if #nodes < 50 then return nil, "zu wenige Knoten: " .. #nodes end

        local stats = { narrow = narrow or 0 }
        -- Beide MUESSEN vor dem Kantenbau laufen: das Wegschieben aendert
        -- Knotenpositionen, addEdge liest nd.bad
        stats.nudged, stats.offWall = nudgeFromEdges(nodes)
        stats.hazard, stats.hazardParts = markHazards(nodes, mapRoot)
        stats.walk, stats.hop, stats.step, stats.vault = buildWalk(nodes, grid, prof)
        stats.climb = buildClimb(nodes, grid, bb, cell, mapRoot, prof)
        local j, d, rim = buildJumpDrop(nodes, grid, cell, prof)
        stats.jump, stats.drop, stats.rim = j, d, #rim
        stats.wallrun, stats.wallParts = 0, 0   -- siehe 4d: bewusst ausgeschlossen
        stats.zip, stats.pad, stats.rail = buildHelpers(nodes, grid, bb, cell, mapRoot, prof)
        stats.linked, stats.islandsBefore, stats.islandsAfter =
            linkIslands(nodes, grid, bb, cell, prof)
    
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
                      climb="c", zip="z", pad="p", wallrun="r", roll="o",
                      rail="g", vault="v" }
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
        if head[1] ~= "UTGNAV15" then return nil end
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
            ("UTGNAV15|%s|%s|%s,%s,%s,%s,%s,%s"):format(tostring(G.map), tostring(G.cell),
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
    
end

local PathfindingService = game:GetService("PathfindingService")
local PATH = { wps = nil, idx = 1, at = 0, target = nil, busy = false, fails = 0,
               jumped = {} }
AP.path = PATH
ENV.ap = AP          -- fuer Diagnose von aussen
ENV.cfg = CFG        -- dito: erlaubt Messlaeufe mit gesetzter AYIP-Stufe

-- Einstellungen ueber Neuinjektionen hinweg behalten. Gespeichert wird
-- nur, was der Nutzer selbst schaltet; alles andere ergibt sich daraus.
local SETTINGS_FILE = "utg_tag_settings.json"
local function saveSettings()
    if type(writefile) ~= "function" then return end
    pcall(function()
        writefile(SETTINGS_FILE, game:GetService("HttpService"):JSONEncode({
            autopilot = CFG.autopilot and true or false,
            ayip = CFG.ayip or 0,
            jukeSound = CFG.jukeSound and true or false,
            jukeSoundVC = CFG.jukeSoundVC and true or false,
            jukeSoundSelf = CFG.jukeSoundSelf and true or false,
            jukeSoundVol = CFG.jukeSoundVol or 1.6,
            -- 3rd Person wird BEWUSST nicht gesichert: der Modus haengt die
            -- Kamera hinter den Charakter, und wer ihn einmal versehentlich
            -- anhatte, bekam ihn bei jeder Injektion zurueck, ohne die
            -- Ursache zu sehen.
        }))
    end)
end
ENV.saveSettings = saveSettings
do
    if type(readfile) == "function" and type(isfile) == "function" then
        pcall(function()
            if not isfile(SETTINGS_FILE) then return end
            local d = game:GetService("HttpService"):JSONDecode(readfile(SETTINGS_FILE))
            if type(d) ~= "table" then return end
            if d.autopilot ~= nil then CFG.autopilot = d.autopilot end
            if type(d.ayip) == "number" then CFG.ayip = math.clamp(d.ayip, 0, 3) end
            if d.jukeSound ~= nil then CFG.jukeSound = d.jukeSound end
            if d.jukeSoundVC ~= nil then CFG.jukeSoundVC = d.jukeSoundVC end
            if d.jukeSoundSelf ~= nil then CFG.jukeSoundSelf = d.jukeSoundSelf end
            if type(d.jukeSoundVol) == "number" then
                CFG.jukeSoundVol = math.clamp(d.jukeSoundVol, 0, 2)
            end
        end)
    end
end

-- Ein Pfad direkt zum Gegner scheitert oft (er steht auf einem Dach, auf einer
-- Leiter, in der Luft). Deshalb wird eine Kette von Zielen probiert: exakt,
-- auf den Boden projiziert, dann nur noch "in die Naehe" — den Rest macht die
-- normale Verfolgung.
-- Der Graph wird einmal pro Map gebacken (dauert gemessen 3.3 s) und
-- danach nur noch abgefragt. Laeuft im Hintergrund, damit das Spiel
-- waehrenddessen weiterlaeuft.
local navBake = { map = nil, busy = false, at = 0, fails = 0 }
local function ensureGraph()
    local cm = workspace:FindFirstChild("CurrentMap")
    local child = cm and cm:GetChildren()[1]
    if not child then return end
    if navBake.map == child and NAV.graph then return end
    if navBake.busy or tick() - navBake.at < 4 then return end
    navBake.busy, navBake.at = true, tick()
    task.spawn(function()
        -- Erst die Datei. Der gruendliche Bake dauert ~30 s und liefert
        -- 99 % Erreichbarkeit; das muss pro Map genau einmal passieren,
        -- nicht bei jedem Rundenwechsel.
        local okL, loaded = pcall(NAV.load, child.Name)
        if okL and loaded then
            navBake.map, navBake.fails, navBake.busy = child, 0, false
            LOG(("Navigationsgraph fuer %s aus Datei geladen: %d Knoten")
                :format(child.Name, #loaded.nodes))
            return
        end
        local ok, g, err = pcall(NAV.bake)
        if ok and g then
            navBake.map, navBake.fails = child, 0
            local s = g.stats
            LOG(("Navigationsgraph fuer %s gebaut: %d Knoten in %.1f s — %d gehen, "
                 .. "%d Stufe hoch, %d Stufe runter, %d springen, %d fallen, "
                 .. "%d klettern, %d vault, %d zip, %d pad; %d Punkte wegen zu wenig "
                 .. "Platz verworfen, %d von Waenden weggeschoben; "
                 .. "Inseln %d -> %d durch %d Verbindungen")
                :format(g.map, s.nodes, s.secs, s.walk, s.hop or 0, s.step or 0,
                        s.jump, s.drop, s.climb, s.vault or 0, s.zip, s.pad, s.narrow or 0,
                        s.offWall or 0, s.islandsBefore or 0, s.islandsAfter or 0,
                        s.linked or 0))
            -- pcall allein genuegt hier nicht: NAV.save kann sauber
            -- zurueckkehren und trotzdem false melden
            local okCall, saved, info = pcall(NAV.save)
            if okCall and saved then
                LOG(("Graph gespeichert (%.1f MB) — naechste Runde auf %s laedt ihn sofort")
                    :format((tonumber(info) or 0) / 1048576, g.map))
            else
                LOG("Graph konnte nicht gespeichert werden: "
                    .. tostring(okCall and info or saved))
            end
        else
            navBake.fails = navBake.fails + 1
            if navBake.fails % 3 == 1 then
                LOG("Navigationsgraph konnte nicht gebaut werden: " .. tostring(g or err))
            end
        end
        navBake.busy = false
    end)
end

-- Ersetzt die alte PathfindingService-Anfrage. Das Rueckgabeformat bleibt
-- gleich (Position/Action), damit der Wegpunkt-Folger unveraendert damit
-- arbeitet — zusaetzlich traegt jeder Punkt die Kantenart, ueber die er
-- erreicht wird, damit die Ausfuehrung weiss, was zu tun ist.
------------------------------------------------------------------
-- PFAD-ANZEIGE
--     Macht sichtbar, was der Graph plant: je Wegpunkt ein Wuerfel,
--     eingefaerbt nach Kantenart. Rein lokal, nichts davon repliziert.
------------------------------------------------------------------
-- Die Anzeige baut bei jedem neuen Weg Parts neu auf. Das war einmal ein
-- Bildratenproblem, weil der Weg 50 mal in 30 s berechnet wurde; seit der
-- Drosselung sind es 4, damit ist sie wieder tragbar.
-- Die Pfad-Anzeige legt je Wegpunkt ein Part an — bei 40 bis 60 Wegpunkten
-- und einer Neuberechnung alle paar Sekunden sind das Dutzende
-- Instanz-Erzeugungen in EINEM Frame, gut sichtbar als Ruckler beim
-- Umschauen. Sie ist ein Diagnosemittel und darum standardmaessig aus;
-- einschalten mit ENV.pathVis(true).
local PATHVIS = { folder = nil, on = false, dirPart = nil }
local KIND_COLOR = {
    walk    = Color3.fromRGB(235, 235, 235),
    hop     = Color3.fromRGB(255, 210,  60),
    step    = Color3.fromRGB(255, 150,  40),
    jump    = Color3.fromRGB( 70, 230,  90),
    drop    = Color3.fromRGB( 70, 150, 255),
    climb   = Color3.fromRGB(190,  90, 255),
    zip     = Color3.fromRGB( 60, 230, 230),
    via     = Color3.fromRGB(255, 255,  90),
    roll    = Color3.fromRGB(140, 255, 150),
    pad     = Color3.fromRGB(255,  90, 200),
    wallrun = Color3.fromRGB(255,  70,  70),
}

local function visClear()
    if PATHVIS.folder then
        pcall(function() PATHVIS.folder:Destroy() end)
        PATHVIS.folder = nil
    end
    if PATHVIS.dirPart then
        pcall(function() PATHVIS.dirPart:Destroy() end)
        PATHVIS.dirPart = nil
    end
end

-- Im Nahbereich gibt es keinen Weg, sondern nur eine Richtung. Damit auch
-- dort sichtbar ist, wohin gesteuert wird, zeigt ein flacher Balken die
-- aktuelle Laufrichtung an.
local function visDirection(pos, dir)
    if not PATHVIS.on or not dir then
        if PATHVIS.dirPart then
            pcall(function() PATHVIS.dirPart:Destroy() end)
            PATHVIS.dirPart = nil
        end
        return
    end
    pcall(function()
        local p = PATHVIS.dirPart
        if not p or not p.Parent then
            p = Instance.new("Part")
            p.Name = "UTG_Dir"
            p.Anchored, p.CanCollide, p.CanQuery, p.CanTouch = true, false, false, false
            p.Material = Enum.Material.Neon
            p.Color = Color3.fromRGB(120, 255, 180)
            p.Transparency = 0.35
            p.Size = Vector3.new(0.5, 0.2, 14)
            p.Parent = workspace
            PATHVIS.dirPart = p
        end
        p.CFrame = CFrame.lookAt(pos + Vector3.new(0, -2.4, 0) + dir * 7, pos + dir * 14)
    end)
end

-- Pfad-Anzeige zuschalten, wenn man sehen will, was der Folger vorhat.
function ENV.pathVis(on)
    PATHVIS.on = on and true or false
    if not PATHVIS.on then pcall(visClear) end
    LOG("Pfad-Anzeige " .. (PATHVIS.on and "AN" or "AUS"))
    return PATHVIS.on
end

local function visPath(wps)
    visClear()
    if not PATHVIS.on or not wps or #wps < 2 then return end
    local ok = pcall(function()
        local f = Instance.new("Folder")
        f.Name = "UTG_PathVis"
        f.Parent = workspace
        PATHVIS.folder = f
        for i, wp in ipairs(wps) do
            local kind = wp.kind or "walk"
            local p = Instance.new("Part")
            p.Name = "wp" .. i
            p.Anchored = true
            p.CanCollide = false
            p.CanQuery = false
            p.CanTouch = false
            p.Material = Enum.Material.Neon
            p.Color = KIND_COLOR[kind] or KIND_COLOR.walk
            -- Wegpunkte, die etwas Besonderes verlangen, deutlich groesser
            local special = (kind ~= "walk")
            p.Size = special and Vector3.new(1.6, 1.6, 1.6) or Vector3.new(0.7, 0.7, 0.7)
            p.Transparency = special and 0.15 or 0.45
            p.Shape = Enum.PartType.Block
            p.Position = wp.Position
            p.Parent = f
        end
    end)
    if not ok then visClear() end
end

------------------------------------------------------------------
-- VERFOLGUNGSPUNKT
--     Ein bewegtes Ziel direkt anzupfaden funktioniert nicht: der Pfad
--     wird bei jeder groesseren Zielbewegung verworfen und neu gerechnet,
--     der Bot faehrt nie eine Route zu Ende. Stattdessen wird die
--     Bodenposition des Ziels als fester Punkt gemerkt und nur alle paar
--     Sekunden nachgezogen — oder sobald er erreicht ist.
--     Ein Punkt entsteht NUR, wenn das Ziel Bodenkontakt hat; haengt es
--     in der Luft, bleibt der alte stehen, bis es wieder landet.
------------------------------------------------------------------
local CHASE = { point = nil, at = 0, pl = nil }
local CHASE_INTERVAL = 3.0
local CHASE_REACHED  = 9

local function groundedPos(pl)
    local char = pl and pl.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if not (hrp and hum) then return nil end
    if hum.FloorMaterial == Enum.Material.Air then return nil end
    local st = hum:GetState()
    if st == Enum.HumanoidStateType.Freefall or st == Enum.HumanoidStateType.Jumping
       or st == Enum.HumanoidStateType.Climbing then return nil end
    return hrp.Position
end

local function chasePoint(pos, preyPl)
    if not preyPl then
        CHASE.point, CHASE.pl = nil, nil
        return nil
    end
    local now = tick()
    if CHASE.pl ~= preyPl then           -- Zielwechsel: von vorne
        CHASE.point, CHASE.pl, CHASE.at = nil, preyPl, 0
    end
    local reached = CHASE.point
        and ((CHASE.point - pos) * Vector3.new(1, 0, 1)).Magnitude < CHASE_REACHED
    if (not CHASE.point) or reached or (now - CHASE.at > CHASE_INTERVAL) then
        local g = groundedPos(preyPl)
        if g then CHASE.point, CHASE.at = g, now end
    end
    return CHASE.point
end

------------------------------------------------------------------
-- FEHLERERKENNUNG
--     Jede Art, wie das Abfahren eines Weges scheitern kann, bekommt
--     einen eigenen Zaehler. Ohne diese Trennung sieht man nur "der Bot
--     haengt" und raet beim Beheben.
------------------------------------------------------------------
local FAIL = {
    counts = {}, last = {}, recent = {},
    seg = { sum = 0, n = 0, max = 0 },     -- Abweichung vom Sollweg
}
ENV.fail = FAIL

local function failNote(kind, detail)
    FAIL.counts[kind] = (FAIL.counts[kind] or 0) + 1
    local now = tick()
    FAIL.recent[#FAIL.recent + 1] = { t = now, kind = kind, detail = detail }
    if #FAIL.recent > 60 then table.remove(FAIL.recent, 1) end
    -- entprellt ins Log, sonst flutet ein Dauerfehler die Datei
    if not FAIL.last[kind] or now - FAIL.last[kind] > 6 then
        FAIL.last[kind] = now
        LOG(("FEHLER %s (%d.) %s"):format(kind, FAIL.counts[kind], detail or ""))
    end
end

-- Laufender Zustand fuer die Erkennung
local WATCH = { pos = nil, at = 0, movedAt = 0, idx = nil, idxAt = 0,
                kind = nil, kindAt = 0, kindY = nil, jumpAt = 0, jumpY = nil,
                lastY = nil, hadPath = false }

local function failTick(pos, hum, goalActive)
    local now = tick()
    local wps, idx = PATH.wps, PATH.idx

    -- 1) STECKENGEBLIEBEN: will laufen, kommt aber nicht vom Fleck
    if WATCH.pos then
        local moved = ((pos - WATCH.pos) * Vector3.new(1, 0, 1)).Magnitude
        if moved > 1.0 then WATCH.movedAt = now end
        if goalActive and now - WATCH.movedAt > 1.5 then
            failNote("steckt", ("%.1f s ohne Fortschritt"):format(now - WATCH.movedAt))
            WATCH.movedAt = now
        end
    else
        WATCH.movedAt = now
    end

    -- 2) ABWEICHUNG vom Sollweg: wie weit laeuft er neben dem Pfad her?
    if wps and idx and idx > 1 and wps[idx] and wps[idx - 1] then
        local a = wps[idx - 1].Position * Vector3.new(1, 0, 1)
        local b = wps[idx].Position * Vector3.new(1, 0, 1)
        local ab = b - a
        if ab.Magnitude > 0.1 then
            local p2 = pos * Vector3.new(1, 0, 1)
            local t = math.clamp((p2 - a):Dot(ab.Unit) / ab.Magnitude, 0, 1)
            local dev = (p2 - (a + ab * t)).Magnitude
            -- Respawn oder Rundenwechsel setzt den Charakter irgendwohin,
            -- waehrend der alte Weg noch steht. Solche Spruenge sind kein
            -- Pfadfehler und wuerden den Schnitt unbrauchbar machen
            -- (gemessen einmal 2138 Studs).
            if dev > 100 then
                PATH.endWhy = "versetzt"
                PATH.wps = nil
            else
                FAIL.seg.sum = FAIL.seg.sum + dev
                FAIL.seg.n = FAIL.seg.n + 1
                if dev > FAIL.seg.max then FAIL.seg.max = dev end
                if dev > 10 then
                    failNote("abgekommen", ("%.0f Studs neben dem Weg"):format(dev))
                end
            end
        end
    end

    -- 3) WEGPUNKT HAENGT: derselbe Index viel zu lange
    if wps and idx then
        if WATCH.idx ~= idx then WATCH.idx, WATCH.idxAt = idx, now
        elseif now - WATCH.idxAt > 4 then
            local wp = wps[idx]
            failNote("wegpunkt_haengt",
                ("Art %s, %.0f Studs flach / %.0f hoch"):format(
                    tostring(wp and wp.kind),
                    wp and ((wp.Position - pos) * Vector3.new(1,0,1)).Magnitude or -1,
                    wp and (wp.Position.Y - pos.Y) or 0))
            WATCH.idxAt = now
        end
    end

    -- 4) KANTENARTEN, die ihr Versprechen nicht halten
    local curKind = (wps and idx and wps[idx]) and wps[idx].kind or nil
    if curKind ~= WATCH.kind then
        WATCH.kind, WATCH.kindAt, WATCH.kindY = curKind, now, pos.Y
    elseif curKind and now - WATCH.kindAt > 2.5 then
        local gained = pos.Y - (WATCH.kindY or pos.Y)
        local climbing = (hum and hum:GetState() == Enum.HumanoidStateType.Climbing)
                         or RENV.shared.touchingTruss
        if curKind == "climb" and not climbing and gained < 3 then
            failNote("klettern_greift_nicht",
                ("seit %.1f s an der Leiter, %.0f Studs gewonnen"):format(now - WATCH.kindAt, gained))
        elseif (curKind == "hop" or curKind == "jump") and gained < 1 then
            failNote("sprung_ohne_hoehe",
                ("Art %s, %.1f s, %.0f Studs"):format(curKind, now - WATCH.kindAt, gained))
        end
        WATCH.kindAt, WATCH.kindY = now, pos.Y
    end

    -- 5) PFAD VERLOREN, obwohl das Ziel noch weit weg ist
    if WATCH.hadPath and not wps then
        local tgt = PATH.target
        if tgt and (tgt - pos).Magnitude > 12 then
            failNote("pfad_verloren", ("%.0f Studs vom Ziel"):format((tgt - pos).Magnitude))
        end
    end
    WATCH.hadPath = wps ~= nil

    -- 6) STURZ: viel Hoehe verloren, ohne dass ein Abstieg geplant war
    if WATCH.lastY then
        local drop = WATCH.lastY - pos.Y
        if drop > 22 and curKind ~= "drop" and curKind ~= "step" then
            failNote("sturz", ("%.0f Studs gefallen (Art %s)"):format(drop, tostring(curKind)))
        end
    end
    WATCH.lastY = pos.Y

    -- 7) HIN UND HER: kippt die Laufrichtung staendig um, kommt der Bot
    -- nicht voran, auch wenn er sich dauernd bewegt. Ueber ein Fenster von
    -- 0.3 s gemessen, sonst ist die Richtung von Frame zu Frame zu verrauscht.
    if not WATCH.dirAt or now - WATCH.dirAt > 0.3 then
        if WATCH.dirPos then
            local mv = (pos - WATCH.dirPos) * Vector3.new(1, 0, 1)
            if mv.Magnitude > 1.0 then
                local d = mv.Unit
                if WATCH.dir and d:Dot(WATCH.dir) < -0.4 then
                    WATCH.flips = (WATCH.flips or 0) + 1
                    if WATCH.flips >= 3 then
                        failNote("hin_und_her",
                            ("%d Richtungswechsel hintereinander"):format(WATCH.flips))
                        WATCH.flips = 0
                    end
                else
                    WATCH.flips = 0
                end
                WATCH.dir = d
            end
        end
        WATCH.dirPos, WATCH.dirAt = pos, now
    end

    WATCH.pos, WATCH.at = pos, now
end

local computeEngine        -- weiter unten definiert
-- Sichtlinie fuer die Glaettung: derselbe Korridor-Gedanke wie beim Backen,
-- denn was der Bot faehrt, muss fuer seine Breite frei sein.
local smoothRP = RaycastParams.new()
smoothRP.FilterType = Enum.RaycastFilterType.Exclude
smoothRP.RespectCanCollide = true
local function lineFree(a, b)
    local ign = { workspace.CurrentCamera }
    for _, pl in ipairs(Players:GetPlayers()) do
        if pl.Character then ign[#ign + 1] = pl.Character end
    end
    local vis = workspace:FindFirstChild("UTG_PathVis")
    if vis then ign[#ign + 1] = vis end
    smoothRP.FilterDescendantsInstances = ign
    local flat = (b - a) * Vector3.new(1, 0, 1)
    if flat.Magnitude < 0.1 then return true end
    local side = Vector3.new(-flat.Unit.Z, 0, flat.Unit.X)
    for _, w in ipairs({ 0, 1.15, -1.15 }) do
        local o = side * w + Vector3.new(0, 2.2, 0)
        if workspace:Raycast(a + o, (b + o) - (a + o), smoothRP) then return false end
    end
    return true
end

local function computeGraph(fromPos, toPos)
    if not NAV.graph then
        diagStat("graph_kein_graph").n = diagStat("graph_kein_graph").n + 1
        return nil
    end
    -- WIE WEIT LIEGT DER GRAPH VOM BOT UND VOM ZIEL WEG?
    -- Gemessen stand der Bot schon 9 Studs neben und 9 Studs ueber dem
    -- naechsten Knoten. Der Weg beginnt dann an einer Stelle, an der er gar
    -- nicht ist — die ersten Wegpunkte sind unerreichbar und der ganze Weg
    -- wird verworfen. Ohne diese Zahl im Log sieht man das nie.
    local G = NAV.graph
    local function nearestDist(p)
        -- Rueckgabe nil statt einer Fantasiezahl, wenn nichts in Reichweite
        -- liegt: ein Platzhalter von 1e9 hat die Mittelwerte im Bericht
        -- unbrauchbar gemacht (421524666 Studs).
        local bd, bn = 1e9, nil
        local cell, bb = G.cell, G.bb
        local ix = math.floor((p.X - bb.min.X) / cell + 0.5)
        local iz = math.floor((p.Z - bb.min.Z) / cell + 0.5)
        for dx = -3, 3 do
            for dz = -3, 3 do
                local b = G.grid[(ix + dx) .. "," .. (iz + dz)]
                if b then
                    for _, n in ipairs(b) do
                        local d = (n.p - p).Magnitude
                        if d < bd then bd, bn = d, n end
                    end
                end
            end
        end
        if not bn then return nil end
        return bd, bn
    end
    local dStart = nearestDist(fromPos)
    local dGoal = nearestDist(toPos)

    local ok, path, why = pcall(NAV.findPath, fromPos, toPos)
    -- ZIEL LIEGT IM SELBEN KNOTEN WIE DER START.
    -- A* gibt dann einen Weg aus einem einzigen Punkt zurueck. Das galt
    -- bisher als Fehlschlag, worauf PathfindingService einen langen Weg fuer
    -- eine Strecke von wenigen Studs gerechnet hat — gemessen 221 von 446
    -- "Fehlschlaegen" waren genau das. Richtig ist: einfach direkt hinlaufen.
    if ok and type(path) == "table" and #path == 1 then
        diagStat("graph_zu_nah").n = diagStat("graph_zu_nah").n + 1
        return { { Position = path[1].node.p, Action = Enum.PathWaypointAction.Walk,
                   kind = "walk" },
                 { Position = toPos, Action = Enum.PathWaypointAction.Walk,
                   kind = "walk" } }
    end
    if not ok or type(path) ~= "table" or #path < 2 then
        local reason = (not ok) and "Fehler" or tostring(why or "leer")
        -- NICHT hochzaehlen: diagLine() unten erhoeht denselben Zaehler
        -- bereits. Doppelt gezaehlt sah die Trefferquote halb so gut aus,
        -- wie sie ist (130 statt 65 Fehlschlaege).
        diagStat("graphgrund_" .. reason:gsub("%s+", "_")).n =
            diagStat("graphgrund_" .. reason:gsub("%s+", "_")).n + 1
        if dStart then diagVal("graph_fehler", "start", dStart)
        else diagStat("graph_bot_ohne_knoten").n = diagStat("graph_bot_ohne_knoten").n + 1 end
        if dGoal then diagVal("graph_fehler", "ziel", dGoal)
        else diagStat("graph_ziel_ohne_knoten").n = diagStat("graph_ziel_ohne_knoten").n + 1 end
        diagLine("graph_fehler",
            "%s | Bot %s vom naechsten Knoten, Ziel %s | -> PathfindingService",
            reason,
            dStart and ("%.1f"):format(dStart) or "KEIN Knoten in Reichweite",
            dGoal and ("%.1f"):format(dGoal) or "KEIN Knoten in Reichweite")
        return nil
    end
    diagStat("graph_ok").n = diagStat("graph_ok").n + 1
    if dStart then diagVal("graph_ok", "start", dStart) end
    if dGoal then diagVal("graph_ok", "ziel", dGoal) end
    -- Ein Weg, der weit weg vom Bot beginnt, ist der haeufigste Grund fuer
    -- abgebrochene Routen: die ersten Punkte liegen hinter ihm oder ueber ihm.
    if dStart and dStart > 8 then
        diagLine("start_weit_weg",
            "Weg beginnt %.1f Studs neben dem Bot (Ziel %.1f Studs neben dem Knoten)",
            dStart, dGoal)
    end

    local raw = {}
    for i, step in ipairs(path) do
        raw[i] = {
            Position = step.node.p,
            Action = Enum.PathWaypointAction.Walk,
            kind = step.kind,
        }
    end

    -- DIE SPRUNGMARKE GEHOERT AN DEN ABSPRUNG, NICHT AN DIE LANDUNG.
    -- A* traegt in jeden Knoten die Art der Kante ein, die ZU IHM fuehrt
    -- (NAV.findPath, came[at].k). Ein Wegpunkt der Art "jump" ist also der
    -- LANDEpunkt. Ausgeloest wurde der Sprung aber wenige Studs vor genau
    -- diesem Wegpunkt — bei einer Sprungweite von bis zu 22 Studs also
    -- ungefaehr eine halbe Sekunde nachdem der Bot bereits ueber die Kante
    -- gelaufen und gefallen war. Dass Treppen trotzdem funktionierten, lag
    -- allein daran, dass "hop"-Kanten nur zwischen Nachbarzellen entstehen
    -- (4 bis 5.6 Studs) und der Ausloeseradius dort zufaellig passte.
    -- Der Absprung bekommt jetzt die Marke und das Sprungziel dazu; die
    -- Kantenart bleibt am Landepunkt stehen, weil Fehlersuche und Anzeige
    -- sie dort erwarten.
    for i = 2, #raw do
        local k = raw[i].kind
        -- SCHIENE: aufgesprungen wird am NAHEN Ende, nicht am fernen. Der
        -- Wegpunkt der Art "rail" ist das Ziel der Fahrt — stur darauf
        -- zuzuhalten heisst, am Boden daneben herzulaufen. Gemessen kam der
        -- Bot solchen Punkten nie naeher als 18 Studs.
        if k == "rail" then
            local t = raw[i - 1]
            t.railEntry = true
            t.railTo = raw[i].Position
        end
        if k == "jump" or k == "hop" then
            local t = raw[i - 1]
            t.Action = Enum.PathWaypointAction.Jump
            t.takeoff = true
            t.jumpTo = raw[i].Position
            t.jumpKind = k
        end
    end

    -- Ein Glaettungsversuch (aufeinanderfolgende Gehpunkte bei freier Sicht
    -- zusammenfassen) hat die Abweichung vom Sollweg NICHT verbessert,
    -- sondern von 5.5 auf 6.3 Studs verschlechtert und "abgekommen" von 408
    -- auf 720 Meldungen getrieben: zusammengefasst wurde auch ueber Ecken
    -- hinweg. Bis das sauber funktioniert, bleiben die Rohpunkte.
    return raw
end

-- Beide Verfahren, jedes fuer das, was es nachweislich kann. Gemessen auf
-- MedievalGlassHouses ueber Hoehenbaender (je 4 Ziele):
--        Hoehe ueber Bot   PathfindingService   Graph
--           0..15 Studs          4/4             4/4
--          15..45 Studs          0/8             8/8   <- nur der Graph
--          45..90 Studs         10/12            1/12  <- nur die Engine
-- Der Graph kommt zuerst, weil er die Fortbewegungsarten des Spiels kennt
-- und mit 12 ms statt 100-160 ms antwortet; die Engine faengt die Faelle
-- ab, an denen das Raster des Graphen an schmalen Rampen zerreisst.
local function computeOnce(fromPos, toPos, radius)
    local wps = computeGraph(fromPos, toPos)
    if wps then wps.__src = "graph" return wps end
    wps = computeEngine(fromPos, toPos, radius or 1.8)
    if wps then wps.__src = "engine" end
    return wps
end

computeEngine = function(fromPos, toPos, radius)
    local ok, res = pcall(function()
        local path = PathfindingService:CreatePath({
            -- AgentRadius: die Doku nennt ihn ganzzahlig, die Engine wertet
            -- aber Nachkommastellen aus — auf CrossRoads gemessen (34 Ziele):
            -- r=2.0 liefert durchweg laengere Wege als 1.8, r=0.8 findet mit
            -- 26/34 am wenigsten. 1.8 bleibt, 1.2 rettet 3 weitere Pfade.
            AgentRadius = radius or 1.8,
            -- 5 gegen 5.5 gemessen: identisch (33/34 Pfade). Bleibt bei 5.
            AgentHeight = 5,
            AgentCanJump = true,
            -- DAS hier war der fehlende Schluessel fuer Vertikalitaet: damit
            -- bezieht die Wegfindung TrussParts (die Leitern dieser Maps) in
            -- die Navigation ein, statt sie als Wand zu behandeln.
            AgentCanClimb = true,
            AgentMaxSlope = 89,
            WaypointSpacing = 4,
        })
        path:ComputeAsync(fromPos, toPos)
        if path.Status == Enum.PathStatus.Success then
            return path:GetWaypoints()
        end
        return nil
    end)
    if ok and res and #res > 1 then
        -- PathWaypoint ist ein Datentyp der Engine, kein Tabelle. Der
        -- Wegpunkt-Folger fragt aber ueberall nach wp.kind — und ein
        -- unbekanntes Feld an einem Engine-Datentyp ist kein nil, sondern
        -- ein Fehler. Jede ueber die Engine gefundene Route hat den
        -- Autopilotschritt deshalb sofort abgebrochen. Also hier in
        -- einfache Tabellen umschreiben, in demselben Format wie der Graph.
        local out = {}
        for i, w in ipairs(res) do
            out[i] = { Position = w.Position, Action = w.Action, kind = "walk" }
        end
        -- Bei der Engine sitzt die Sprungmarke bereits am richtigen Ende
        -- (dort, wo gesprungen werden soll). Sie bekommt hier nur noch das
        -- Sprungziel dazu, damit der Absprung dieselbe Behandlung erfaehrt
        -- wie beim Graphen.
        for i = 1, #out do
            if out[i].Action == Enum.PathWaypointAction.Jump and out[i + 1] then
                -- WEITE SPRUENGE AUCH HIER RAUS.
                -- Der Graph ist auf 9 Studs gedeckelt, PathfindingService
                -- kennt diese Grenze nicht. Gemessen kamen ueber die Engine
                -- weiter Spruenge von 9 bis 14 Studs herein, die nur zu 38
                -- Prozent ankamen. Ueber neun Studs wird der Punkt deshalb
                -- als gewoehnlicher Gehpunkt behandelt — hinlaufen statt
                -- hinspringen, und wenn dort eine Luecke ist, faellt der Weg
                -- weg und es wird neu geplant.
                local gap = ((out[i + 1].Position - out[i].Position)
                             * Vector3.new(1, 0, 1)).Magnitude
                if gap <= 9 then
                    out[i].takeoff = true
                    out[i].jumpTo = out[i + 1].Position
                    out[i].jumpKind = "jump"
                    out[i + 1].kind = "jump"
                else
                    out[i].Action = Enum.PathWaypointAction.Walk
                end
            end
        end
        return out
    end
    return nil
end

local function requestPath(fromPos, candidates)
    if PATH.busy then return end
    -- Harte Mindestpause zwischen zwei Berechnungen. Gemessen wurden 50
    -- Anfragen in 30 s (1.7 pro Sekunde) bei 15-30 ms A* je Anfrage — das
    -- allein erzeugte laufend Ruckler und drueckte die Bildrate auf 43.
    if PATH.lastCalc and tick() - PATH.lastCalc < 0.7 then return end
    -- harte Sperre nach Fehlschlaegen: sonst wird jede Sekunde mehrfach
    -- gerechnet und jedes Mal derselbe Umweg verworfen
    if PATH.nextAllowed and tick() < PATH.nextAllowed then return end
    PATH.busy = true
    PATH.lastCalc = tick()
    task.spawn(function()
        local wps, used
        -- Eine Graph-Anfrage kostet gemessen 12 ms statt 100-160 ms bei
        -- PathfindingService — die alten Budgets und Radien-Ketten sind
        -- damit hinfaellig.
        for _, t in ipairs(candidates) do
            wps = computeOnce(fromPos, t)
            if wps then used = t break end
        end
        if wps then
            -- Laenge gegen Luftlinie pruefen. Die alte Regel "laenger als das
            -- 2.5-fache der Luftlinie = Unsinn" hat in dieser Map genau die
            -- richtigen Pfade weggeworfen: gemessener Durchschnittsumweg ist
            -- x2.03, weil die Luftlinie durch Beton geht und der echte Weg
            -- ueber Treppen und Leitern fuehrt. Hoehenunterschied kostet nun
            -- ausdruecklich Weglaenge, statt als Umweg zu gelten.
            -- Die Laengenpruefung ist entfallen. Sie stammte aus der Zeit von
            -- PathfindingService, wo ein langer Weg ein Umweg war. Der Graph
            -- rechnet in SEKUNDEN: ein Weg ueber Zipline und Wallrun kann
            -- weit aussehen und trotzdem der schnellste sein — genau solche
            -- Wege hat die alte Regel zuverlaessig weggeworfen.
            PATH.jumped, PATH.idxAt, PATH.from = {}, tick(), fromPos
            PATH.air, PATH.prog, PATH.syncAt = nil, nil, nil
            AP.pathLoose = false
            visPath(wps)
            -- DA ANFANGEN, WO DER BOT WIRKLICH STEHT.
            -- Der Graph haengt den Weg an den naechstgelegenen Knoten, und der
            -- liegt gemessen im Schnitt 6.1 Studs neben dem Bot (bis zu 22).
            -- Stur bei Punkt 2 zu beginnen heisst dann: die ersten Wegpunkte
            -- liegen neben oder hinter ihm, er laeuft erst einmal zurueck,
            -- und der halbe Weg ist verbraucht, bevor es vorwaerts geht.
            -- Deshalb den Punkt suchen, der dem Bot am naechsten liegt, und
            -- beim darauffolgenden einsteigen — aber nur unter den ersten
            -- sechs, damit eine Schleife im Weg nicht abgekuerzt wird.
            local startIdx = (wps[1] and wps[1].takeoff) and 1 or 2
            do
                local bestI, bestD = startIdx, math.huge
                for k = 1, math.min(6, #wps) do
                    if wps[k].takeoff then break end   -- Abspruenge nie ueberspringen
                    local d = ((wps[k].Position - fromPos) * Vector3.new(1, 0, 1)).Magnitude
                    if d < bestD then bestI, bestD = k, d end
                end
                local cand = math.min(bestI + 1, #wps)
                if cand > startIdx and not wps[cand - 1].takeoff then
                    startIdx = cand
                end
                diagVal("wegstart", "abstand",
                    ((wps[startIdx].Position - fromPos) * Vector3.new(1, 0, 1)).Magnitude)
                diagVal("wegstart", "uebersprungen", startIdx - 2)
                diagStat("wegstart").n = diagStat("wegstart").n + 1
            end
            PATH.wps, PATH.idx, PATH.at, PATH.target, PATH.fails =
                wps, startIdx, tick(), used, 0
            PATH.nextAllowed = nil
        else
            PATH.wps, PATH.fails = nil, PATH.fails + 1
            PATH.at = tick()
            failNote("kein_weg", ("%d Kandidaten erfolglos"):format(#candidates))
            PATH.nextAllowed = tick() + math.min(1.5 + PATH.fails * 0.5, 6)
            if PATH.fails % 5 == 1 then
                LOG(("Pfad nicht berechenbar (%d. Mal) — es laeuft die direkte Steuerung"):format(PATH.fails))
            end
        end
        PATH.busy = false
    end)
end

-- Sprungwerte des Charakters, jedes Mal frisch gelesen: die Gravitation
-- unterscheidet sich je Map deutlich (auf FactionAction 71.25 statt 196),
-- und JumpPower aendert sich mit Boosts.
-- JUMPPOWER HAENGT AN DER WALKSPEED (gemessen 2026-09-18, 260 Proben):
--     WalkSpeed 31-36  ->  JumpPower 28.8 bis 30.1
--     WalkSpeed 44     ->  JumpPower 36.4
-- Schnell ankommen bringt also doppelt: mehr Weite UND mehr Sprunghoehe.
-- Deshalb wird vor einem Absprung nie gebremst, und der Wert wird im Moment
-- des Absprungs gelesen, nicht vorher.
local function jumpProfile()
    local hum = LP.Character and LP.Character:FindFirstChildOfClass("Humanoid")
    local g = math.max(workspace.Gravity, 1)
    local vy = 28
    if hum then
        vy = hum.UseJumpPower and hum.JumpPower
             or math.sqrt(2 * g * math.max(hum.JumpHeight, 1))
        -- Untergrenze aus der gemessenen Kopplung an die WalkSpeed: beim
        -- Absprung aus vollem Lauf steht mehr Sprungkraft bereit, als ein
        -- im Stand gelesener Wert vermuten laesst.
        if hum.WalkSpeed and hum.WalkSpeed > 8 then
            vy = math.max(vy, hum.WalkSpeed * 0.86)
        end
    end
    return g, vy
end

-- Eine Leitermessung abschliessen und einordnen.
local function diagCloseLadder()
    local l = DIAG.lad
    DIAG.lad = nil
    if not l or not DIAG.on then return end
    local kind = (l.climbing or (l.gain or 0) > 3) and "leiter_ok" or "leiter_daneben"
    diagEvent("leiter", kind, ("%.1f"):format(l.min), ("%.0f"):format(l.spdMin or 0),
              ("touch=%s hoehe=%.0f dauer=%.1f"):format(tostring(l.touched),
                                                        l.gain or 0, tick() - l.t0))
    diagVal(kind, "min", l.min)
    diagVal(kind, "spd", l.spdMin or 0)
    diagLine(kind,
        "Abstand %.1f, Tempo dabei %.0f, touchingTruss=%s, Hoehe %+.0f, %.1fs, %s",
        l.min, l.spdMin or 0, tostring(l.touched), l.gain or 0,
        tick() - l.t0, l.loose and "weiche Steuerung" or "harter Weg")
end

-- Eine Wegpunktmessung abschliessen.
local function diagCloseWaypoint(why)
    local w = DIAG.wp
    DIAG.wp = nil
    if not w or not DIAG.on then return end
    why = why or "?"
    -- Respawn, Rundenwechsel oder Teleport setzen den Charakter irgendwohin.
    -- Solche Spruenge sind kein Fahrfehler und wuerden jeden Schnitt
    -- unbrauchbar machen (gemessen einmal 1881 Studs "Ueberschuss").
    if (w.over or 0) > 60 or (w.min or 0) > 200 then
        diagStat("sprung_verworfen").n = diagStat("sprung_verworfen").n + 1
        return
    end
    diagStat("wegpunkt").n = diagStat("wegpunkt").n + 1
    diagStat("grund_" .. why).n = diagStat("grund_" .. why).n + 1
    -- JE KANTENART: hat der Bot den Punkt wirklich erreicht? Das ist das
    -- allgemeine Mass fuer "funktioniert diese Fortbewegungsart" — bei
    -- Leitern, Schienen, Ziplines und Trampolinen genauso wie beim Gehen.
    local art = "art_" .. tostring(w.kind)
    diagStat(art).n = diagStat(art).n + 1
    diagVal(art, "min", w.min)
    diagVal(art, "spd", w.spdMin or 0)
    diagVal(art, "zeit", tick() - w.t0)
    if w.min < 4 then
        diagStat(art .. "_ok").n = diagStat(art .. "_ok").n + 1
    end
    diagStat("modus_" .. tostring(w.mode)).n =
        diagStat("modus_" .. tostring(w.mode)).n + 1
    diagVal("modus_" .. tostring(w.mode), "min", w.min)
    diagVal("wegpunkt", "min", w.min)
    diagVal("wegpunkt", "over", w.over)
    diagVal("wegpunkt", "side", w.side)
    diagVal("wegpunkt", "spd", w.spdMin or 0)
    -- Ueberschiessen: er war schon dicht dran und hat sich dann wieder
    -- entfernt, obwohl derselbe Wegpunkt noch galt.
    -- Nur echtes Ueberschiessen melden: er war dicht dran (unter 4 Studs)
    -- und hat sich dann wieder entfernt. Ein Wegpunkt, der nie nah war, ist
    -- ein anderes Problem und wird getrennt gezaehlt.
    diagEvent("wegpunkt", w.kind, ("%.1f"):format(w.min), ("%.0f"):format(w.spdMin or 0),
              ("over=%.1f side=%.1f ende=%s"):format(w.over, w.side, tostring(why)))
    if w.over > 3 and w.min < 4 then
        diagLine("ueberschossen",
            "Art %s: %.1f Studs drueber (dichteste %.1f, seitlich %.1f, "
            .. "Tempo %.0f, Anlauf %.0f, %.1fs, Ende: %s)",
            w.kind, w.over, w.min, w.side, w.spdMin or 0, w.d0, tick() - w.t0, why)
    elseif w.min > 6 and why ~= "neuer_weg" and why ~= "weg_weg" then
        diagStat("nah_" .. tostring(w.mode)).n = diagStat("nah_" .. tostring(w.mode)).n + 1
        diagLine("nie_nah_dran",
            "Art %s: dichteste %.1f (seitlich %.1f, Tempo %.0f, Anlauf %.0f, "
            .. "%.1fs, Ende: %s)",
            w.kind, w.min, w.side, w.spdMin or 0, w.d0, tick() - w.t0, why)
    end
end

-- Einen ganzen Weg abschliessen: wie weit ist der Bot gekommen?
local function diagClosePath(why)
    local P = DIAG.path
    DIAG.path = nil
    if not P or not DIAG.on or (P.n or 0) < 2 then return end
    local done = math.clamp((P.maxIdx - 1) / math.max(P.n - 1, 1), 0, 1)
    diagStat("weg").n = diagStat("weg").n + 1
    diagVal("weg", "anteil", done * 100)
    diagVal("weg", "punkte", P.n)
    diagVal("weg", "dauer", tick() - P.t0)
    diagEvent("weg", P.n, ("%.0f"):format(done * 100), tostring(P.src),
              ("ende=%s dauer=%.1f"):format(tostring(why), tick() - P.t0))
    diagStat("wegende_" .. tostring(why)).n =
        diagStat("wegende_" .. tostring(why)).n + 1
    diagStat("wegquelle_" .. tostring(P.src)).n =
        diagStat("wegquelle_" .. tostring(P.src)).n + 1
    -- Ein Weg, von dem weniger als die Haelfte gefahren wurde, ist eine
    -- vergebliche Rechnung — die interessiert einzeln.
    if done < 0.5 and why ~= "nahbereich" then
        diagLine("weg_abgebrochen",
            "%.0f%% von %d Punkten gefahren (%s, %.1fs, Quelle %s, Ende: %s)",
            done * 100, P.n, tostring(P.mode), tick() - P.t0,
            tostring(P.src), tostring(why))
    end
end

-- Laeuft in jedem Frame mit einem gueltigen Wegpunkt.
local function diagTick(pos, wps, idx, wp)
    if not DIAG.on then return end
    local hrpD = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
    local spd = hrpD and (hrpD.AssemblyLinearVelocity * Vector3.new(1, 0, 1)).Magnitude or 0
    local flat = ((wp.Position - pos) * Vector3.new(1, 0, 1)).Magnitude

    -- Weg-Identitaet: eine neue Wegpunktliste ist ein neuer Weg
    local P = DIAG.path
    if not P or P.wps ~= wps then
        diagClosePath("neuer_weg")
        P = { wps = wps, n = #wps, t0 = tick(), maxIdx = idx,
              src = (wps.__src or "?"), mode = tostring(AP.mode) }
        DIAG.path = P
    elseif idx > P.maxIdx then
        P.maxIdx = idx
    end

    local w = DIAG.wp
    if w and (w.idx ~= idx or w.wps ~= wps) then
        -- Eine Neuberechnung tauscht die ganze Wegpunktliste aus; das ist
        -- kein Ueberschiessen, sondern ein neuer Weg.
        diagCloseWaypoint(w.wps ~= wps and "neuer_weg" or PATH.reason)
        w = nil
    end
    if not w then
        w = { idx = idx, kind = tostring(wp.kind), d0 = flat, t0 = tick(),
              min = flat, over = 0, side = 0, spdMin = spd, wps = wps,
              mode = tostring(AP.mode) }
        if idx > 1 and wps[idx - 1] then
            w.seg = (wp.Position - wps[idx - 1].Position) * Vector3.new(1, 0, 1)
        end
        DIAG.wp = w
    end
    if flat < w.min then
        w.min, w.spdMin, w.over = flat, spd, 0
        -- seitlicher Versatz zur Sollinie im dichtesten Moment: zeigt, ob er
        -- den Punkt verfehlt, weil er neben der Linie laeuft
        if w.seg and w.seg.Magnitude > 0.1 then
            local u = w.seg.Unit
            local rel = (pos - wp.Position) * Vector3.new(1, 0, 1)
            w.side = (rel - u * rel:Dot(u)).Magnitude
        end
    else
        local o = flat - w.min
        if o > w.over then w.over = o end
    end

    -- Leitern gesondert: hier zaehlt, ob das Spiel den Truss ueberhaupt
    -- erkannt hat (shared.touchingTruss) und mit welchem Tempo er ankam.
    if wp.kind == "climb" then
        local lad = AP.ladder
        local l = DIAG.lad
        if lad and lad.Parent
           and ((lad.Position - pos) * Vector3.new(1, 0, 1)).Magnitude < 25
           and (not l or l.part ~= lad) then
            diagCloseLadder()
            l = { part = lad, t0 = tick(), y0 = pos.Y, min = 1e9, spdMin = 0,
                  touched = false, climbing = false, gain = 0,
                  loose = AP.pathLoose and true or false }
            DIAG.lad = l
        end
        if l and l.part and l.part.Parent then
            local d = ((l.part.Position - pos) * Vector3.new(1, 0, 1)).Magnitude
            if d < l.min then l.min, l.spdMin = d, spd end
            if RENV.shared.touchingTruss then l.touched = true end
            local humD = LP.Character and LP.Character:FindFirstChildOfClass("Humanoid")
            if humD and humD:GetState() == Enum.HumanoidStateType.Climbing then
                l.climbing = true
            end
            l.gain = pos.Y - l.y0
        end
    elseif DIAG.lad then
        diagCloseLadder()
    end
end

-- Punkte, an denen die Position wirklich stimmen muss: dort greift eine
-- Spielmechanik (Truss, Zipline, Trampolin) oder es geht durch eine Tuer.
local function wpsExact(wps, idx)
    local w = wps and wps[idx]
    if not w then return false end
    local k = w.kind
    return w.takeoff or w.railEntry
        or k == "climb" or k == "zip" or k == "pad" or k == "via" or k == "rail"
        or k == "vault"
end

-- liefert die Richtung zum naechsten Wegpunkt (oder nil, wenn kein Pfad taugt).
-- "mode" entscheidet ueber die Strenge: beim Weglaufen ist der Weg nur eine
-- Richtung, beim Jagen ein Ziel.
local function followPath(pos, mode)
    local wps = PATH.wps
    if not wps then
        -- kein Weg mehr, also auch kein laufender Sprung: der Flugzustand
        -- sperrt sonst dauerhaft Ausweichen und Finten
        PATH.air, AP.inAir, AP.pathLoose, PATH.prog = nil, false, false, nil
        if DIAG.wp then diagCloseWaypoint("weg_weg") end
        if DIAG.lad then diagCloseLadder() end
        if DIAG.path then
            diagClosePath(PATH.endWhy or "verworfen")
            PATH.endWhy = nil
        end
        return nil
    end

    -- WAEHREND EINES SPRUNGS WIRD NICHT NACHGERECHNET.
    -- In der Luft ist jede Korrektur schaedlich: die Wegpunktpruefung haekt
    -- Punkte ab oder verwirft den Weg ("unter dem Weg"), waehrend der Bot
    -- noch fliegt, und das Ausweichen vor Hindernissen dreht ihn kurz vor
    -- der Landung von der Zielkante weg. Zwischen Absprung und Aufsetzen
    -- zaehlt deshalb nur eines: die Luftsteuerung auf den Landepunkt.
    local air = PATH.air
    if air then
        local humA = LP.Character and LP.Character:FindFirstChildOfClass("Humanoid")
        local flying = humA and humA.FloorMaterial == Enum.Material.Air
        local tAir = tick() - air.at
        local toLand = (air.to - pos) * Vector3.new(1, 0, 1)
        if flying and tAir < 3 then
            -- im Flug niemals die freie Richtungswahl: sie bewertet Boden und
            -- Offenheit und wuerde den Bot von seiner Zielkante wegdrehen
            AP.inAir, AP.pathLoose = true, false
            if toLand.Magnitude > 0.1 then return toLand.Unit end
            return nil
        end
        AP.inAir = false
        -- Nicht abgehoben? Der Tap wird verschluckt, wenn der Charakter
        -- gerade landet, rollt oder eine Leiter streift. Zwei Mal kurz
        -- nachfassen ist billiger als eine Neuplanung.
        local lifted = (pos.Y - air.from.Y) > 1.2
        if not flying and not lifted and tAir < 0.5 then
            if tick() - (air.lastTry or 0) > 0.15 and (air.tries or 1) < 3 then
                air.tries, air.lastTry = (air.tries or 1) + 1, tick()
                tryJump(true)
            end
            if toLand.Magnitude > 0.1 then return toLand.Unit end
            return nil
        end
        PATH.air, PATH.prog = nil, nil   -- Fortschrittsuhr nach der Landung neu
        local flat = toLand.Magnitude
        local dy = pos.Y - air.to.Y
        diagEvent("sprung", air.kind, ("%.0f"):format(air.gap), ("%.0f"):format(air.spd),
                  ("noetig=%.0f winkel=%.0f flach=%.0f hoch=%.0f"):format(
                      air.need, air.ang, flat, dy))
        LOG(("Sprung %s: %.0f Studs Luecke, Absprung %.0f Studs/s (noetig %.0f), "
             .. "Winkel %.0f Grad -> %s (%.0f flach, %.0f hoch daneben)")
            :format(tostring(air.kind), air.gap, air.spd, air.need, air.ang,
                    (flat <= 7 and dy > -6) and "gelandet" or "DANEBEN", flat, dy))
        if flat > 7 or dy < -6 then
            PATH.endWhy = "sprung_daneben"
                    failNote("sprung_daneben",
                ("Luecke %.0f, Absprung %.0f Studs/s bei %.0f Grad, %.0f Studs daneben")
                    :format(air.gap, air.spd, air.ang, flat))
            -- sofort neu planen, nicht erst nach der Mindestpause: er steht
            -- jetzt irgendwo unter der Route
            PATH.wps, PATH.at, PATH.lastCalc = nil, 0, nil
            return nil
        end
    end
    -- Wegpunkte abhaken. Die alte Regel "XZ-Abstand < 4.5" war bei
    -- WaypointSpacing 3 groesser als der Abstand zwischen zwei Wegpunkten:
    -- es lag staendig schon der uebernaechste Punkt im Streichbereich und
    -- wurde mitsamt seinem Sprung-Marker blind uebersprungen. Und weil nur
    -- XZ zaehlte, galt ein Wegpunkt 30 Studs ueber uns als erreicht — in
    -- einer gestapelten Map ist das der halbe Pfad auf einmal.
    -- Die Zahlen stammen aus einem Parametervergleich ueber 12 echte Pfade
    -- auf CrossRoads, jeweils gegen drei Steigraten (Treppe / Leiter / kaum
    -- hochkommen). Eine Y-Toleranz von 5 wirkte am Schreibtisch richtig,
    -- liess den Bot beim langsamen Steigen aber 162 statt 61 Spruenge
    -- ausloesen — er erreicht den hoeher liegenden Punkt nicht und spamt.
    -- 12 ist ueber alle Steigraten stabil.
    local now = tick()
    -- BEIM WEGLAUFEN IST DER WEG NUR EINE RICHTUNG, KEINE SCHIENE.
    -- Das Ziel ist dort eine grobe Himmelsrichtung weg vom Faenger, kein
    -- bestimmter Punkt — ein um zwei Studs verfehlter Wegpunkt ist also
    -- voellig egal. Mit den strengen Toleranzen hat der Bot dafuer aber
    -- kehrtgemacht und ihn nachgeholt, und ein Umdrehen vor dem Verfolger
    -- kostet genau das, was die Flucht gewinnen soll. Beim Jagen zaehlt
    -- dagegen der genaue Punkt, dort bleibt alles wie es war.
    local flee = (mode == "FLUCHT")
    -- ABER: Leiter, Zipline und Trampolin muessen auch auf der Flucht genau
    -- getroffen werden — ein Annahmeradius von 6 Studs haekt die Leiter ab,
    -- waehrend der Bot noch daneben steht. Gemessen wurde genau das: 39 % der
    -- Wegpunkte hatten als dichteste Annaeherung 6.0 bis 6.5 Studs, Grund
    -- "radius". Fuer gewoehnliche Gehpunkte bleibt es locker.
    -- Grundwerte; je Wegpunkt wird unten nachgeschaerft, sobald ein genauer
    -- Punkt drankommt (Leiter, Zipline, Trampolin, Durchgang, Absprung).
    -- 6.0 war zu grosszuegig: gemessen kam der Bot bei 63 % der Wegpunkte im
    -- Fluchtmodus nie naeher als 6 Studs heran, der Weg wurde faktisch nur
    -- gestreift. 4.5 bleibt lockerer als beim Jagen (3.0), haelt ihn aber
    -- auf der Spur.
    local tightR   = flee and 4.5 or 3.0
    local passR    = flee and 14 or 7.2     -- "schon vorbei" gilt bis hierhin
    local upTol    = flee and 4.0 or 2.5    -- wie hoch der Punkt liegen darf
    local advMax   = flee and 4 or 2        -- Wegpunkte pro Frame
    local advanced = 0
    while PATH.idx <= #wps and advanced < advMax do
        local wp = wps[PATH.idx]
        local flat = (wp.Position - pos) * Vector3.new(1, 0, 1)
        local dy = math.abs(wp.Position.Y - pos.Y)
        local reached, reachedWhy
        -- Genaue Punkte bleiben eng, auch beim Weglaufen
        local exactHere = wpsExact(wps, PATH.idx)
        local tightNow = exactHere and 3.0 or tightR
        local passNow  = exactHere and 7.2 or passR
        if wp.takeoff then
            -- EIN ABSPRUNGPUNKT WIRD NUR DURCH DEN SPRUNG SELBST ERLEDIGT.
            -- Sonst gewinnt das normale Abhaken (Radius 3.0) das Rennen gegen
            -- den Ausloeseabstand (rund 3.1 Studs bei vollem Tempo): der
            -- Absprung waere abgehakt, bevor gesprungen wurde, und es bliebe
            -- der Landepunkt jenseits der Luecke uebrig.
            -- Beim Weglaufen wird ein verpasster Absprung nicht nachgeholt:
            -- liegt er hinter dem Bot, waere das eine Kehrtwende vor dem
            -- Verfolger. Dann lieber sofort einen neuen Weg.
            local behind = false
            if flee and PATH.idx > 1 then
                local segT = (wp.Position - wps[PATH.idx - 1].Position) * Vector3.new(1, 0, 1)
                behind = segT.Magnitude > 0.1 and segT.Unit:Dot(-flat) > 0
            end
            if behind or now - (PATH.idxAt or now) > 3 then
                PATH.endWhy = "absprung_verpasst"
                    failNote("absprung_verpasst",
                    ("%.0f Studs vom Absprung, kein Sprung ausgeloest")
                        :format(flat.Magnitude))
                PATH.wps, PATH.at, PATH.prog = nil, 0, nil
                -- kurze Sperre, sonst kommt sofort derselbe Weg mit
                -- demselben Absprung zurueck und er huepft dort fest
                PATH.nextAllowed = now + 1.2
                AP.pathLoose = false
                return nil
            end
            break
        end
        if wp.kind == "climb" then
            -- Der Kopf einer Leiter liegt bis zu 45 Studs ueber dem Fuss.
            -- Hier darf der Notausgang nicht greifen, sonst gilt der Punkt
            -- als erledigt, bevor ueberhaupt geklettert wurde. Und eng
            -- greifen: bei 5 Studs Toleranz galt die Leiter als erreicht,
            -- obwohl er noch gar nicht an ihr hing — er lief seitlich vorbei.
            reached = flat.Magnitude < 2.0 and dy < 5
        else
            -- Die Hoehentoleranz muss ASYMMETRISCH sein. Mit einem
            -- symmetrischen Fenster von 12 Studs hakt der Bot einen
            -- Wegpunkt ab, der ueber ihm liegt — unter einer Treppe ist
            -- die XZ-Position ja dieselbe wie oben darauf. Er gilt dann als
            -- angekommen, ohne je hochgelaufen zu sein, und springt danach
            -- gegen die Unterseite der Treppe.
            -- Nach OBEN wird auf Fusshoehe geprueft: liegt der Punkt auf
            -- einer Erhoehung, reicht es nicht, ihn seitlich zu beruehren.
            -- Mit 4 Studs Spielraum galt eine kniehohe Kiste als erreicht,
            -- waehrend der Bot davorstand — danach zeigte der Rest des Weges
            -- ins Leere. Nach UNTEN bleibt es grosszuegig, weil Fallen
            -- erlaubt ist und er sonst beim Absteigen klebt.
            local up = wp.Position.Y - pos.Y
            local heightOk = up < upTol and up > -12
            -- Tuerdurchgaenge brauchen Genauigkeit, aber 1.6 Studs waren zu
            -- streng: gemessen entfielen darauf 56 % der gesamten
            -- Haengerzeit (im Schnitt 2.45 s je Fall, Zustand "Running")
            -- — er traf den Punkt nicht und blieb davor stehen.
            -- Durchgaenge (Tueren, Fenster) erst als erledigt werten, wenn er
            -- wirklich HINDURCH ist. Beim reinen Naeherungsradius schwenkte
            -- er schon zum naechsten Wegpunkt, waehrend er noch davorstand,
            -- und sprang links oder rechts am Rahmen vorbei.
            if wp.kind == "via" and not flee then
                reached = false
                if PATH.idx > 1 then
                    local seg = (wp.Position - wps[PATH.idx - 1].Position) * Vector3.new(1, 0, 1)
                    if seg.Magnitude > 0.1 and seg.Unit:Dot(-flat) > 0
                       and flat.Magnitude < 6 then
                        reached = true
                    end
                end
                if not reached and flat.Magnitude < 1.4 and heightOk then
                    reached = true
                    reachedWhy = "via_radius"
                end
                -- Ventil: ein Durchgang, der nach ueber einer Sekunde immer
                -- noch nicht passiert ist, wird nicht getroffen — bei 32
                -- Studs/s und 1.4 Studs Annahmeradius umkreist der Bot ihn
                -- nur. Dann gilt er als erledigt; kommt er dahinter wirklich
                -- nicht weiter, greift der Fortschrittswaechter.
                if not reached and flat.Magnitude < 5 and heightOk
                   and now - (PATH.idxAt or now) > 1.2 then
                    reached = true
                    reachedWhy = "via_ventil"
                end
            else
                reached = flat.Magnitude < tightNow and heightOk
            -- (Ein eigenes Ventil fuer Durchgaenge stand hier mit 0.6 s und
            --  war toter Code: der allgemeine Notausgang unten greift schon
            --  bei 0.5 s und deckt denselben Fall ab.)
            -- oder schon daran vorbei: hinter der Ebene senkrecht zum Wegstueck
            -- SCHON VORBEI — aber nur, wenn er auch NEBEN dem Punkt vorbei
            -- ist und nicht quer daneben. Ohne Seitengrenze galt ein Wegpunkt
            -- als erledigt, an dem er 9.5 Studs seitlich vorbeigelaufen ist:
            -- gemessen 11 solcher Faelle mit 5 bis 9.5 Studs Versatz, alle
            -- als "nie nah dran" aufgefallen. Hinter der Ebene UND weit
            -- daneben heisst nicht "geschafft", sondern "verfehlt" — dann
            -- soll der Fortschrittswaechter uebernehmen.
            if not reached and PATH.idx > 1 and flat.Magnitude < passNow and heightOk then
                local seg = (wp.Position - wps[PATH.idx - 1].Position) * Vector3.new(1, 0, 1)
                if seg.Magnitude > 0.1 and seg.Unit:Dot(-flat) > 0 then
                    local u = seg.Unit
                    local side = (-flat - u * (-flat):Dot(u)).Magnitude
                    if side < (flee and 6.0 or 4.0) then
                        reached = true
                        reachedWhy = "vorbeigelaufen"
                    end
                end
            end
            -- NIE UMDREHEN, UM EINEN PUNKT NACHZUHOLEN. Beim Weglaufen gilt
            -- ein Wegpunkt, der hinter dem Bot liegt, ohne Abstandsgrenze als
            -- erledigt — auch wenn er ihn um zehn Studs verfehlt hat. Kehrt
            -- machen heisst dem Verfolger entgegenlaufen.
            -- Beim Weglaufen ohne Abstandsgrenze, aber ebenfalls nicht quer
            -- daneben: sonst gilt ein Punkt als erledigt, den er um zwanzig
            -- Studs verfehlt hat, und der Weg dahinter passt nicht mehr.
            if not reached and flee and not exactHere and PATH.idx > 1 then
                local seg = (wp.Position - wps[PATH.idx - 1].Position) * Vector3.new(1, 0, 1)
                if seg.Magnitude > 0.1 and seg.Unit:Dot(-flat) > 0
                   and (function()
                           local u = seg.Unit
                           return (-flat - u * (-flat):Dot(u)).Magnitude < 9.0
                       end)() then
                    reached = true
                    reachedWhy = "hinter_mir_flucht"
                end
            end
            end
            -- Notausgang: haengt er eine halbe Sekunde am selben Punkt und
            -- ist horizontal laengst da, gilt der Punkt als erledigt.
            -- NICHT aber, wenn der Punkt ueber ihm liegt — dann steht er
            -- darunter (der Treppenfall) und Ueberspringen macht es
            -- schlimmer, weil der Weg danach durch die Decke zeigt.
            -- Stattdessen den Weg verwerfen und von der tatsaechlichen
            -- Position neu planen.
            -- Durchgaenge sind hier ausgenommen: sie muessen wirklich
            -- passiert werden, sonst springt er wieder am Rahmen vorbei.
            -- Kommt er dort nicht durch, plant die Wegneuberechnung neu.
            -- Der Punkt ueber dem Bot bekommt mehr Zeit als frueher.
            -- Seit Vertikalitaet im Graphen billiger ist, fuehren viel mehr
            -- Wege nach oben, und "unter_dem_weg" ist dadurch zum
            -- zweithaeufigsten Wegende geworden (51 von 600). Eine halbe
            -- Sekunde reicht nicht, um eine Stufe zu nehmen oder an eine
            -- Leiter zu kommen; anderthalb reichen.
            if not reached and wp.kind ~= "via" and flat.Magnitude < 7.2
               and now - (PATH.idxAt or now) > (up >= 2.5 and 1.5 or 0.5) then
                if up >= 2.5 then
                    PATH.endWhy = "unter_dem_weg"
                    failNote("unter_dem_weg",
                        ("Wegpunkt %.1f Studs ueber dem Bot, neu geplant"):format(up))
                    PATH.wps, PATH.at = nil, 0
                    return nil
                end
                reached = true
                reachedWhy = "notausgang"
            end
        end
        if not reached then break end
        PATH.idx = PATH.idx + 1
        PATH.idxAt = now
        advanced = advanced + 1
        PATH.reason = reachedWhy or "radius"
    end
    if not PATH.idxAt then PATH.idxAt = now end
    if PATH.idx > #wps then PATH.wps = nil return nil end
    local wp = wps[PATH.idx]

    -- FORTSCHRITTSWAECHTER. Bisher gab es auf einem Weg keine Rettung fuer den
    -- Nahbereich: der Folger zeigt stur auf seinen Wegpunkt, und weil auf
    -- Wegen weder Wandgleiten noch die Richtungswahl laufen, dreht der Bot vor
    -- einem Durchgang, den er zu Fuss einfach durchlaufen koennte, so lange
    -- Kreise, bis sich das Ziel aendert (beobachtet). Ein Wegpunkt, den er bei
    -- 32 Studs/s nicht genau trifft, wird umkreist statt erreicht.
    -- Deshalb wird der Fortschritt zum aktuellen Wegpunkt gemessen:
    --   Stufe 1: sobald ein Wegpunkt NICHT in der erwarteten Zeit erreicht
    --     ist, wird die freie Nahbereichssteuerung zugeschaltet — dieselbe,
    --     die beim Weglaufen laeuft (Wandgleiten, Wahl der offensten
    --     Richtung), mit der Wegrichtung als Ziel.
    --   Stufe 2: deutlich ueber der Zeit und ohne Annaeherung — Wegpunkt
    --     ueberspringen, wenn der naechste frei erreichbar ist, sonst den Weg
    --     verwerfen und neu planen.
    --
    -- DIE ERWARTETE ZEIT statt einer festen Frist. Wegpunkte liegen 4 bis 9
    -- Studs auseinander, bei 32 Studs/s werden also drei bis acht pro Sekunde
    -- abgehakt. Eine feste Frist von 0.9 s ist in diesem Takt eine halbe
    -- Ewigkeit — bis sie ablief, stand der Bot laengst vor seinem Hindernis.
    -- Gerechnet wird darum mit Strecke durch Tempo: braucht er laenger als das
    -- knapp Doppelte davon, stimmt etwas nicht, und zwar SOFORT.
    local flatNow = ((wp.Position - pos) * Vector3.new(1, 0, 1)).Magnitude
    local hrpP = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
    local spdP = hrpP and (hrpP.AssemblyLinearVelocity * Vector3.new(1, 0, 1)).Magnitude or 0
    local pr = PATH.prog
    if not pr or pr.idx ~= PATH.idx then
        -- Budget beim Eintritt in den Wegpunkt festlegen, nicht laufend neu:
        -- sonst waechst es mit, waehrend er langsamer wird, und laeuft nie ab.
        local ref = math.max(spdP, 12)
        pr = { idx = PATH.idx, best = flatNow, at = now, t0 = now,
               budget = flatNow / ref * 1.9 + 0.25 }
        PATH.prog = pr
    elseif flatNow < pr.best - 0.4 then
        pr.best, pr.at = flatNow, now
    end
    -- Die Uhr laeuft nur, wenn der Folger auch wirklich steuert. Waehrend
    -- einer Finte und bei eigenem Tasteneingriff fuehrt jemand anders, und
    -- fehlender Fortschritt zum Wegpunkt ist dann kein Haenger.
    if AP.jukeName or tick() < (AP.manualUntil or 0) then
        pr.at, pr.t0 = now, now
    end
    diagTick(pos, wps, PATH.idx, wp)
    local stuckFor = now - pr.at
    local overdue = now - pr.t0 - pr.budget       -- wie lange ueberfaellig
    -- BEIM WEGLAUFEN GRUNDSAETZLICH WEICH. Der Weg liefert dort nur die
    -- Himmelsrichtung; gefahren wird sie von derselben Nahbereichssteuerung
    -- wie ohne Weg (offenste Richtung, Wandgleiten, Verfolger als Term).
    -- Stur abgefahrene Wegpunkte kosten auf der Flucht mehr als sie bringen
    -- — gemessen 34 Fehler mit Route gegen 29 ohne.
    -- Sonst: ueberfaellig ODER ohne Annaeherung. Zurueck auf hart geht es von
    -- selbst, sobald wieder ein Wegpunkt abgehakt ist — dann ist pr neu.
    AP.pathLoose = flee or (overdue > 0) or (stuckFor > 0.9)
    -- An einem genauen Punkt hat der Folger das letzte Wort. Sonst waehlt die
    -- freie Nahbereichssteuerung die "offenste" Richtung — und eine Leiter
    -- ist fuer sie ein Hindernis, von dem sie wegsteuert. Genau so entstand
    -- das seitliche Vorbeifliegen an Leitern.
    AP.pathExact = wpsExact(wps, PATH.idx)

    -- WIEDER IN DEN WEG EINSTEIGEN. Faehrt die Nahbereichssteuerung, landet
    -- der Bot oft neben dem verpassten Punkt, aber laengst auf Hoehe eines
    -- spaeteren. Dann dort einsteigen statt zurueckzulaufen. Alle 0.25 s, weil
    -- jede Pruefung Strahlen kostet.
    if AP.pathLoose and not wp.takeoff and now - (PATH.syncAt or 0) > 0.25 then
        PATH.syncAt = now
        local jumpTo
        -- drei Kandidaten statt sechs: jede Pruefung kostet drei Strahlen,
        -- und weiter vorn im Weg liegt ohnehin selten etwas Erreichbares
        for k = PATH.idx + 1, math.min(PATH.idx + 3, #wps) do
            local w2 = wps[k]
            local d2 = ((w2.Position - pos) * Vector3.new(1, 0, 1)).Magnitude
            if d2 < flatNow - 1 and d2 < 14
               and math.abs(w2.Position.Y - pos.Y) < 8
               and lineFree(pos, w2.Position) then
                jumpTo = k                 -- den weitesten passenden nehmen
            end
            -- Nicht ueber einen Absprung hinweg einsteigen: dahinter liegt
            -- eine Luecke, und der Landepunkt allein ist kein Weg.
            if w2.takeoff then break end
        end
        if jumpTo then
            PATH.reason = "wiedereinstieg"
            PATH.idx, PATH.idxAt, PATH.prog = jumpTo, now, nil
            wp = wps[jumpTo]
            flatNow = ((wp.Position - pos) * Vector3.new(1, 0, 1)).Magnitude
            AP.pathLoose = flee
            stuckFor, overdue = 0, -1
        end
    end

    -- Aufgeben, wenn er es sichtbar nicht schafft: weit ueber der Zeit UND
    -- ohne Annaeherung. Bei kurzen Abschnitten greift das nach gut einer
    -- Sekunde, bei langen entsprechend spaeter.
    if (overdue > math.max(pr.budget * 2, 0.8) and stuckFor > 0.6)
       or stuckFor > 2.2 then
        -- Ueberspringen ist nur bei einem NAHEN Wegpunkt sinnvoll: den trifft
        -- er dann eben nicht genau, der Weg dahinter stimmt aber noch. Ist er
        -- weit weg, laeuft er in Wahrheit ganz woanders — dann taugt der
        -- ganze Weg nicht mehr und wird neu gerechnet.
        local nxtW = (flatNow < 12) and wps[PATH.idx + 1] or nil
        -- Absprung- und Kletterpunkte werden NICHT uebersprungen: hinter
        -- ihnen liegt eine Luecke oder eine Leiter, der naechste Punkt ist
        -- ohne sie gar nicht erreichbar.
        local skippable = nxtW and not wp.takeoff and wp.kind ~= "climb"
                          and lineFree(pos, nxtW.Position)
        if skippable then
            failNote("wegpunkt_uebersprungen",
                ("Art %s, %.1f s ueberfaellig, %.1f s ohne Annaeherung (%.0f Studs)")
                    :format(tostring(wp.kind), math.max(overdue, 0), stuckFor, flatNow))
            PATH.reason = "uebersprungen"
            PATH.idx = PATH.idx + 1
            PATH.idxAt, PATH.prog = now, nil
            wp = wps[PATH.idx]
        else
            PATH.endWhy = "haengt"
            failNote("weg_haengt",
                ("Art %s, %.1f s ueberfaellig, %.1f s ohne Annaeherung (%.0f Studs) — neu geplant")
                    :format(tostring(wp.kind), math.max(overdue, 0), stuckFor, flatNow))
            PATH.wps, PATH.at, PATH.lastCalc, PATH.prog = nil, 0, nil, nil
            AP.pathLoose = false
            return nil
        end
    end

    -- KLETTERN. Der Spielcode (Parkour-Modul) setzt shared.touchingTruss nur,
    -- wenn ein Strahl aus der BLICKRICHTUNG des Charakters (LookVector * 4)
    -- einen TrussPart trifft, bei 6 Studs Reichweite. Der Blick folgt der
    -- Laufrichtung, also muss exakt auf die Leiter zugehalten werden — auf
    -- den Zielknoten oben zuzulaufen reicht nicht, seitlich daneben klettert
    -- er nie. Gesprungen wird dabei nicht: ein Sprung an der Leiter heisst
    -- loslassen (das faengt tryJump bereits ab).
    if wp.kind == "climb" and tick() >= (AP.noClimbUntil or 0) then
        local best, bd
        for _, l in ipairs(ladders()) do
            if l.Parent then
                local d = ((l.Position - pos) * Vector3.new(1, 0, 1)).Magnitude
                local top = l.Position.Y + l.Size.Y * 0.5
                -- nur Leitern, die uns tatsaechlich zu diesem Wegpunkt bringen
                if d < 16 and top > pos.Y + 2 and (not bd or d < bd) then
                    best, bd = l, d
                end
            end
        end
        if best then
            AP.ladder = best
            -- NOTFALL: klebt er laenger als eine Sekunde davor, ohne dass das
            -- Spiel den Truss erkennt, taugt der gewaehlte Anlaufpunkt nicht.
            -- Dann den Anlaufpunkt ignorieren und stur auf die Leitermitte
            -- zuhalten. Gemessen wurde genau dieser Fall: 6.6 Sekunden bei
            -- 4.7 Studs Abstand, touchingTruss nie gesetzt.
            if not RENV.shared.touchingTruss
               and now - (PATH.idxAt or now) > 1.0 then
                local straightIn = (best.Position - pos) * Vector3.new(1, 0, 1)
                if straightIn.Magnitude > 0.1 then
                    AP.ladderForce = true
                    return straightIn.Unit
                end
            end
            AP.ladderForce = false
            -- Eine Leiter hat vier Seiten, aber meist stehen ein bis drei
            -- davon an einer Wand. Haelt man auf die Mitte zu, landet man
            -- genau dort und rutscht seitlich daran herum, ohne zu greifen.
            -- Also erst die freie Seite bestimmen, sie anlaufen, und von
            -- dort auf die Leiter zuhalten — nur so trifft der Blickstrahl
            -- des Spiels den TrussPart.
            -- Von WELCHER Seite geklettert wird, steht schon im Weg: der
            -- Wegpunkt davor ist der geplante Anlaufpunkt am Leiterfuss.
            -- Vorher wurde stattdessen die dem Bot naechste freie Seite
            -- gesucht — damit lief er um die Leiter herum und stieg von
            -- hinten ein, obwohl der Weg vor ihre Front zeigte.
            local approach = (PATH.idx > 1) and wps[PATH.idx - 1].Position or nil
            local cf = best.CFrame
            local half = math.max(best.Size.X, best.Size.Z) * 0.5
            local anchor, aScore
            for _, dir in ipairs({ cf.LookVector, -cf.LookVector,
                                   cf.RightVector, -cf.RightVector }) do
                local flatDir = (dir * Vector3.new(1, 0, 1))
                if flatDir.Magnitude > 0.1 then
                    flatDir = flatDir.Unit
                    -- 3.5 Studs Abstand zur Leitermitte waren zu weit:
                    -- gemessen blieb der Bot bei 4.7 bis 5.4 Studs stehen und
                    -- shared.touchingTruss wurde nie gesetzt. Der Spielcode
                    -- prueft mit einem Strahl LookVector * 4 — aus fuenf
                    -- Studs trifft der den Truss gar nicht mehr.
                    local probe = best.Position + flatDir * (half + 2.2)
                    local blocked = workspace:Raycast(
                        best.Position + Vector3.new(0, 1, 0),
                        flatDir * (half + 2.2), AP.rp)
                    if not blocked then
                        -- an der geplanten Seite messen, nicht an der eigenen
                        local ref = approach or pos
                        local d = ((probe - ref) * Vector3.new(1, 0, 1)).Magnitude
                        if not aScore or d < aScore then anchor, aScore = probe, d end
                    end
                end
            end
            if anchor then
                local toAnchor = (anchor - pos) * Vector3.new(1, 0, 1)
                -- Enger ansteuern als bisher (3.0): aus drei Studs Abstand
                -- zur richtigen Seite trifft der Blickstrahl des Spiels den
                -- Truss oft noch nicht, und er rutscht seitlich daran vorbei.
                -- Frueher umschwenken (1.5 -> 2.5): der Blick folgt der
                -- Laufrichtung, also muss er schon auf dem letzten Stueck auf
                -- den Truss zeigen, nicht erst unmittelbar davor.
                if toAnchor.Magnitude > 2.5 then
                    return toAnchor.Unit
                end
                -- auf der richtigen Seite: jetzt exakt auf die Leitermitte
                -- zuhalten, damit der Strahl sie sicher trifft
                local straight = (best.Position - pos) * Vector3.new(1, 0, 1)
                if straight.Magnitude > 0.1 then return straight.Unit end
            end
            local v = (best.Position - pos) * Vector3.new(1, 0, 1)
            if v.Magnitude > 0.1 then return v.Unit end
        end
    end

    -- VAULT / MANTLE. Der entscheidende Punkt: der Griff geht AUS DER LUFT.
    -- Man springt vor die Kante und zieht sich im Flug darueber — damit sind
    -- Absaetze weit ueber der eigenen Sprunghoehe erreichbar, und das Spiel
    -- gibt dabei das 2.4-fache Momentum (VaultMomentumMultiplier). Genau
    -- diese Vertikalitaet haengt Verfolger ab, die den Weg nicht kennen.
    -- Drei Dinge muessen zusammenkommen: frueh genug abspringen, im Flug
    -- GEGEN die Kante halten (nur bei Beruehrung greift es), und in der Luft
    -- nachfassen — ein einzelner Tap beim Absprung haelt den Griff nicht.
    if wp.kind == "vault" then
        local toWp = (wp.Position - pos) * Vector3.new(1, 0, 1)
        local d = toWp.Magnitude
        local humV = LP.Character and LP.Character:FindFirstChildOfClass("Humanoid")
        local airborne = humV and humV.FloorMaterial == Enum.Material.Air
        local up = wp.Position.Y - pos.Y
        -- KETTEN SIND MOEGLICH: drei Vaults hintereinander ohne Bodenkontakt.
        -- Deshalb wird der naechste Griff auch aus der Luft heraus
        -- angenommen, nicht nur vom Boden aus.
        if (not airborne or up > 3) and d < 6
           and tick() - (AP.vaultAt or 0) > 0.45 then
            AP.vaultAt, AP.vaultY = tick(), pos.Y
            tryJump(true)
            diagEvent("vault", ("%.1f"):format(d), ("%.0f"):format(up), "", "Absprung")
        elseif airborne and up > 1
               and tick() - (AP.vaultAt or 0) > 0.2
               and tick() - (AP.vaultGrab or 0) > 0.2 then
            AP.vaultGrab = tick()
            tryJump(true)
        end
        if d > 0.1 then return toWp.Unit end
    end

    -- RAIL (Grindschiene), EINSTIEG. Der Spielcode startet den Grind, wenn
    -- man auf der Schiene LANDET. Der Einstieg liegt am nahen Ende; von dort
    -- geht es die Schiene entlang. Also: auf den Einstieg zuhalten, und beim
    -- Erreichen einmal in Fahrtrichtung der Schiene aufspringen. Tempo bleibt
    -- oben, der Grind lebt vom Schwung.
    if wp.railEntry and wp.railTo then
        local toEntry = (wp.Position - pos) * Vector3.new(1, 0, 1)
        local along = (wp.railTo - wp.Position) * Vector3.new(1, 0, 1)
        local d = toEntry.Magnitude
        local humR = LP.Character and LP.Character:FindFirstChildOfClass("Humanoid")
        local grounded = humR and humR.FloorMaterial ~= Enum.Material.Air
        if d > 4 then
            -- von hinten auf den Einstieg zu, damit er in Fahrtrichtung
            -- ankommt und nicht quer
            if along.Magnitude > 0.1 then
                local aim = wp.Position - along.Unit * math.min(d * 0.5, 5)
                local v = (aim - pos) * Vector3.new(1, 0, 1)
                if v.Magnitude > 0.1 then return v.Unit end
            end
            if toEntry.Magnitude > 0.1 then return toEntry.Unit end
        end
        if grounded and tick() - (AP.railJumpAt or 0) > 0.8 then
            AP.railJumpAt = tick()
            tryJump(true)
            diagLine("rail_einstieg", "Aufsprung bei %.1f Studs, Schiene %.0f Studs lang",
                     d, along.Magnitude)
        end
        if along.Magnitude > 0.1 then return along.Unit end
    end

    -- ROLLEN durch enge Stellen. Solche Luecken haben unter 5 Studs
    -- Kopffreiheit; der Bot lief bisher stur dagegen. Das Spiel loest die
    -- Rolle ueber den Keybind "slide" aus, der auf C liegt (shared.keybinds
    -- .slide = ButtonL2 / ButtonB / C) — es gibt dafuer keinen setzbaren
    -- Tap-Wert wie beim Sprung, also wird die Taste kurz gedrueckt.
    if wp.kind == "roll" and type(keypress) == "function" then
        local toWp = (wp.Position - pos) * Vector3.new(1, 0, 1)
        if toWp.Magnitude < 7 and tick() - (AP.rollAt or 0) > 1.2 then
            AP.rollAt = tick()
            task.spawn(function()
                pcall(keypress, 0x43)          -- C
                task.wait(0.18)
                pcall(keyrelease, 0x43)
            end)
        end
    end

    -- ABSPRUNG einer Sprung- oder Hop-Kante. Der Wegpunkt traegt die Marke
    -- jetzt am richtigen Ende (siehe computeGraph) und weiss, WOHIN gesprungen
    -- wird — daraus ergeben sich Anlaufrichtung, noetiges Tempo und Zeitpunkt.
    -- Nachgefasst wird nicht mehr hier, sondern im Flugzustand oben: bleibt
    -- der Tap wirkungslos (Landeanimation, Rolle, Truss-Beruehrung), sieht
    -- man das daran, dass der Charakter nicht abhebt — und nur dann wird
    -- erneut gedrueckt.
    if wp.takeoff and wp.jumpTo then
        local line = (wp.jumpTo - wp.Position) * Vector3.new(1, 0, 1)
        local gap = line.Magnitude
        if gap > 0.1 then
            local lineU = line.Unit
            local toWp = (wp.Position - pos) * Vector3.new(1, 0, 1)
            local d = toWp.Magnitude
            local hrpJ = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
            local humJ = LP.Character and LP.Character:FindFirstChildOfClass("Humanoid")
            local vel = hrpJ and (hrpJ.AssemblyLinearVelocity * Vector3.new(1, 0, 1))
                        or Vector3.zero
            local spd = vel.Magnitude
            local grounded = humJ and humJ.FloorMaterial ~= Enum.Material.Air
            -- Flugzeit bis auf Zielhoehe, nicht pauschal 2*vy/g: eine hoeher
            -- gelegene Landung verkuerzt den Flug und braucht deshalb mehr
            -- Tempo als dieselbe Weite auf gleicher Hoehe.
            local g, vy = jumpProfile()
            local dyJ = wp.jumpTo.Y - wp.Position.Y
            local disc = vy * vy - 2 * g * dyJ
            local airT = (disc > 0) and ((vy + math.sqrt(disc)) / g) or (vy / g)
            local need = gap / math.max(airT, 0.05)
            local along = (spd > 0.1) and vel.Unit:Dot(lineU) or 1

            -- ANLAUF AUF DER SPRUNGLINIE. Der Bogen ist beim Backen als
            -- Gerade vom Absprung zur Landung geprueft worden. Laeuft der Bot
            -- den Absprungknoten aus einer anderen Richtung an, steht seine
            -- tatsaechliche Fahrtrichtung beim Abheben quer dazu — die
            -- Drehbegrenzung ist auf Wegen zwar aus, die Traegheit des
            -- Charakters aber nicht (gemessen 27.5 Grad Abweichung zwischen
            -- gewollter und gefahrener Richtung). Also wird nicht der Knoten
            -- selbst angesteuert, sondern ein Punkt auf der rueckwaertigen
            -- Verlaengerung der Sprunglinie: er faehrt damit von hinten auf
            -- den Absprung zu und liegt beim Abheben schon auf Kurs.
            -- Nur bei echten Luecken. Eine Treppenstufe ist 4 bis 5.6 Studs
            -- weit (Nachbarzellen im Raster) — dort waere der Anlaufbogen ein
            -- Umweg um den eigenen Absprung herum, und Treppen funktionieren
            -- heute schon zuverlaessig. Erst ab 8 Studs zahlt sich die
            -- Ausrichtung aus, darunter zaehlt nur der Zeitpunkt.
            -- Steht der Bot schon JENSEITS des Absprungs (in Sprungrichtung
            -- hinter dem Knoten), darf der Anlaufbogen nicht greifen: er wuerde
            -- ihn rueckwaerts um seinen eigenen Absprung herumfuehren — als
            -- Kreisen sichtbar. Dann geht es direkt auf den Knoten.
            local past = (pos - wp.Position):Dot(lineU) > 0
            local wide = gap > 8 and not past
            local lead = math.max(spd, 8) * 0.07 + 0.9
            if d > lead then
                if not wide then
                    local v = (wp.Position - pos) * Vector3.new(1, 0, 1)
                    if v.Magnitude > 0.1 then return v.Unit end
                    return lineU
                end
                local aim = wp.Position - lineU * math.clamp(d * 0.55, 0, 6)
                local v = (aim - pos) * Vector3.new(1, 0, 1)
                if v.Magnitude > 0.1 then return v.Unit end
                return lineU
            end

            -- AM ABSPRUNG. Ausgeloest wird ueber die ZEIT bis zur Kante
            -- (rund ein Humanoid-Schritt Vorlauf), nicht ueber einen festen
            -- Radius: bei 14 Studs/s und bei 37 Studs/s liegt derselbe
            -- Radius eine Viertelsekunde auseinander.
            local last = PATH.jumped[PATH.idx] or 0
            -- AUSRICHTUNG IST BEI WEITEN SPRUENGEN PFLICHT.
            -- Gemessen ueber 176 Spruenge: bis 8 Studs Luecke landen 100
            -- Prozent, darueber nur 12 bis 34 — und der Winkelfehler beim
            -- Absprung lag im Schnitt bei 54 Grad (gelandet) bzw. 78 Grad
            -- (daneben). Er springt also quer zur Sprunglinie. Schuld war
            -- die Hintertuer "d < 1.2": stand er nah genug am Absprung,
            -- wurde ohne jede Ausrichtung gesprungen. Bei kurzen Huepfern
            -- ist das egal, bei weiten entscheidet es alles.
            local aligned = (not wide) or (spd < 4) or (along > 0.87)
            -- 0.9 -> 0.85: wer schneller ankommt, springt auch hoeher
            -- (JumpPower folgt der WalkSpeed), der Bogen faellt also besser
            -- aus als die statische Rechnung annimmt.
            if grounded and spd >= need * 0.75
               and (aligned or (not wide and d < 1.2))
               and now - last > 0.3 then
                PATH.jumped[PATH.idx] = now
                PATH.air = {
                    at = now, to = wp.jumpTo, from = pos, gap = gap,
                    spd = spd, need = need, tries = 1,
                    ang = math.deg(math.acos(math.clamp(along, -1, 1))),
                    kind = wp.jumpKind or "jump",
                }
                tryJump(true)
                -- Der Absprungpunkt ist mit dem Sprung erledigt; ab jetzt
                -- gilt der Landepunkt. Ohne das muesste er den Knoten auch
                -- noch "erreichen", waehrend er schon in der Luft ist.
                PATH.idx = PATH.idx + 1
                PATH.idxAt = now
                return lineU
            end
            -- QUER ZUR SPRUNGLINIE: nicht springen, sondern einschwenken.
            -- Ein kurzer Bogen zurueck auf die Linie kostet eine halbe
            -- Sekunde, ein Sprung im falschen Winkel den ganzen Weg.
            -- Quer zur Sprunglinie: einschwenken, aber nach VORNE. Der alte
            -- Bogen nach hinten sah aus wie ein Haken.
            if wide and grounded and not aligned and d < 3 then
                diagStat("sprung_eingeschwenkt").n =
                    diagStat("sprung_eingeschwenkt").n + 1
                local mix = (lineU * 2 + toWp.Unit)
                if mix.Magnitude > 0.05 then return mix.Unit end
                return lineU
            end

            -- ZU LANGSAM FUER DIE LUECKE: nicht gleich den ganzen Weg
            -- wegwerfen. Gemessen endeten 20 von 110 Wegen genau hier — das
            -- Veto war teurer als das Problem, das es verhindern sollte.
            -- Der Bot holt jetzt erst Anlauf: ein Stueck auf der Sprunglinie
            -- zurueck und mit Schwung wieder heran. Bleibt es dabei, greift
            -- nach zwei Sekunden der Notausgang weiter oben und plant neu.
            -- ZU LANGSAM: NICHT ZURUECKLAUFEN.
            -- Das sah von aussen aus wie eine Finte — vor und zurueck auf
            -- der Sprunglinie, mitten in der Flucht. Im Unfangbar-Modus
            -- soll gar nichts nach Zappeln aussehen. Stattdessen einfach
            -- weiter auf der Linie halten und beschleunigen; reicht es
            -- nicht, greift nach drei Sekunden der Notausgang und plant neu.
            if grounded and d < 2.5 and spd < need * 0.75 then
                diagStat("sprung_zu_langsam").n =
                    diagStat("sprung_zu_langsam").n + 1
                return lineU
            end
            return lineU
        end
    end
    -- Der Weg darf jetzt ueber Leitern fuehren. Ein Wegpunkt deutlich ueber uns
    -- in Leiternaehe heisst: dranhalten und klettern, nicht danebenlaufen.
    if wp.Position.Y - pos.Y > 3 and tick() >= (AP.noClimbUntil or 0) then
        for _, l in ipairs(ladders()) do
            if l.Parent and (l.Position - wp.Position).Magnitude < 8 then
                AP.ladder = l
                local v = (l.Position - pos) * Vector3.new(1, 0, 1)
                if v.Magnitude > 0.1 and v.Magnitude < 14 then
                    return v.Unit
                end
                break
            end
        end
    end
    -- Wegpunkt deutlich hoeher -> springen (Treppe/Absatz). Ebenfalls
    -- wegbezogen, also an der Sprungbremse vorbei.
    -- Gedrosselt und nur, wenn vor ihm ueberhaupt Platz zum Steigen ist:
    -- ungedrosselt war das jeden Frame ein Sprungbefehl, und in einer Ecke
    -- mit einem Wegpunkt ueber dem Kopf huepfte der Bot dort nur noch herum.
    if wp.Position.Y - pos.Y > 3 and tick() - (AP.risenJumpAt or 0) > 0.5 then
        local toHigher = (wp.Position - pos) * Vector3.new(1, 0, 1)
        local wallAhead = toHigher.Magnitude > 0.1
            and workspace:Raycast(pos + Vector3.new(0, 3.2, 0),
                                  toHigher.Unit * 3, AP.rp)
        if not wallAhead then
            AP.risenJumpAt = tick()
            tryJump(true)
        end
    end

    -- DURCHGANG DURCHLAUFEN, NICHT UMKREISEN. Aus der Naehe wird nicht mehr
    -- der Durchgangspunkt selbst angesteuert, sondern ein Punkt drei Studs
    -- DAHINTER auf derselben Achse. Ein Punkt, auf den man zielt und den man
    -- bei vollem Tempo knapp verfehlt, wird umrundet; ein Punkt dahinter
    -- zieht den Bot hindurch.
    if wp.kind == "via" and PATH.idx > 1 then
        local segV = (wp.Position - wps[PATH.idx - 1].Position) * Vector3.new(1, 0, 1)
        local dV = ((wp.Position - pos) * Vector3.new(1, 0, 1)).Magnitude
        if segV.Magnitude > 0.1 and dV < 5 then
            local through = wp.Position + segV.Unit * 3
            local v = (through - pos) * Vector3.new(1, 0, 1)
            if v.Magnitude > 0.1 then return v.Unit end
        end
    end

    local dir = (wp.Position - pos) * Vector3.new(1, 0, 1)
    if dir.Magnitude < 0.1 then return nil end

    -- KURVE VORWEGNEHMEN. Der Bot dreht hoechstens 330 Grad/s und laeuft
    -- 32 Studs/s — sein engster fahrbarer Kurvenradius ist damit 5.6 Studs.
    -- Zielt er stur auf den aktuellen Wegpunkt, kann er erst einlenken,
    -- wenn er schon darueber hinaus ist; an einer Dachkante bedeutet das
    -- Absturz. Also wird ab 7 Studs Naehe die Richtung zum naechsten Punkt
    -- eingemischt, zunehmend staerker je naeher er kommt.
    -- Ausgenommen sind Punkte, an denen die Position genau stimmen muss:
    -- Leiter, Zipline, Jumppad und Tuerdurchgaenge.
    local nxt = wps[PATH.idx + 1]
    local exact = (wp.kind == "climb" or wp.kind == "zip"
                   or wp.kind == "pad" or wp.kind == "via")
    if nxt and not exact and dir.Magnitude < 7 then
        local nextExact = (nxt.kind == "climb" or nxt.kind == "zip"
                           or nxt.kind == "pad" or nxt.kind == "via")
        local d2 = (nxt.Position - pos) * Vector3.new(1, 0, 1)
        -- nicht ueber einen Absprung hinweg mischen: der Sprung braucht
        -- die volle Richtung auf seinen eigenen Punkt
        local jumpNext = (nxt.Action == Enum.PathWaypointAction.Jump)
        if d2.Magnitude > 0.1 and not nextExact and not jumpNext then
            local blend = math.clamp((1 - dir.Magnitude / 7) * 0.6, 0, 0.6)
            local mixed = dir.Unit * (1 - blend) + d2.Unit * blend
            if mixed.Magnitude > 0.05 then return mixed.Unit end
        end
    end
    return dir.Unit
end

-- Zentrale Sicherheitspruefung fuer JEDE Richtungsaenderung (Finte, Ausweichen,
-- Abstecher): simuliert 14 Studs voraus und lehnt alles ab, was auf einen
-- Verfolger zulaeuft oder den Abstand zu ihm verkleinert.
local function movesTowardThreat(pos, cand)
    if not cand then return true end
    local future = pos + cand * 14
    for _, t in ipairs(state.threats or {}) do
        local v = (t.pos - pos) * Vector3.new(1, 0, 1)
        local dNow = v.Magnitude
        if dNow > 0.1 and dNow < 70 then
            if cand:Dot(v.Unit) > 0.0 then return true end
            if ((t.pos - future) * Vector3.new(1, 0, 1)).Magnitude < dNow then return true end
        end
    end
    return false
end

local function refreshRaycastFilter()
    if tick() - AP.rpAt < 0.75 then return end
    AP.rpAt = tick()
    local ignore = { workspace.CurrentCamera }
    for _, pl in ipairs(Players:GetPlayers()) do
        if pl.Character then ignore[#ignore + 1] = pl.Character end
    end
    for _, n in ipairs({ "EmotePuppets", "ragdolls", "bullets", "Displayed", "coins" }) do
        local f = workspace:FindFirstChild(n)
        if f then ignore[#ignore + 1] = f end
    end
    AP.rp.FilterDescendantsInstances = ignore
end

-- Strahl auf einer Hoehe: 0 = sofort Wand, 1 = freie Bahn
local PROBE = 11
local function rayClear(pos, dir, height, len)
    len = len or PROBE
    local from = pos + Vector3.new(0, height, 0)
    local hit = workspace:Raycast(from, dir * len, AP.rp)
    if not hit then return 1 end
    return (hit.Position - from).Magnitude / len
end

-- rutschige Materialien: darauf verliert der Charakter die Kontrolle
local SLIPPERY = {
    [Enum.Material.Ice] = true,
    [Enum.Material.Glacier] = true,
    [Enum.Material.Snow] = true,
}
-- Flaechen, die Schaden machen: das Spiel markiert sie per Attribut
local function isHarmful(hit)
    local inst = hit and hit.Instance
    if not inst then return false end
    if inst:GetAttribute("Lava") then return true end
    local cd = inst:GetAttribute("ContactDamage")
    if cd and cd > 0 then return true end
    local par = inst.Parent
    if par and (par:GetAttribute("Lava") or (par:GetAttribute("ContactDamage") or 0) > 0) then
        return true
    end
    return false
end

local function isSlippery(hit)
    if not hit then return false end
    if SLIPPERY[hit.Material] then return true end
    local inst = hit.Instance
    if inst then
        local ok, props = pcall(function() return inst.CustomPhysicalProperties end)
        if ok and props and inst.CustomPhysicalProperties ~= nil then
            if props.Friction and props.Friction < 0.25 then return true end
        end
    end
    return false
end

-- steht dort vorne Boden? (Abgrund / Void / Eis)
-- Rueckgabe: hatBoden, istRutschig
local function groundAt(pos, dir, dist, tol)
    local from = pos + dir * dist + Vector3.new(0, 3, 0)
    local hit = workspace:Raycast(from, Vector3.new(0, -60, 0), AP.rp)
    if not hit then return false, false end
    -- Erlaubte Fallhoehe gestaffelt: direkt vor den Fuessen streng (da faellt
    -- man wirklich), weiter voraus grosszuegig — sonst gilt auf Maps mit
    -- vielen Absaetzen fast jede Richtung als Abgrund und er bleibt stehen.
    local maxDrop = tol or ((AP.mode == "FLUCHT") and 18 or 12)
    if hit.Position.Y <= pos.Y - maxDrop then return false, false end
    -- Lava zaehlt wie "kein Boden": da will man nicht hin
    if isHarmful(hit) then return false, true end
    return true, isSlippery(hit)
end

-- Vollbild einer Richtung: Brust frei? Knie frei? Boden nah/weit?
-- Knie blockiert + Brust frei = niedriges Hindernis -> drueber vaulten statt wegdrehen.
-- Boden nah fehlt + Boden weit da = Luecke -> drueber springen statt wegdrehen.
local function probeDir(pos, dir)
    local chest = rayClear(pos, dir, 2.4)
    local knee  = rayClear(pos, dir, 0.5)
    local gNear, slipNear = groundAt(pos, dir, 6, 9)      -- Schritt: streng
    local gFar, slipFar = groundAt(pos, dir, 13, 30)     -- Sichtweite: locker
    local vault = (knee < 0.3 and chest > 0.6)
    local gap   = (not gNear and gFar)
    local passable = chest
    if vault then passable = chest end
    local score = 0
    if chest < 0.3 then
        score = -2.5                      -- echte Wand
    else
        score = passable
    end
    local groundScore
    if gNear and gFar then groundScore = 1
    elseif gNear then groundScore = 0.25  -- Schritt sicher, dahinter Kante:
                                          -- klar abwerten, sonst laeuft er
                                          -- wissentlich darueber und faellt
    elseif gap then groundScore = 0.5     -- ueberspringbare Luecke
    else groundScore = -2.5 end           -- echter Abgrund direkt voraus
    -- Eis/rutschiges Zeug klar abwerten: dort ist die Steuerung weg
    if slipNear then groundScore = groundScore - 2.2 end
    if slipFar then groundScore = groundScore - 0.8 end
    return score, groundScore, (vault or gap)
end

-- Vorausschau gegen Sackgassen: an dem Punkt, den diese Richtung in ~12 Studs
-- erreicht, wird rundum geprueft, wieviele Auswege es dort noch gibt. Eine
-- Ecke erkennt man erst so — an der aktuellen Position sieht sie frei aus.
local function escapeRoutes(pos, dir, horizon)
    horizon = horizon or 12
    local reach = math.min(horizon, rayClear(pos, dir, 2.4, horizon) * horizon)
    if reach < 4 then return 0 end
    local p2 = pos + dir * (reach - 1) + Vector3.new(0, 2.4, 0)
    local open = 0
    for i = 0, 5 do
        local a = i * (math.pi * 2 / 6)
        local d2 = Vector3.new(math.cos(a), 0, math.sin(a))
        if not workspace:Raycast(p2, d2 * 10, AP.rp) then open = open + 1 end
    end
    return open
end

-- beste Laufrichtung.
--  * Waende: entlanggleiten statt reinlaufen
--  * Hindernis/Luecke: drueber springen
--  * ECKEN: bewertet wird nicht nur "ist es geradeaus frei", sondern wie offen
--    der ganze Sektor ringsum ist. Eine Ecke/Sackgasse ist genau dann schlecht,
--    wenn auch die Nachbarrichtungen dicht sind — dadurch laeuft er gar nicht
--    erst hinein, statt sich spaeter wieder herausruckeln zu muessen.
--  * Neuberechnung nur alle 80 ms (36 Richtungen x 4 Strahlen pro Frame waere
--    sinnlos teuer); dazwischen wird die gewaehlte Richtung gehalten.
local N_DIRS = 24
local function pickDirection(pos, goalDir, curVel)
    refreshRaycastFilter()
    local up = Vector3.new(0, 2.4, 0)

    -- Wandgleiten: Zielrichtung entlang der Wandflaeche umlenken.
    -- Gemessen war das die mit Abstand haeufigste Haengerursache: in 52 von
    -- 52 Faellen zeigte die Laufrichtung direkt in eine Wand. Darum auf
    -- zwei Hoehen pruefen (Huefte und knapp ueber dem Boden, sonst werden
    -- niedrige Kanten uebersehen) und, falls das Abgleiten selbst wieder
    -- in die Wand fuehrt, zusaetzlich zur Seite aufdrehen.
    -- Bei einem geplanten Weg nur sanft abgleiten: der Graph hat die
    -- Begehbarkeit geprueft, und das harte Abdrehen unten hat die
    -- Wegrichtung um im Schnitt 108 Grad verbogen — der Weg wurde damit
    -- praktisch ignoriert.
    -- Auf einem geplanten Weg gar kein Gleiten mehr: gemessen hat es die
    -- Richtung des Folgers um 17.5 Grad verbogen, obwohl der Graph die
    -- Begehbarkeit bereits geprueft hat. Bleibt er dort wirklich haengen,
    -- faengt das die Wegneuplanung ab.
    -- AP.pathLoose: der Fortschrittswaechter im Wegpunkt-Folger meldet, dass
    -- der Bot seit ueber einer Sekunde nicht naeher an seinen Wegpunkt kommt.
    -- Dann gilt der Weg nur noch als Richtungsvorschlag, und es laeuft
    -- dieselbe Nahbereichssteuerung wie beim Weglaufen: Wandgleiten und Wahl
    -- der offensten Richtung. Genau das fehlte, als er vor einem Durchgang
    -- Kreise drehte, obwohl daneben alles frei war.
    local onPath = AP.usingPath and (AP.pathExact or not AP.pathLoose)
    local blockHit = (not onPath)
        and workspace:Raycast(pos + up, goalDir * 6, AP.rp) or nil
    if not blockHit and not onPath then
        blockHit = workspace:Raycast(pos + Vector3.new(0, 0.6, 0), goalDir * 5, AP.rp)
    end
    if blockHit then
        local slide = goalDir - blockHit.Normal * goalDir:Dot(blockHit.Normal)
        slide = slide * Vector3.new(1, 0, 1)
        if slide.Magnitude > 0.08 then
            goalDir = slide.Unit
            -- zweite Runde: liegt auch der Gleitweg zu, staerker abdrehen.
            -- Auf einem geplanten Weg entfaellt das.
            if not onPath and workspace:Raycast(pos + up, goalDir * 4, AP.rp) then
                local n2 = blockHit.Normal * Vector3.new(1, 0, 1)
                if n2.Magnitude > 0.05 then
                    local sideN = Vector3.new(-n2.Unit.Z, 0, n2.Unit.X)
                    local pick = (sideN:Dot(goalDir) >= 0) and sideN or -sideN
                    goalDir = (pick * 1.2 + n2.Unit * 0.5).Unit
                end
            end
        elseif not onPath then
            -- frontal auf die Wand: entlang ihrer Flaeche ausweichen
            local n2 = blockHit.Normal * Vector3.new(1, 0, 1)
            if n2.Magnitude > 0.05 then
                local sideN = Vector3.new(-n2.Unit.Z, 0, n2.Unit.X)
                goalDir = ((math.random() < 0.5) and sideN or -sideN)
            end
        end
    end

    -- LAEUFT EIN BERECHNETER WEG, GILT SEINE RICHTUNG.
    -- Darunter waehlt diese Funktion aus 16 Richtungen die "offenste" und
    -- gewichtet die Zielrichtung nur als einen Faktor unter mehreren. Fuer
    -- freies Laufen ist das richtig, bei einem geplanten Weg aber fatal:
    -- der Graph hat die Begehbarkeit bereits geprueft, und die Neuwahl
    -- fuehrt den Bot sichtbar vom Pfad weg — teilweise mitten in eine Wand.
    -- Das Wandgleiten oben bleibt aktiv, damit er nicht stur dagegenrennt.
    -- Haengt er fest (AP.pathLoose), faellt er bewusst in die freie
    -- Richtungswahl darunter — dort wird der Weg nur noch gewichtet.
    if onPath then
        -- Kleine Hindernisse kennt der Graph nicht: sein Raster ist 4 bis 9
        -- Studs weit, Moebel und Deko in Innenraeumen fallen komplett durch.
        -- Die Richtung bleibt daher unveraendert, aber es wird gesprungen
        -- beziehungsweise knapp ausgewichen, statt dagegenzulaufen.
        -- Nicht im Flug: gegen Ende eines Sprungbogens trifft der Strahl die
        -- STIRNSEITE der Zielkante. Der Zweig unten hat den Kurs daraufhin um
        -- bis zu 40 Grad zur Seite gedreht — direkt vor der Landung, also
        -- genau dann, wenn nichts mehr korrigiert werden darf.
        local kneeH = (not PATH.air)
            and workspace:Raycast(pos + Vector3.new(0, 0.6, 0), goalDir * 4, AP.rp) or nil
        local chestH = (not PATH.air)
            and workspace:Raycast(pos + Vector3.new(0, 3.2, 0), goalDir * 4, AP.rp) or nil
        if kneeH and not chestH then
            -- niedrig genug zum Drueberspringen
            if tick() - (AP.pathVaultAt or 0) > 0.5 then
                AP.pathVaultAt = tick()
                tryJump(true)
            end
        elseif kneeH and chestH then
            -- volles Hindernis: knapp seitlich vorbei, ohne den Kurs
            -- aufzugeben
            local n = kneeH.Normal * Vector3.new(1, 0, 1)
            if n.Magnitude > 0.05 then
                local sideN = Vector3.new(-n.Unit.Z, 0, n.Unit.X)
                if sideN:Dot(goalDir) < 0 then sideN = -sideN end
                local mixed = (goalDir + sideN * 0.9)
                if mixed.Magnitude > 0.05 then goalDir = mixed.Unit end
            end
        end
        AP.lastDir, AP.dirAt = goalDir, tick()
        return goalDir
    end

    -- WAEHREND EINER FINTE GILT DIE CHOREOGRAFIE.
    -- Darunter wuerde aus 24 Richtungen die offenste gewaehlt — das sind rund
    -- 70 Raycasts je Aufruf. Waehrend eines Manoevers ist die Richtungshaltung
    -- ausgeschaltet (holdFor = 0), der Scan lief dort also in JEDEM Frame und
    -- war als Ruckeln beim Umschauen zu spueren. Gebraucht wird er dabei
    -- ohnehin nicht: das Manoever gibt die Richtung vor und prueft sie selbst
    -- gegen Waende und Kanten. Das Wandgleiten oben bleibt aktiv.
    if AP.jukeName then
        AP.lastDir, AP.dirAt = goalDir, tick()
        return goalDir
    end

    -- gehaltene Richtung zwischen den Neuberechnungen
    local juking2 = (AP.feintUntil and tick() < AP.feintUntil)
                    or (AP.move and tick() < (AP.move.tEnd or 0))
    local ak2 = math.clamp(CFG.ankles or 3, 0, 10)
    local holdFor = juking2 and 0
        or (((AP.mode == "JAGD") and 0.16 or 0.08) * math.max(1 - 0.09 * ak2, 0.1))
    if AP.dirAt and tick() - AP.dirAt < holdFor and AP.lastDir then
        return AP.lastDir
    end
    AP.dirAt = tick()

    local velDir = curVel.Magnitude > 4 and (curVel * Vector3.new(1, 0, 1)).Unit or Vector3.zero
    local dirs, clear, ground, jump = {}, {}, {}, {}

    -- 1. Durchgang: Umgebung abtasten
    for i = 1, N_DIRS do
        local a = (i - 1) * (math.pi * 2 / N_DIRS)
        local dir = Vector3.new(math.cos(a), 0, math.sin(a))
        dirs[i] = dir
        if dir:Dot(goalDir) > -0.5 then
            local clScore, grScore, needJump = probeDir(pos, dir)
            clear[i], ground[i], jump[i] = clScore, grScore, needJump
        else
            -- grob nach hinten: nur billig pruefen, zaehlt aber fuer die Offenheit
            clear[i] = rayClear(pos, dir, 2.4, 7)
            ground[i] = 0
            jump[i] = false
        end
    end

    -- 2. Durchgang: Offenheit = wie frei ist der Sektor um die Richtung herum
    local best, bestScore, bestJump
    local ranked = {}
    for i = 1, N_DIRS do
        if ground[i] ~= 0 or clear[i] then
            local dir = dirs[i]
            local align = dir:Dot(goalDir)
            if align > -0.45 then
                local open, cnt = 0, 0
                for k = -2, 2 do
                    local idx = ((i - 1 + k) % N_DIRS) + 1
                    open = open + math.max(clear[idx] or 0, 0)
                    cnt = cnt + 1
                end
                open = open / cnt
                local keep = velDir ~= Vector3.zero and dir:Dot(velDir) * 0.35 or 0
                -- Randbereich: Richtungen zur Mitte werden zusaetzlich belohnt
                local mid = 0
                local pc, pr2 = playfield()
                if pc and pr2 and AP.mode ~= "JAGD" then
                    local toC = (pc - pos) * Vector3.new(1, 0, 1)
                    local dc = toC.Magnitude
                    if dc > pr2 * 0.5 and toC.Magnitude > 0.1 then
                        mid = dir:Dot(toC.Unit) * math.clamp(dc / pr2 - 0.5, 0, 1.2) * 3.0
                    end
                end
                -- VERFOLGER: jede Richtung, die den Abstand zu einem Jaeger
                -- verkleinert, wird bestraft — nah dran mit Veto-Gewicht.
                -- (Beim Jagen zaehlt das eigene Ziel nicht als Bedrohung.)
                local threatPen = 0
                for _, t in ipairs(state.threats or {}) do
                    local tv = (t.pos - pos) * Vector3.new(1, 0, 1)
                    local td = tv.Magnitude
                    if td > 0.1 and td < 70 and not (AP.preyPos and (t.pos - AP.preyPos).Magnitude < 3) then
                        local approach = dir:Dot(tv.Unit)          -- 1 = direkt hin
                        if approach > 0 then
                            local near = math.clamp((70 - td) / 70, 0, 1)
                            local w = t.mobile and 1 or 0.15   -- Stehende sperren nicht den Weg
                            threatPen = threatPen + approach * near * (td < 25 and 9 or 4.5) * w
                        end
                    end
                end
                local s = align * (AP.mode == "JAGD" and 3.2 or 1.5)
                        - threatPen
                        + (clear[i] or 0) * 1.8
                        -- Boden deutlich staerker gewichten: mit 1.6 stand
                        -- "sicherer Boden" gegen "dahinter Kante" nur 0.48
                        -- auseinander, waehrend die Zielrichtung bis 3.2
                        -- zaehlte. Ergebnis waren 43 Landungen bei 25
                        -- Spruengen — er lief laufend ueber Kanten.
                        + (ground[i] or 0) * 2.6
                        -- Offenheit: 3.2 plus Strafmalus hatte keinen belegten
                        -- Nutzen und stand im Verdacht, die Wegtreue zu
                        -- verschlechtern. Zurueck auf den gemessenen Stand.
                        + open * 1.7
                        + mid                   -- am Rand zur Mitte ziehen
                        + keep
                ranked[#ranked + 1] = { dir = dir, s = s, jump = jump[i] }
                if not bestScore or s > bestScore then
                    best, bestScore, bestJump = dir, s, jump[i]
                end
            end
        end
    end
    -- Die besten Kandidaten gegen die Vorausschau pruefen: eine Richtung, die
    -- in eine Kammer mit nur einem Ausgang fuehrt, wird hart abgewertet.
    if #ranked > 1 then
        table.sort(ranked, function(a, b) return a.s > b.s end)
        local fleeing = (AP.mode == "FLUCHT")
        local topN = math.min(#ranked, fleeing and 7 or 4)
        local horizon = fleeing and 22 or 12     -- beim Fliehen weiter schauen
        -- Stehen wir schon in einer Kammer? Dann zaehlt fast nur noch, wo es
        -- ueberhaupt noch weitergeht.
        local hereOpen = 0
        for i = 0, 7 do
            local a = i * (math.pi * 2 / 8)
            local d2 = Vector3.new(math.cos(a), 0, math.sin(a))
            if not workspace:Raycast(pos + Vector3.new(0, 2.4, 0), d2 * 14, AP.rp) then
                hereOpen = hereOpen + 1
            end
        end
        local trapped = hereOpen <= 3
        AP.trapped = trapped
        local bb, bs, bj
        for i = 1, topN do
            local r = ranked[i]
            local routes = escapeRoutes(pos, r.dir, horizon)
            local pen = 0
            if routes <= 1 then pen = 4.5
            elseif routes == 2 then pen = 1.8
            elseif routes >= 4 then pen = -0.8 end
            if fleeing then pen = pen * 1.6 end          -- Sackgassen beim Fliehen teurer
            local sc = r.s - pen + (trapped and routes * 1.4 or 0)
            if not bs or sc > bs then bb, bs, bj = r.dir, sc, r.jump end
        end
        if bb then best, bestScore, bestJump = bb, bs, bj end
        if trapped and not AP.trappedLogged then
            AP.trappedLogged = true
            LOG("in der Enge — Richtung mit den meisten Auswegen gewaehlt")
        elseif not trapped then
            AP.trappedLogged = false
        end
    end

    -- Steckt der Bogen nach vorne fest (Ecke/Sackgasse), wird ohne
    -- Richtungsfilter neu bewertet — auch zurueck ist dann erlaubt. Sonst
    -- rennt er bei einer Beeline stur in die Ecke.
    if not best or (bestScore and bestScore < 0.9) then
        local b2, s2, j2
        for i = 1, N_DIRS do
            local dir = dirs[i]
            local cl = clear[i]
            if cl == nil then
                cl = rayClear(pos, dir, 2.4, 9)
                clear[i] = cl
            end
            local open, cnt = 0, 0
            for k = -2, 2 do
                local idx = ((i - 1 + k) % N_DIRS) + 1
                open = open + math.max(clear[idx] or 0, 0)
                cnt = cnt + 1
            end
            open = open / cnt
            local tp = 0
            for _, t in ipairs(state.threats or {}) do
                local tv = (t.pos - pos) * Vector3.new(1, 0, 1)
                local td = tv.Magnitude
                if td > 0.1 and td < 70 then
                    local ap2 = dir:Dot(tv.Unit)
                    if ap2 > 0 then tp = tp + ap2 * math.clamp((70 - td) / 70, 0, 1) * 9 end
                end
            end
            local sc = dir:Dot(goalDir) * 0.6 + cl * 2.2 + open * 2.4 - tp
            if not s2 or sc > s2 then b2, s2, j2 = dir, sc, jump[i] end
        end
        if b2 and (not bestScore or s2 > bestScore) then
            best, bestScore, bestJump = b2, s2, j2
            AP.lastDir = nil               -- Hysterese loesen, sonst klebt er
        end
    end
    if not best then return nil end

    -- Hysterese gegen Zickzack: alte Richtung behalten, wenn fast gleich gut
    if AP.lastDir and not juking2 then
        local clScore, grScore, needJump = probeDir(pos, AP.lastDir)
        if clScore > 0.45 and grScore > 0 then
            local prevScore = AP.lastDir:Dot(goalDir) * 1.5 + clScore * 1.8 + grScore * 1.6
                + (velDir ~= Vector3.zero and AP.lastDir:Dot(velDir) * 0.35 or 0)
                + clScore * 1.7
            local tol = ((AP.mode == "JAGD") and 1.2 or 0.45)
                        * math.max(1 - 0.09 * (CFG.ankles or 3), 0.15)
            if prevScore > bestScore - tol then
                best, bestJump = AP.lastDir, needJump
            end
        end
    end
    -- Die eigentliche Drehung passiert pro Frame in autopilotStep (Drehrate
    -- statt Sprung), hier wird nur die Wunschrichtung festgelegt.
    AP.lastDir, AP.needJump = best, bestJump
    return best, bestScore
end

-- WICHTIG: In diesem Spiel ist Sprint der Normalzustand, der Keybind "run"
-- schaltet aufs LANGSAME Gehen. Deshalb wird hier bewusst NICHTS an der
-- Keybind-Abfrage gedreht — ein Eingriff dort bremst den Charakter dauerhaft.

-- Move-Vektor uebernehmen
local hookedCM
local function hookControlModule()
    local cm = RENV.shared.controlModule
    if not cm or hookedCM == cm then return end
    local orig = rawget(cm, "GetMoveVector") or cm.GetMoveVector
    if not orig then return end
    hookedCM = cm
    AP.origGetMoveVector = orig
    cm.GetMoveVector = function(self, ...)
        local v = orig(self, ...)
        if typeof(v) == "Vector3" and v.Magnitude > 0.15 then
            AP.manualUntil = tick() + 0.5        -- eigener Input schlaegt Autopilot
            return v
        end
        -- Richtung verfaellt: bricht der Autopilot-Schritt ab (Fehler,
        -- fehlender Charakter, Rundenwechsel), blieb die zuletzt gesetzte
        -- Richtung im Hook stehen und der Bot lief stur immer weiter
        -- geradeaus, ohne dass sie noch jemand aktualisiert haette.
        if AP.vecAt and tick() - AP.vecAt > 0.4 then
            AP.vec, AP.vecWorld = nil, nil
        end
        if CFG.autopilot and AP.vec and tick() > AP.manualUntil then
            -- Die Richtung wird als WELTrichtung gehalten und erst hier in
            -- den Kameraraum gerechnet. Frueher lag sie schon kamerarelativ
            -- in AP.vec: drehte man die Maus zwischen zwei
            -- Autopilot-Schritten, wurde derselbe Vektor gegen die neue
            -- Kameraausrichtung gelesen — die Blickrichtung hat die
            -- Laufrichtung verbogen.
            if AP.vecWorld then
                local ch = LP.Character
                local vs = ch and ch:FindFirstChild("values")
                local cy = vs and vs:FindFirstChild("CameraY")
                if cy then
                    local r = cy.Value:VectorToObjectSpace(AP.vecWorld)
                    r = Vector3.new(r.X, 0, r.Z)
                    if r.Magnitude > 0.05 then return r.Unit end
                end
            end
            return AP.vec
        end
        return v
    end
    LOG("controlModule gehookt")
end

-- ---------------------------------------------------------------------
-- WALLRIDE-KLETTERN als eigene Routine.
-- Spielregeln (aus dem Code): Ansetzen geht nur in der LUFT, die Wand muss
-- SEITLICH liegen (Strahl entlang RightVector, 5 Studs, Normale waagerecht),
-- und derselbe Sprungknopf setzt an bzw. stoesst ab. Also: parallel zur Wand
-- ausrichten, Abstand ~3 Studs halten, im Takt springen.
-- Rueckgabe: Laufrichtung oder nil, wenn keine kletterbare Wand da ist.
-- ---------------------------------------------------------------------
local function climbStep(pos, dirHint)
    local char = LP.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if not (hrp and hum) then return nil end
    refreshRaycastFilter()

    -- Wand suchen: seitlich (wie das Spiel), dann voraus, dann rundum
    local right = (hrp.CFrame.RightVector * Vector3.new(1, 0, 1))
    local wall
    if right.Magnitude > 0.1 then
        right = right.Unit
        for _, sgn in ipairs({ 1, -1 }) do
            local h = workspace:Raycast(hrp.Position, right * sgn * 5, AP.rp)
            if h and math.abs(h.Normal.Y) < 0.15 then wall = h break end
        end
    end
    if not wall and dirHint then
        local h = workspace:Raycast(pos + Vector3.new(0, 1.5, 0), dirHint * 6, AP.rp)
        if h and math.abs(h.Normal.Y) < 0.15 then wall = h end
    end
    if not wall then
        local bd
        for i = 0, 11 do
            local a = i * (math.pi * 2 / 12)
            local d = Vector3.new(math.cos(a), 0, math.sin(a))
            local h = workspace:Raycast(pos + Vector3.new(0, 1.5, 0), d * 7, AP.rp)
            if h and math.abs(h.Normal.Y) < 0.15 then
                local dd = (h.Position - pos).Magnitude
                if not bd or dd < bd then wall, bd = h, dd end
            end
        end
    end
    if not wall then
        AP.climbAssist = false
        AP.climbTan = nil
        local m = RENV.shared.multipliers
        if m then m.RotateInMoveDirection = CFG.faceRun end
        return nil
    end

    -- lohnt die Wand? (weiter oben muss noch Flaeche sein)
    if not workspace:Raycast(pos + Vector3.new(0, 8, 0), -wall.Normal * 7, AP.rp) then
        AP.climbAssist = false
        return nil
    end
    -- Kein Wallride unter einem Ueberhang: ragt oberhalb etwas ueber die
    -- Wand hinaus, stoesst man sich dort den Kopf und rutscht wieder ab.
    -- Der Graph prueft das fuer seine Sprungkanten laengst, die
    -- Nahbereichssteuerung bisher nicht.
    do
        local lip = pos + Vector3.new(0, 7.5, 0) - wall.Normal * 1.5
        if workspace:Raycast(lip, Vector3.new(0, 6, 0), AP.rp) then
            AP.climbAssist = false
            return nil
        end
    end

    local tan = wall.Normal:Cross(Vector3.new(0, 1, 0)) * Vector3.new(1, 0, 1)
    if tan.Magnitude < 0.05 then return nil end
    tan = tan.Unit
    if dirHint and tan:Dot(dirHint) < 0 then tan = -tan end
    if AP.climbTan and tan:Dot(AP.climbTan) < 0 then tan = AP.climbTan end   -- Seite halten
    AP.climbTan = tan

    -- Aus der Aufnahme des Spielers: waehrend des Wallruns betraegt der
    -- Wandabstand konstant ~1.0 Studs und der Input ist reines Vorwaerts.
    -- Also dicht an die Wand regeln und entlanglaufen.
    local dWall = (wall.Position - hrp.Position).Magnitude
    local push = math.clamp((dWall - 1.2) * 0.5, -0.5, 0.8)
    local dir = (tan - wall.Normal * push) * Vector3.new(1, 0, 1)
    if dir.Magnitude < 0.05 then return nil end
    dir = dir.Unit

    -- Parallel zur Wand ausrichten, damit RightVector auf sie zeigt.
    -- NUR wenn der Bot auch wirklich in der Luft ist: dieser Zweig laeuft
    -- jeden Frame, sobald ueberhaupt eine Wand in Reichweite steht. Am
    -- Boden hat er damit dauerhaft die Blickrichtung an die Kamera
    -- gekoppelt statt an die Laufrichtung — beim Weglaufen entlang von
    -- Waenden war das praktisch durchgehend der Fall.
    -- In der Luft allein reicht als Bedingung nicht: der Bot ist rund 40 %
    -- der Zeit in der Luft, und dort hing die Blickrichtung dann dauerhaft
    -- an der Kamera. Ein echter Wallrun STEIGT dabei — ein normaler Sturz
    -- nicht. Also zusaetzlich auf aufwaerts gerichtete Geschwindigkeit
    -- pruefen.
    local humW = LP.Character and LP.Character:FindFirstChildOfClass("Humanoid")
    local airborne = humW and humW.FloorMaterial == Enum.Material.Air
    local rising = hrp.AssemblyLinearVelocity.Y > 2
    if airborne and rising then
        local m = RENV.shared.multipliers
        if m then
            m.RotateInMoveDirection = false
            AP.climbRotating = true
        end
        hrp.CFrame = CFrame.lookAt(hrp.Position, hrp.Position + tan)
    end

    -- SPRUNG-TIMING (der eigentliche Knackpunkt):
    -- Ein Sprung waehrend eines laufenden Wallruns bedeutet ABSTOSSEN. Wer im
    -- Takt spammt, bricht damit jeden Wallrun sofort wieder ab. In der
    -- Aufnahme laeuft ein Wallrun ~0.8 s und traegt den Spieler gut 3 Studs
    -- hoch; erst wenn der Auftrieb verbraucht ist (vy faellt gegen 0), kommt
    -- der naechste Sprung. Genau so wird es hier gemacht.
    local vy = hrp.AssemblyLinearVelocity.Y
    local liftSpent = vy < 1.5
    if liftSpent and tick() - (AP.lastJump or 0) > 0.32 then
        AP.lastJump = tick()
        AP.wallChain = (AP.wallChain or 0) + 1
        tryJump(true)
    end
    AP.climbAssist = true
    return dir
end

-- ---------------------------------------------------------------------
-- HOEHEN-SUCHER: sucht in Laufrichtung erhoehte Standflaechen — Baeume,
-- schwebende Baelle, Vorspruenge, Kisten. Oben ist man schwerer zu fangen
-- und hat mehr Fluchtwege, deshalb wird so eine Flaeche angesteuert und im
-- richtigen Moment angesprungen.
-- Rueckgabe: Richtung zur Flaeche (oder nil) und ob gesprungen werden soll.
-- ---------------------------------------------------------------------
local function findHighSpot(pos, dirHint)
    if AP.highAt and tick() - AP.highAt < 0.4 then
        return AP.highDir, AP.highSpot
    end
    AP.highAt = tick()
    refreshRaycastFilter()
    local best, bestScore, bestPos
    for i = 0, 11 do
        local a = i * (math.pi * 2 / 12)
        local d = Vector3.new(math.cos(a), 0, math.sin(a))
        local align = dirHint and d:Dot(dirHint) or 1
        if align > -0.35 then
            for _, dist in ipairs({ 6, 12, 20, 28 }) do
                local probe = pos + d * dist
                local hit = workspace:Raycast(probe + Vector3.new(0, 26, 0),
                                              Vector3.new(0, -34, 0), AP.rp)
                if hit then
                    local gain = hit.Position.Y - pos.Y
                    -- erreichbar und lohnend: ueber Kopfhoehe, aber springbar
                    if gain > 2.5 and gain < 16 then
                        -- steht dort oben genug Platz? (kein Deckel direkt drueber)
                        local head = workspace:Raycast(hit.Position + Vector3.new(0, 1, 0),
                                                       Vector3.new(0, 5, 0), AP.rp)
                        if not head then
                            local safe = true
                            for _, t in ipairs(state.threats or {}) do
                                if (t.pos - hit.Position).Magnitude < dist * 0.8 then safe = false break end
                            end
                            if safe then
                                local sc = gain * 0.35 + align * 2 - dist / 28
                                if not bestScore or sc > bestScore then
                                    best, bestScore, bestPos = d, sc, hit.Position
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    AP.highDir, AP.highSpot = best, bestPos
    return best, bestPos
end


------------------------------------------------------------------
-- 5b) AYIP — Juke-Repertoire
--     Jeder Move ist ein eigener Eintrag mit Vorbedingung, Phasen und
--     eigenem Cooldown. Frueher lagen die Manoever als lose Variablen
--     (peelUntil, squeezeUntil, bamboozleUntil ...) im Autopilot
--     verteilt; dadurch konnten sie einander ueberschreiben, und einen
--     gemeinsamen Takt gab es nicht.
--     Richtungen sind relativ zur Laufrichtung gedacht: 12 Uhr ist
--     voraus, 9 und 3 Uhr sind die Seiten.
------------------------------------------------------------------
local JUKE = { active = nil, cd = {}, lastAny = 0, count = 0, log = {},
               -- Wirkungsmessung je Manoever: wie viel Abstand hat es
               -- gebracht? Ohne das ist jede Aenderung am Repertoire
               -- Geschmackssache.
               stat = {}, base = { n = 0, sum = 0 } }
AP.juke = JUKE

-- Bericht ueber die Wirkung der Manoever. Verglichen wird der
-- Abstandsgewinn zum Verfolger ueber 1.2 s nach dem Manoever gegen
-- denselben Zeitraum OHNE Manoever — nur die Differenz ist aussagekraeftig,
-- weil der Abstand beim Weglaufen ohnehin schwankt.
function ENV.jukeReport()
    local base = (JUKE.base.n > 0) and (JUKE.base.sum / JUKE.base.n) or 0
    local out = { ("ohne Finte: %+.2f Studs je 1.2 s (aus %d Messungen)")
                  :format(base, JUKE.base.n) }
    local rows = {}
    for name, s in pairs(JUKE.stat) do
        rows[#rows+1] = { name = name, avg = s.sum / math.max(s.n, 1), n = s.n,
                          best = s.best, worst = s.worst }
    end
    table.sort(rows, function(a, b) return a.avg > b.avg end)
    for _, r in ipairs(rows) do
        out[#out+1] = ("%-12s %+.2f (gegen ohne: %+.2f)  n=%d  best %+.1f  schlecht %+.1f")
            :format(r.name, r.avg, r.avg - base, r.n, r.best, r.worst)
    end
    out[#out+1] = ("gestartet %d, abgebrochen (Tempo) %d, abgebrochen (Wand) %d")
        :format(JUKE.count, JUKE.aborted or 0, JUKE.wallAborts or 0)
    return table.concat(out, "\n")
end

local function turn(dir, deg)
    local a = math.rad(deg)
    local c, s = math.cos(a), math.sin(a)
    local v = Vector3.new(dir.X * c - dir.Z * s, 0, dir.X * s + dir.Z * c)
    return v.Magnitude > 0.01 and v.Unit or dir
end

-- Treppe, Rampe oder Leiter in der Naehe — Grundlage der mapbezogenen
-- Finten. Rueckgabe: Richtung dorthin und Art.
local function findRise(pos, facing)
    for _, l in ipairs(ladders()) do
        if l.Parent then
            local v = (l.Position - pos) * Vector3.new(1, 0, 1)
            local d = v.Magnitude
            if d > 3 and d < 22 and v.Unit:Dot(facing) > -0.2 then
                return v.Unit, "leiter"
            end
        end
    end
    for _, deg in ipairs({ 0, -30, 30, -60, 60 }) do
        local dir = turn(facing, deg)
        local gNear, hNear = groundAt(pos, dir, 4, 12)
        local gFar, hFar = groundAt(pos, dir, 10, 12)
        if gNear and gFar and hNear and hFar
           and (hFar - hNear) > 2.5
           and rayClear(pos, dir, 2.4, 10) > 0.7 then
            return dir, "rampe"
        end
    end
    return nil
end

-- Sucht eine Ecke oder Saeule in Laufrichtung, um die man eng herumziehen
-- kann: eine Richtung, in der etwas steht, unmittelbar daneben aber frei ist
-- und Boden liegt. Rueckgabe: Richtung zum Hindernis und die freie Seite.
local function findCorner(pos, facing)
    for _, deg in ipairs({ 0, -25, 25, -50, 50 }) do
        local dir = turn(facing, deg)
        local f = rayClear(pos, dir, 2.4, 12)
        -- Hindernis 4 bis 10 Studs voraus: nah genug zum Umrunden, weit
        -- genug, um ueberhaupt hinzukommen
        if f > 0.33 and f < 0.85 then
            for _, sdeg in ipairs({ 45, -45 }) do
                local sdir = turn(dir, sdeg)
                if rayClear(pos, sdir, 2.4, 12) > 0.95
                   and groundAt(pos, sdir, 8, 10) then
                    return dir, (sdeg > 0) and 1 or -1
                end
            end
        end
    end
    return nil
end

-- GEMESSENE WIRKUNG (2026-09-18, drei Laeufe auf CrossPaths/GlassHouses,
-- Abstandsgewinn zum Verfolger 1.2 s nach dem Manoever, Vergleichswert ohne
-- Finte lag bei -2.9 bis +1.1 Studs):
--     rollFeint   +17.5 Studs (n=9)
--     double180   +14.0        (n=5)
--     stairJuke   +11.5        (n=5)
--     cornerLoop   -0.7        (n=4)
--     bamboozle    -9.0        (n=2)
--     circle      -10.4        (n=1)
-- Die Kehren und die Rollfinte tragen das Repertoire; die langen Bogen- und
-- Sprungmanoever kosten eher Strecke. Deshalb dreht der Kreis jetzt kuerzer,
-- und die Auswahl gewichtet sich zur Laufzeit selbst nach Wirkung (siehe
-- jukeStep) — statt die schwachen Manoever zu loeschen, was bei n=1 bis 4
-- verfrueht waere.
local JUKE_MOVES = {
    -- 180 Grad antaeuschen und sofort wieder zurueck
    {   name = "double180", cd = 5, minLevel = 1, maxD = 29, minD = 6, turnBack = true,
        init = function(ctx, m)
            m.back = ctx.facing
            m.s = (math.random() < 0.5) and 1 or -1
        end,
        run = function(ctx, m, t)
            -- Kreisfoermig aufziehen statt sofort kehrt: erst seitlich weg,
            -- dann zunehmend nach hinten. Das haelt das Tempo (das Spiel
            -- setzt Momentum auf 0, sobald die Seitgeschwindigkeit unter
            -- 6.8 faellt) und sieht aus wie ein Bogen statt wie ein Knick.
            -- Kuerzer gehalten als commit180: das Double-Back lebt davon,
            -- schnell wieder zurueck zu sein, sonst ist es kein Antaeuschen
            -- mehr, sondern ein halber Umweg.
            -- Noch kuerzer: bei 32 Studs/s waren 0.38 s schon zwoelf Studs
            -- weg vom Kurs. Ein Antaeuschen soll knapp sein, sonst ist es
            -- ein Umweg.
            -- Sehr knapp halten: 0.26 s waren bei 32 Studs/s noch acht Studs
            -- abseits. Jetzt reicht es gerade fuer die Koerpertaeuschung,
            -- ohne nennenswert Strecke zu verlieren.
            -- Noch einen Tick knapper (0.17/0.44 -> 0.14/0.36): das Ausholen
            -- kostet bei vollem Tempo 4.5 statt 5.4 Studs, und der ganze
            -- Haken ist nach gut einer Drittelsekunde durch.
            if t < 0.14 then
                local p = t / 0.14
                return turn(ctx.facing, m.s * (75 + 95 * p))
            end
            if t < 0.36 then return m.back end
            return nil
        end },

    -- 180 Grad wirklich durchziehen und am Verfolger vorbeilaufen
    {   name = "commit180", cd = 5, minLevel = 2, maxD = 27, minD = 9, turnBack = true,
        init = function(ctx, m)
            m.s = (math.random() < 0.5) and 1 or -1
        end,
        run = function(ctx, m, t)
            -- Erst seitlich anreissen, dann kreisfoermig hinter den
            -- Verfolger aufdrehen und dort bleiben. Ein sofortiger
            -- 180er wuerde ihn ausbremsen.
            if t < 0.6 then
                local p = t / 0.6
                return turn(ctx.facing, m.s * (70 + 85 * p))
            end
            if t < 1.7 then return turn(ctx.facing, m.s * 155) end
            return nil
        end },

    -- Knoechelbrecher: 12 Uhr -> 9 Uhr -> 3 Uhr, ab Stufe 2 auch
    -- zurueck auf 9 Uhr und dort bleiben
    -- Vollkreis-Manoever: 270 oder 450 Grad am Stueck, kontinuierlich
    -- gedreht. Kein Umschnappen zwischen festen Richtungen — der Bot
    -- laeuft wirklich einen Kreis, weil eine Sprungdrehung das Momentum
    -- kostet (das Spiel setzt es auf 0, sobald die Seitgeschwindigkeit
    -- unter 6.8 faellt) und der Verfolger einen harten Knick ohnehin
    -- mitgeht. Ein Bogen laesst ihn dagegen aussen vorbeilaufen.
    {   name = "circle", cd = 5, minLevel = 1, maxD = 29, minD = 7, arc = true, skipWall = true,
        init = function(ctx, m)
            m.s = (math.random() < 0.5) and 1 or -1
            -- 270 Grad reicht meist, 450 ist die anderthalbfache Runde
            m.total = (ctx.level >= 2 and math.random() < 0.4) and 450 or 270
            -- so lang, dass es eine gefahrene Kurve wird und kein Drehen
            -- auf der Stelle. 210 Grad pro Sekunde war noch zu hastig,
            -- jetzt 165 - ein 270er dauert damit 1.6 s, ein 450er 2.7 s.
            m.dur = m.total / 165
        end,
        run = function(ctx, m, t)
            if t < m.dur then
                -- gleichmaessig aufdrehen statt springen
                return turn(ctx.facing, m.s * m.total * (t / m.dur))
            end
            return nil
        end },
    -- wieder auf dem Ausgangspunkt landen
    {   name = "bamboozle", cd = 8, minLevel = 2, maxD = 29, minD = 7, turnBack = true, mapMove = true,
        ready = function(ctx)
            local near = groundAt(ctx.pos, ctx.facing, 4, 10)
            local far = groundAt(ctx.pos, ctx.facing, 11, 14)
            return (near and not far) and true or false
        end,
        init = function(ctx, m) m.back = turn(ctx.facing, 180) end,
        run = function(ctx, m, t)
            if t < 0.18 then return ctx.facing end
            if t < 0.26 then
                tryJump(true)
                return ctx.facing
            end
            -- noch in der Luft kehrt machen, damit er wieder auf der
            -- Ausgangsflaeche landet statt unten
            if t < 0.9 then return m.back end
            return nil
        end },

    -- Treppen-/Leiterfinte: Aufstieg antaeuschen, dann abspringen.
    -- Entweder zurueck zum Ausgangspunkt oder seitlich weiter.
    {   name = "stairJuke", cd = 8, minLevel = 2, maxD = 38, minD = 8, mapMove = true,
        ready = function(ctx) return findRise(ctx.pos, ctx.facing) ~= nil end,
        init = function(ctx, m)
            local dir, kind = findRise(ctx.pos, ctx.facing)
            m.up, m.kind = dir or ctx.facing, kind
            m.commit = (math.random() < 0.5)
            if m.commit then
                m.away = turn(ctx.facing, (math.random() < 0.5) and 100 or -100)
            else
                m.away = turn(ctx.facing, 180)
            end
        end,
        run = function(ctx, m, t)
            -- Den Aufstieg lange genug antaeuschen, damit der Verfolger ihn
            -- kauft und mit hochkommt - sonst steht er unten und wartet.
            if t < 0.95 then return m.up end
            if t < 1.05 then
                tryJump(true)
                return m.up
            end
            if t < 2.0 then return m.away end
            return nil
        end },

    -- Eng um eine Ecke oder Saeule ziehen. Der Verfolger kommt mit Tempo an
    -- und kann den Knick nicht so eng fahren — er laeuft aussen vorbei und
    -- verliert dabei die Sichtlinie. Anders als die Kehren kostet das kaum
    -- Strecke, weil der Bot hinter dem Hindernis weiterlaeuft.
    {   name = "cornerLoop", cd = 6, minLevel = 1, maxD = 26, minD = 6,
        arc = true, skipWall = true, noMirror = true,
        ready = function(ctx) return findCorner(ctx.pos, ctx.facing) ~= nil end,
        init = function(ctx, m)
            local dir, side = findCorner(ctx.pos, ctx.facing)
            m.to, m.s = dir or ctx.facing, side or 1
        end,
        run = function(ctx, m, t)
            -- erst knapp an der Kante vorbei (auf der freien Seite) ...
            if t < 0.40 then return turn(m.to, m.s * 35) end
            -- ... dann eng herumziehen, solange das Tempo haelt
            if t < 1.20 then
                local p = (t - 0.40) / 0.80
                return turn(m.to, m.s * (35 + 125 * p))
            end
            return nil
        end },

    -- Rollfinte: waehrend der Rolle die Richtung wechseln
    {   name = "rollFeint", cd = 5, minLevel = 1, maxD = 29, minD = 6, arc = true,
        init = function(ctx, m)
            m.dir = turn(ctx.facing, (math.random() < 0.5) and 70 or -70)
            m.fired = false
        end,
        run = function(ctx, m, t)
            if not m.fired and type(keypress) == "function" then
                m.fired = true
                task.spawn(function()
                    pcall(keypress, 0x43)          -- C ist der Slide-Keybind
                    task.wait(0.16)
                    pcall(keyrelease, 0x43)
                end)
            end
            if t < 1.1 then return m.dir end
            return nil
        end },

}

-- Abstand bis zum naechsten Manoever, je Stufe. Deutlich groesser als
-- vorher (2.6/1.8/1.2): dauernde Tricks sehen nicht nach Koennen aus,
-- sondern nach Zappeln, und kosten jedes Mal Strecke.
local function jukeGap(level)
    return ({ 4.5, 3.4, 2.4 })[level] or 4.5
end

-- Waehlt ein Manoever und fuehrt es aus. Rueckgabe: Richtung oder nil.
------------------------------------------------------------------
-- 5c) FINTEN-SOUNDS
--     Spielt 0.25 s nach einer Finte einen Sound — aber nur, wenn sie
--     aufgegangen ist, also niemand getaggt hat.
--     Alles laeuft IM SPIEL und nur auf diesem Rechner: die Sounds
--     haengen an SoundService, kein Mikrofon, kein Voicechat, keine
--     Uebertragung an andere Spieler.
--     Zwei Quellen, beide beliebig lang:
--       * eigene Dateien im Executor-Ordner "utg_sounds"
--         (mp3/ogg/wav/flac, eingebunden ueber getcustomasset)
--       * Roblox-Asset-IDs, eine je Zeile in "utg_sounds.txt"
--     Gewaehlt wird zufaellig; Nachladen ueber den Schalter in der GUI.
------------------------------------------------------------------
local SoundService = game:GetService("SoundService")

-- MITGELIEFERTE SOUNDS. Damit das Feature ohne eine einzige eigene Datei
-- laeuft — und bei jedem anderen Spieler genauso, der das Skript per
-- loadstring laedt. Es sind Assets, die DIESES SPIEL selbst benutzt: sie
-- liegen bei jedem im Cache, laden sofort und koennen nicht verschwinden.
-- Ausgesucht nach kurz und knackig (0.2 bis 2.1 s), passend zu einer
-- gelungenen Finte.
local SOUND_DEFAULTS = {
    { 9113631914,      "NoTagBackBreak" },   -- 0.8 s, der Knochenbrecher
    { 5148302439,      "bonk" },             -- 0.4 s
    { 87343799036402,  "TrickBoom" },        -- 2.1 s
    { 6161421479,      "Woohoo" },           -- 1.0 s
    { 8255306220,      "crit" },             -- 1.4 s
    { 3779096010,      "buda" },             -- 0.2 s
    { 140481958643535, "YellowFlash" },      -- 0.4 s
    { 6655708496,      "win2" },             -- 1.1 s
    { 3779053277,      "zoom" },             -- 0.9 s
    { 5077617448,      "waaoom" },           -- 1.6 s
    { 7274429332,      "Fatality" },         -- 2.1 s
    { 138251332,       "Pichuun" },          -- 1.4 s
}

-- GETEILTE LISTE AUF GITHUB. Dort kann jeder mit Schreibrecht Links oder
-- IDs eintragen — einmal ins Repo geschrieben, haben es alle. Wird bei
-- jedem Start geholt; faellt GitHub aus, laeuft alles Uebrige weiter.
-- Ueber die GitHub-API statt ueber raw.githubusercontent.com: der raw-CDN
-- haelt den alten Inhalt bis zu fuenf Minuten fest, und ein angehaengter
-- Zeitstempel hilft dort nicht (gemessen: Repo laengst geaendert, raw lieferte
-- weiter die alte Liste). Die API antwortet sofort mit dem aktuellen Stand.
local SOUND_API =
    "https://api.github.com/repos/filipmijo2/utg-tag-assist/contents/sounds.txt"
local SOUND_URL =
    "https://raw.githubusercontent.com/filipmijo2/utg-tag-assist/main/sounds.txt"

local SND = { list = {}, folder = "utg_sounds", idFile = "utg_sounds.txt",
              holder = nil, lastName = nil, webIds = nil, webAt = 0 }

-- Aus einer Zeile die Asset-Nummer ziehen — egal ob nackte Zahl,
-- rbxassetid://, roblox.com/library/... oder create.roblox.com/store/asset/...
local function soundIdFromLine(line)
    if line:match("^%s*#") or line:match("^%s*//") or line:match("^%s*%-%-") then
        return nil
    end
    -- laengste Ziffernfolge nehmen: in Links steht die ID, danach kommt oft
    -- noch ein Name mit Zahlen darin
    local best
    for num in line:gmatch("%d+") do
        if #num >= 6 and (not best or #num > #best) then best = num end
    end
    return best
end

-- Liste von GitHub holen (gecacht, damit nicht jede Neuladung ins Netz geht)
local function fetchWebSounds(force)
    if SND.webIds and not force and tick() - SND.webAt < 300 then
        return SND.webIds
    end
    local ok, body = pcall(function()
        -- 1. Wahl: API mit Header, liefert immer den aktuellen Stand
        local req = request or http_request
        if type(req) == "function" then
            local r = req({
                Url = SOUND_API,
                Method = "GET",
                Headers = {
                    ["Accept"] = "application/vnd.github.raw",
                    ["Cache-Control"] = "no-cache",
                },
            })
            if r and tonumber(r.StatusCode) == 200 and type(r.Body) == "string" then
                return r.Body
            end
        end
        -- Rueckfall: roher Dateiabruf (kann bis zu fuenf Minuten alt sein)
        return game:HttpGet(SOUND_URL .. "?t=" .. tostring(os.time()), true)
    end)
    if not ok or type(body) ~= "string" or #body < 5 then
        LOG("Geteilte Soundliste nicht erreichbar — nur lokale Quellen")
        SND.webIds, SND.webAt = SND.webIds or {}, tick()
        return SND.webIds
    end
    local ids = {}
    for _, line in ipairs(string.split(body, "\n")) do
        local id = soundIdFromLine(line)
        if id then
            local name = line:match("%d+%s+(.+)$")
            ids[#ids + 1] = { id = id, name = name and name:sub(1, 24) or id }
        end
    end
    SND.webIds, SND.webAt = ids, tick()
    return ids
end
ENV.fetchWebSounds = fetchWebSounds

local function sndHolder()
    if SND.holder and SND.holder.Parent then return SND.holder end
    local f = Instance.new("Folder")
    f.Name = "UTG_JukeSounds"
    f.Parent = SoundService
    SND.holder = f
    return f
end

-- Liest beide Quellen neu ein und legt je Eintrag eine Sound-Instanz an.
-- Rueckgabe: Anzahl, Anzahl Dateien, Anzahl IDs.
-- Die Roblox-Gesamtlautstaerke zieht unseren Sound mit herunter. Steht sie
-- zum Beispiel auf 20 Prozent (gemessen genau das), kommt von einem Sound
-- mit Volume 0.8 effektiv nur 0.16 an — man hoert schlicht nichts. Roblox
-- laesst Volume bis 10 zu, also wird gegengerechnet: die Finte soll
-- unabhaengig vom Regler des Spiels gleich laut sein.
local function jukeVolume()
    local want = CFG.jukeSoundVol or 1.6
    local master = 1
    pcall(function()
        master = UserSettings():GetService("UserGameSettings").MasterVolume or 1
    end)
    if master < 0.02 then master = 0.02 end
    -- Deckel auf 10, dem Hoechstwert von Roblox: bei einer
    -- Gesamtlautstaerke von 20 Prozent braucht es den auch.
    return math.clamp(want / master, want, 10)
end
ENV.jukeVolume = jukeVolume

-- Billiger Fingerabdruck der beiden Quellen: Anzahl Dateien plus Laenge der
-- ID-Datei. Aendert er sich, wird neu eingelesen — so genuegt es, eine Datei
-- in den Ordner zu legen, ohne irgendetwas umzuschalten.
local function sndFingerprint()
    local n = 0
    if type(isfolder) == "function" and type(listfiles) == "function"
       and isfolder(SND.folder) then
        local ok, files = pcall(listfiles, SND.folder)
        if ok and type(files) == "table" then n = #files end
    end
    local idLen = 0
    if type(isfile) == "function" and isfile(SND.idFile) then
        local ok, txt = pcall(readfile, SND.idFile)
        if ok and type(txt) == "string" then idLen = #txt end
    end
    return n .. ":" .. idLen
end

function ENV.reloadSounds()
    if SND.holder then pcall(function() SND.holder:Destroy() end) end
    SND.holder, SND.list = nil, {}
    local entries, nFile, nId = {}, 0, 0

    if type(listfiles) == "function" and type(isfolder) == "function" then
        if not isfolder(SND.folder) and type(makefolder) == "function" then
            pcall(makefolder, SND.folder)
        end
        if isfolder(SND.folder) then
            local okL, files = pcall(listfiles, SND.folder)
            if okL and type(files) == "table" then
                for _, path in ipairs(files) do
                    local low = tostring(path):lower()
                    if low:sub(-4) == ".mp3" or low:sub(-4) == ".ogg"
                       or low:sub(-4) == ".wav" or low:sub(-5) == ".flac" then
                        local grab = getcustomasset or getsynasset
                        local okA, id = pcall(grab, path)
                        if okA and type(id) == "string" then
                            entries[#entries+1] =
                                { id = id, name = tostring(path):match("[^\\/]+$") or "Datei" }
                            nFile = nFile + 1
                        end
                    end
                end
            end
        end
    end

    if type(isfile) == "function" and type(readfile) == "function"
       and isfile(SND.idFile) then
        local okR, txt = pcall(readfile, SND.idFile)
        if okR and type(txt) == "string" then
            for line in txt:gmatch("[^\r\n]+") do
                if not line:match("^%s*//") and not line:match("^%s*%-%-") then
                    local num = line:match("(%d+)")
                    if num then
                        entries[#entries+1] =
                            { id = "rbxassetid://" .. num, name = num }
                        nId = nId + 1
                    end
                end
            end
        end
    end

    -- RANGFOLGE STATT MISCHEN. Es gewinnt die erste Quelle, die etwas
    -- liefert — und das sind die EIGENEN DATEIEN im Ordner utg_sounds.
    -- Grund: dieselben Dateien gehen auch in den Voicechat. Nur so hoeren
    -- alle dasselbe; eine Roblox-Asset-ID kann das Begleitprogramm nicht
    -- abspielen, die kennt nur Roblox.
    --   1. eigene Dateien im Ordner   (gilt auch im Voicechat)
    --   2. geteilte Liste auf GitHub  (nur im Spiel hoerbar)
    --   3. die mitgelieferten Spiel-Sounds als Rueckfall
    local web = (#entries == 0) and fetchWebSounds(false) or {}
    local nWeb, nDef = 0, 0
    if #entries > 0 then
        -- Dateien gefunden: dabei bleibt es
    elseif #web > 0 then
        for _, e in ipairs(web) do
            entries[#entries + 1] = { id = "rbxassetid://" .. e.id, name = e.name }
            nWeb = nWeb + 1
        end
    elseif #entries == 0 then
        for _, d in ipairs(SOUND_DEFAULTS) do
            entries[#entries + 1] = { id = "rbxassetid://" .. d[1], name = d[2] }
            nDef = nDef + 1
        end
    end

    SND.fp = sndFingerprint()
    local holder = sndHolder()
    for _, e in ipairs(entries) do
        local ok = pcall(function()
            local s = Instance.new("Sound")
            s.Name = e.name
            s.SoundId = e.id
            s.Volume = jukeVolume()
            s.Parent = holder
            SND.list[#SND.list+1] = s
        end)
        if not ok then nFile = nFile end
    end
    return #SND.list, nFile, nId, nDef, nWeb
end

-- AUSLOESER FUER DEN VOICECHAT.
-- Roblox uebertraegt im VC nur das Mikrofon; ein Sound, den das Spiel selbst
-- abspielt, bleibt immer lokal — daran laesst sich von innen nichts aendern.
-- Deshalb schreibt das Skript hier nur ein Signal in eine Datei. Das
-- Begleitprogramm utg_vc_player.py liest es und spielt eine Audiodatei auf
-- das virtuelle Mikrofon (Voicemeeter / VB-CABLE), das Roblox als Eingang
-- benutzt. Erst dadurch hoeren andere Spieler etwas.
local VC_TRIGGER, VC_ALIVE = "utg_vc_play.txt", "utg_vc_alive.txt"
local vcCount = 0
local function vcTrigger()
    if type(writefile) ~= "function" then return end
    vcCount = vcCount + 1
    pcall(writefile, VC_TRIGGER, tostring(vcCount) .. " " .. tostring(os.time()))
end

-- Laeuft das Begleitprogramm? Es schreibt jede Sekunde einen Zeitstempel.
function ENV.vcAlive()
    if type(isfile) ~= "function" or not isfile(VC_ALIVE) then return false end
    local ok, txt = pcall(readfile, VC_ALIVE)
    if not ok then return false end
    local t = tonumber((tostring(txt):match("%d+")))
    return t ~= nil and math.abs(os.time() - t) < 8
end

-- Laenger als das soll keine Finte nachhallen: ein Sound, der vier Sekunden
-- laeuft, steht noch im Raum, wenn die naechste Finte kommt.
local JUKE_SOUND_MAX = 2.0

local function playJukeSound()
    if #SND.list == 0 then return end
    local s = SND.list[math.random(1, #SND.list)]
    if not s or not s.Parent then return end
    -- SELBST MITHOEREN ist ein eigener Schalter: wer den Sound nur nach
    -- draussen schicken will, soll ihn sich nicht selbst ins Ohr setzen —
    -- und umgekehrt.
    if CFG.jukeSoundSelf then
        pcall(function()
            s.Volume = jukeVolume()
            s.TimePosition = 0
            s:Play()
        end)
        -- nach zwei Sekunden hart abschneiden, egal wie lang die Datei ist
        task.delay(JUKE_SOUND_MAX, function()
            if s and s.Parent and s.IsPlaying then pcall(function() s:Stop() end) end
        end)
    end
    SND.lastName = s.Name
    -- und nach draussen: das Begleitprogramm spielt dieselbe Gelegenheit
    -- auf das virtuelle Mikrofon, damit die anderen es auch hoeren
    if CFG.jukeSoundVC then vcTrigger() end
end
ENV.playJukeSound = playJukeSound     -- zum Ausprobieren der Lautstaerke

-- Probe aufs Exempel: spielt einen Sound und misst, ob wirklich Ton
-- herauskommt. Damit laesst sich "ich hoere nichts" von "es wurde gar nicht
-- ausgeloest" unterscheiden.
function ENV.testSound()
    if #SND.list == 0 then ENV.reloadSounds() end
    if #SND.list == 0 then return "keine Sounds geladen" end
    playJukeSound()
    local loud = 0
    for i = 1, 24 do
        task.wait(0.05)
        for _, s in ipairs(SND.list) do
            if s.PlaybackLoudness > loud then loud = s.PlaybackLoudness end
        end
    end
    local master = 1
    pcall(function()
        master = UserSettings():GetService("UserGameSettings").MasterVolume or 1
    end)
    return ("%d Sounds, gespielt: %s | Roblox-Gesamtlautstaerke %.0f%%, "
            .. "Sound-Volume dagegen %.1f | lauteste Stelle %.0f — %s")
        :format(#SND.list, tostring(SND.lastName), master * 100, jukeVolume(), loud,
                loud > 0 and "hoerbar" or "STUMM")
end

-- Ein Manoever beenden und zur Wirkungsmessung anmelden.
local function endJuke(a, now, why)
    -- Ein Manoever, das an einer Wand abgebrochen ist, hat gar nicht
    -- stattgefunden — es mit dem vollen Cooldown von 5 bis 8 Sekunden zu
    -- sperren, verschenkt das halbe Repertoire. Gemessen kamen auf 15
    -- gestartete Finten 19 solcher Abbrueche. Kurze Sperre statt langer.
    if why == "wallAborts" or why == "edgeAborts" then
        JUKE.cd[a.def.name] = now - math.max((a.def.cd or 5) - 1.5, 0)
    else
        JUKE.cd[a.def.name] = now
    end
    JUKE.lastAny = now
    if why then JUKE[why] = (JUKE[why] or 0) + 1 end
    -- Erst 1.2 s NACH dem Ende messen: der Verfolger braucht einen Moment,
    -- um auf den Haken zu reagieren, und genau das soll gemessen werden.
    if a.d0 then
        JUKE.pending = { name = a.def.name, d0 = a.d0, at = now + 1.2,
                         cut = (why ~= nil) }
    end

    -- SOUND NACH DER FINTE. Nur, wenn das Manoever wirklich gelaufen ist —
    -- ein an der Wand abgebrochener Versuch ist keine Finte. Und nur, wenn
    -- sie aufgegangen ist: wer getaggt wird, wechselt in diesem Spiel die
    -- Rolle, und in den Modi mit Einfrieren steht er danach fest.
    local ran = (why == nil) or (now - a.t0 >= 0.6)
    if CFG.jukeSound and ran and #SND.list > 0 then
        local roleAt, name = myRole(), a.def.name
        -- 0.05 s: praktisch auf dem Haken. Zum Pruefen, ob die Finte
        -- aufging, reicht das noch — ein Tag schlaegt sofort auf die Rolle
        -- durch, da liegen keine 50 Millisekunden dazwischen.
        task.delay(0.05, function()
            if not CFG.jukeSound then return end
            if myRole() ~= roleAt then return end      -- getaggt
            if AP.immobile then return end             -- gefangen/eingefroren
            playJukeSound()
            LOG(("Finten-Sound nach %s: %s"):format(name, tostring(SND.lastName)))
        end)
    end

    JUKE.active, AP.jukeName = nil, nil
end

local function jukeStep(pos, facing, toThreat, threatD, level)
    local now = tick()
    local ctx = { pos = pos, facing = facing, toThreat = toThreat,
                  threatD = threatD, level = level }
    local dOK = threatD and threatD < 400

    -- WIRKUNGSMESSUNG. Ein Manoever ist nur dann gut, wenn danach mehr
    -- Abstand da ist als ohne — deshalb wird beides gemessen: der Gewinn
    -- nach jeder Finte und, als Vergleich, derselbe Zeitraum im normalen
    -- Weglaufen.
    local pend = JUKE.pending
    if pend then
        if dOK and now >= pend.at then
            local gain = threatD - pend.d0
            local s = JUKE.stat[pend.name]
                      or { n = 0, sum = 0, best = -99, worst = 99 }
            s.n, s.sum = s.n + 1, s.sum + gain
            if gain > s.best then s.best = gain end
            if gain < s.worst then s.worst = gain end
            JUKE.stat[pend.name] = s
            LOG(("Finte %s%s: Abstand %.1f -> %.1f (%+.1f), Schnitt %+.1f aus %d")
                :format(pend.name, pend.cut and " (abgebrochen)" or "",
                        pend.d0, threatD, gain, s.sum / s.n, s.n))
            JUKE.pending = nil
            -- Alle zehn Messungen die Rangliste ins Log: so sammelt sich
            -- ueber echte Spielzeit eine belastbare Aussage darueber, welches
            -- Manoever wirklich Abstand bringt.
            JUKE.since = (JUKE.since or 0) + 1
            if JUKE.since >= 10 then
                JUKE.since = 0
                LOG("--- Wirkung der Finten ---\n" .. ENV.jukeReport())
            end
        elseif now > pend.at + 2.5 then
            JUKE.pending = nil          -- Verfolger weg, nicht auswertbar
        end
    elseif dOK and not JUKE.active then
        -- Vergleichswert: Abstandsaenderung ueber dieselben 1.2 s ohne Finte
        local b = JUKE.baseRef
        if b and now - b.t >= 1.2 then
            JUKE.base.n = JUKE.base.n + 1
            JUKE.base.sum = JUKE.base.sum + (threatD - b.d)
            b = nil
        end
        if not b then JUKE.baseRef = { t = now, d = threatD } end
    end

    local a = JUKE.active
    if a then
        -- MOMENTUM-WACHE. Das Spiel setzt Momentum auf 0, sobald die
        -- Seitgeschwindigkeit unter 6.8 faellt — wer bei einem Manoever
        -- stehenbleibt, wird gefangen. Bricht das Tempo zu stark ein, wird
        -- das Manoever sofort abgebrochen statt zu Ende gefahren.
        local hrpJ = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
        local sp = hrpJ and (hrpJ.AssemblyLinearVelocity * Vector3.new(1, 0, 1)).Magnitude or 99
        a.slow = (sp < 9) and ((a.slow or 0) + 1) or 0
        if a.slow > 12 then          -- rund 0.2 s dauerhaft zu langsam
            endJuke(a, now, "aborted")
            return nil
        end
        local dir = a.def.run(ctx, a, now - a.t0)
        if dir then
            -- Keine Finte in eine Wand: das kostet das gesamte Tempo und
            -- bringt nichts. Ist die Richtung zu, wird abgebrochen statt
            -- dagegenzulaufen.
            -- Ausgenommen sind Kreise: wer sich 270 bis 450 Grad dreht,
            -- zeigt zwangslaeufig zwischendurch auf eine Wand, ohne je
            -- hineinzulaufen. Dort zaehlt allein die Zielrichtung, die
            -- beim Start geprueft wird.
            if not a.def.skipWall and rayClear(pos, dir, 2.4, 9) < 0.7 then
                endJuke(a, now, "wallAborts")
                return nil
            end
            -- ABBRUCH AN DER KANTE. Ein Manoever, das ueber eine Kante
            -- fuehrt, endet im Sturz — und ein Sturz kostet mehr, als jede
            -- Finte je bringt. Geprueft wird der Boden dort, wo er in einer
            -- Viertelsekunde waere.
            if not a.def.mapMove then
                local ahead = pos + dir * 9
                local g = workspace:Raycast(ahead + Vector3.new(0, 2, 0),
                                            Vector3.new(0, -14, 0), AP.rp)
                if not g then
                    endJuke(a, now, "edgeAborts")
                    return nil
                end
            end
            AP.jukeName = a.def.name
            return dir
        end
        endJuke(a, now, nil)
        return nil
    end

    if level < 1 or not toThreat then return nil end
    if now - JUKE.lastAny < jukeGap(level) then return nil end
    -- Nur in spuerbarer Naehe finten. Weiter weg sieht es niemand, kostet
    -- aber Strecke - und der Verfolger hat Zeit, die Abkuerzung zu nehmen.
    if threatD > 30 then return nil end
    -- Und nur vom BODEN aus starten: in der Luft laesst sich die Richtung
    -- kaum aendern, das Manoever verpufft dann wirkungslos. Die Spruenge
    -- innerhalb von bamboozle und stairJuke sind davon unberuehrt, weil
    -- nur der START geprueft wird.
    local humJ = LP.Character and LP.Character:FindFirstChildOfClass("Humanoid")
    if not humJ or humJ.FloorMaterial == Enum.Material.Air then return nil end

    -- ZEIT BIS ZUM KONTAKT statt blosser Entfernung. Ein Verfolger 25 Studs
    -- hinter einem, der keinen Meter gutmacht, ist keine Lage fuer eine
    -- Finte — sie kostet dann nur Strecke. Einer, der mit sechs Studs pro
    -- Sekunde aufholt, ist in vier Sekunden da. Gefintet wird, wenn er
    -- wirklich naeher kommt oder schon dicht dran ist.
    local closing = 0
    if JUKE.lastD and JUKE.lastDt and now - JUKE.lastDt > 0.08 then
        closing = (JUKE.lastD - threatD) / (now - JUKE.lastDt)
    end
    if not JUKE.lastDt or now - JUKE.lastDt > 0.08 then
        JUKE.lastD, JUKE.lastDt = threatD, now
    end
    -- Ausgespart wird nur noch der eindeutige Fall: er faellt deutlich
    -- zurueck UND ist weit weg. Alles andere ist eine Lage fuer eine Finte.
    -- Eine schaerfere Regel (Zeit bis Kontakt ueber 4.5 s = keine Finte) hat
    -- das Repertoire zu oft stillgelegt; die Manoever sollen vorkommen.
    if closing < -3 and threatD > 22 then return nil end

    local pool = {}
    for _, def in ipairs(JUKE_MOVES) do
        if level >= def.minLevel and threatD <= def.maxD
           and threatD >= (def.minD or 0)
           and now - (JUKE.cd[def.name] or -99) >= def.cd
           and ((not def.ready) or def.ready(ctx)) then
            pool[#pool + 1] = def
        end
    end
    if #pool == 0 then return nil end

    -- Gewichtete Auswahl statt reinem Zufall, aus drei Teilen:
    --  1. Gelegenheit: die mapbezogenen Manoever brauchen eine passende
    --     Stelle, und die ist selten (gemessen: Kante voraus in 1.2 % der
    --     Frames). Bei Gleichverteilung faellt so eine Gelegenheit fast
    --     immer durch, also zaehlen sie mehr, wenn sie moeglich sind.
    --  2. Lage: steht der Verfolger direkt im Ruecken, wirken Kehren; kommt
    --     er von der Seite, wirkt der Bogen, weil er aussen vorbeilaeuft.
    --  3. Erfahrung: was in dieser Runde Abstand gebracht hat, wird
    --     haeufiger genommen — was Abstand gekostet hat, seltener. Ein
    --     Mindestgewicht bleibt immer, sonst probiert er nie wieder etwas.
    local behind = 0        -- 1 = genau im Ruecken, 0 = quer daneben
    if toThreat and facing then
        behind = math.clamp(-toThreat:Dot(facing), 0, 1)
    end
    local total = 0
    for _, def in ipairs(pool) do
        local w = def.mapMove and 6 or 1
        -- WICHTIG: die folgenden Faktoren duerfen ein Manoever nur
        -- BEVORZUGEN, niemals praktisch abschalten. Mit den frueheren
        -- Spannen (0.45 bis 1.55 nach Lage, 0.25 bis 2.2 nach Erfahrung)
        -- kamen schwach gemessene Manoever kaum noch vor — das Repertoire
        -- schrumpfte faktisch auf zwei, drei Bewegungen. Jede Finte soll
        -- weiter regelmaessig vorkommen, die Gewichtung gibt nur den
        -- Ausschlag bei sonst gleicher Lage.
        if def.turnBack then
            -- Kehre: passt besser gegen jemanden im Ruecken
            w = w * (0.8 + 0.4 * behind)
        elseif def.arc then
            -- Bogen: passt besser gegen jemanden, der seitlich schneidet
            w = w * (0.8 + 0.4 * (1 - behind))
        end
        local s = JUKE.stat[def.name]
        if s and s.n >= 2 then
            -- Schrumpfung gegen Zufallstreffer, und eine enge Spanne:
            -- hoechstens ein Drittel mehr oder weniger
            local avg = (s.sum / s.n) * (s.n / (s.n + 2))
            w = w * math.clamp(1 + avg / 24, 0.7, 1.35)
        end
        def.__w = math.max(w, 0.35)
        total = total + def.__w
    end
    -- Startrichtung pruefen — und bei einer Wand NICHT gleich aufgeben.
    -- Fast jedes Manoever hat eine zufaellige Seite; ist die eine zu, ist die
    -- andere meist frei. Erst wenn beide Seiten scheitern, wird das naechste
    -- Manoever aus dem Topf probiert. Gemessen war das der groesste Verlust
    -- im ganzen Repertoire.
    local function startDir(def, m)
        -- Beim Kreis zaehlt die Richtung, in der er ENDET, nicht die, mit
        -- der er beginnt
        local first = def.run(ctx, m, 0)
        if def.skipWall and m.total and m.s then
            first = turn(ctx.facing, m.s * m.total)
        end
        return first
    end
    local function usable(def, first)
        if not first then return true end
        if rayClear(pos, first, 2.4, 9) < 0.7 then return false, "wallAborts" end
        -- nicht ueber eine Kante starten: ohne Boden endet die Finte im
        -- Sturz. Die mapbezogenen Manoever sind ausgenommen, die SUCHEN Kanten.
        if not def.mapMove then
            local ahead = pos + first * 10
            if not workspace:Raycast(ahead + Vector3.new(0, 2, 0),
                                     Vector3.new(0, -14, 0), AP.rp) then
                return false, "edgeAborts"
            end
        end
        return true
    end

    local skip = {}
    for attempt = 1, 3 do
        local avail = 0
        for _, d in ipairs(pool) do if not skip[d] then avail = avail + d.__w end end
        if avail <= 0 then break end
        local roll, def = math.random() * avail, nil
        for _, d in ipairs(pool) do
            if not skip[d] then
                roll = roll - d.__w
                if roll <= 0 then def = d break end
            end
        end
        if not def then break end

        local m = { def = def, t0 = now, d0 = threatD }
        if def.init then def.init(ctx, m) end
        local first = startDir(def, m)
        local ok, why = usable(def, first)
        if not ok and m.s and not def.noMirror then
            -- andere Seite versuchen, bevor das Manoever verworfen wird.
            -- Nicht bei cornerLoop: dessen Seite ist die FREIE Seite der
            -- gefundenen Ecke, gespiegelt zeigt sie ins Hindernis.
            m.s = -m.s
            first = startDir(def, m)
            ok, why = usable(def, first)
        end
        if ok then
            JUKE.active = m
            JUKE.count = JUKE.count + 1
            JUKE.log[def.name] = (JUKE.log[def.name] or 0) + 1
            AP.jukeName = def.name
            return first or facing
        end
        skip[def] = true
        JUKE[why] = (JUKE[why] or 0) + 1
        -- kurze Sperre, nicht der volle Cooldown: gelaufen ist es ja nicht
        JUKE.cd[def.name] = now - math.max((def.cd or 5) - 1.5, 0)
    end
    return nil
end
local function autopilotStep(threat, threatD, prey, preyD)
    refreshRaycastFilter()      -- Filter aktuell halten, bevor irgendwer strahlt
    local p = P()
    local char = LP.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    local vals = char and char:FindFirstChild("values")
    local camY = vals and vals:FindFirstChild("CameraY")
    if not (CFG.autopilot and hrp and camY) then AP.mode, AP.vec = nil, nil return end

    hookControlModule()

    -- Position frueh holen: die Bewegungsunfaehigkeits-Erkennung unten misst
    -- die eigene Verschiebung und braucht sie schon dort. Vorher stand die
    -- Definition erst hinter dieser Pruefung, "pos" war dort also ein
    -- globaler nil-Wert — AP.immPos wurde damit nie gesetzt und der
    -- Freeze-/Kaefig-Fall nie erkannt.
    local pos = hrp.Position

    -- Bin ich selbst bewegungsunfaehig (Freeze-Modus, Kaefig, Anchor)? Dann
    -- ist jede Steuerung sinnlos — das Spiel verankert den Charakter, und der
    -- Autopilot wuerde nur gegen die Verankerung anrennen.
    -- Erkennung ueber drei Wege, weil das Attribut nicht zuverlaessig gesetzt
    -- wird: Attribut, Rollenname (Frozen/Caged...) und – am verlaesslichsten –
    -- die tatsaechlich gemessene Eigenbewegung trotz Steuerbefehl.
    local roleName = tostring(state.role or "")
    local roleFrozen = roleName:find("Frozen") ~= nil or roleName:find("Caged") ~= nil
    local nowI = tick()
    -- Diese Messung hat frueher nie angeschlagen (sie las ein "pos", das an
    -- der Stelle noch gar nicht existierte). Seit das behoben ist, muss sie
    -- eng gefasst werden, sonst gilt jedes normale Haengenbleiben als
    -- Bewegungsunfaehigkeit und der Autopilot pausiert sich selbst aus einer
    -- Lage heraus, aus der er sich gerade befreien sollte.
    -- Ein echter Freeze/Kaefig verankert den Charakter: die Geschwindigkeit
    -- ist praktisch null. Wer an einer Wand haengt oder an einer Leiter
    -- klettert, hat dagegen Restbewegung — und Klettern ist ohnehin langsam.
    local humI = char:FindFirstChildOfClass("Humanoid")
    local hrpI = char:FindFirstChild("HumanoidRootPart")
    local velI = hrpI and hrpI.AssemblyLinearVelocity.Magnitude or 99
    local climbingI = humI and humI:GetState() == Enum.HumanoidStateType.Climbing
    if AP.vec and AP.vec.Magnitude > 0.1 and not climbingI and velI < 1.0 then
        local moved = AP.immPos and (pos - AP.immPos).Magnitude or 99
        if not AP.immAt or nowI - AP.immAt > 0.5 then
            AP.immStuck = (moved < 1.5) and ((AP.immStuck or 0) + 1) or 0
            AP.immAt, AP.immPos = nowI, pos
        end
    else
        AP.immStuck, AP.immPos, AP.immAt = 0, pos, nowI
    end
    local immobile = roleFrozen or (AP.immStuck or 0) >= 5

    if immobile or char:GetAttribute("Frozen") or char:GetAttribute("Caged")
       or char:GetAttribute("Anchor") or (RENV.shared.multipliers or {}).Anchored then
        AP.mode, AP.vec, AP.move = nil, nil, nil
        AP.immobile = true
        if not AP.frozenLogged then
            AP.frozenLogged = true
            LOG("selbst bewegungsunfaehig (" .. roleName .. ") — Autopilot und Auto-Tag pausiert")
        end
        return
    end
    AP.frozenLogged = false
    AP.immobile = false

    -- FESTHAENGEN AN DER LEITER. Klettern ohne Hoehengewinn heisst, dass der
    -- Charakter am Truss klebt, ohne hochzukommen (beobachtet: Zustand
    -- Climbing, Position minutenlang unveraendert). Ein Sprung ist an der
    -- Leiter das Loslassen — danach kurz keine Leiter mehr ansteuern, sonst
    -- greift er im naechsten Frame wieder zu.
    if humI and humI:GetState() == Enum.HumanoidStateType.Climbing then
        if not AP.climbY or math.abs(pos.Y - AP.climbY) > 1.0 then
            AP.climbY, AP.climbYAt = pos.Y, nowI
        elseif nowI - (AP.climbYAt or nowI) > 1.5 then
            AP.climbY, AP.climbYAt = pos.Y, nowI
            tryJump(true)
            AP.noClimbUntil = nowI + 1.5
            failNote("leiter_haengt", "1.5 s an der Leiter ohne Hoehengewinn — losgelassen")
        end
    else
        AP.climbY, AP.climbYAt = nil, nil
    end

    local goal, mode

    -- Klettertest/erzwungenes Klettern laeuft unabhaengig von Runde und Ziel
    if AP.forceClimbUntil and tick() < AP.forceClimbUntil then
        local cdir = climbStep(pos, AP.lastDir)
        if cdir then
            local rel = camY.Value:VectorToObjectSpace(cdir)
            rel = Vector3.new(rel.X, 0, rel.Z)
            if rel.Magnitude > 0.05 then
                -- auch hier die Weltrichtung mitfuehren, sonst rechnet der
                -- Move-Hook mit einer veralteten und die Kamera verbiegt
                -- den Kurs
                AP.vec, AP.vecWorld, AP.mode = rel.Unit, cdir.Unit, "KLETTERN"
                AP.vecAt = tick()
                return
            end
        end
    end

    -- PRIORITAET: Taggen schlaegt Nicht-getaggt-werden. Gibt es ein taggbares
    -- Ziel, wird gejagt — quer ueber die ganze Karte und auch dann, wenn
    -- Jaeger unterwegs sind (in vielen Modi taggt man sich gegenseitig).
    -- Die Flucht unterbricht nur, wenn einer wirklich im Nacken sitzt UND
    -- naeher ist als das eigene Ziel.
    -- Reine Beute (Crown im Crown-Modus, Runner in Classic ...): es gibt nichts
    -- zu taggen, also wird durchgehend Abstand gehalten und vorausschauend zu
    -- sicheren Punkten gelaufen — nicht erst, wenn jemand nah ist.
    local purePrey = (state.nPrey or 0) == 0 and (state.nThreat or 0) > 0
    local huntable = prey and preyD
    -- Fuer Panik/Flucht zaehlt nur, wer sich auch bewegen kann
    local mobileThreatD
    for _, t in ipairs(state.threats or {}) do
        if t.mobile and (not mobileThreatD or t.d < mobileThreatD) then mobileThreatD = t.d end
    end
    -- Notnagel: erkennt die Messung (noch) niemanden als beweglich, gilt der
    -- naechste Verfolger trotzdem als Gefahr. Lieber einmal zu viel fliehen.
    if not mobileThreatD then mobileThreatD = threatD end
    state.mobileThreatD = mobileThreatD
    -- Ein unbewegliches Ziel (Frozen zum Auftauen) laeuft nicht weg — dafuer
    -- lohnt es nicht, sich einen Jaeger einzufangen. Also grosszuegiger
    -- ausweichen, bevor man es holt.
    local preyStill = false
    if prey then
        local prh = hrpOf(prey)
        if prh then preyStill = speedOf(prey, prh) <= 4 end
    end
    local panicR = (p.panicR or 14) * (preyStill and 1.9 or 1)
    -- Flucht geht vor Jagd, wenn der Verfolger naeher ist als das eigene Ziel.
    -- Vorher galt das nur innerhalb des kleinen Panik-Radius — dadurch ist er
    -- weiter hinter jemandem hergelaufen, waehrend ihn selbst jemand einholte.
    local panic = mobileThreatD and (
        mobileThreatD <= panicR
        or (preyD and mobileThreatD < preyD and mobileThreatD < 38)
    )

    if huntable and not panic then
        local pr = hrpOf(prey)
        if pr then
            goal = (pr.Position - pos) * Vector3.new(1, 0, 1)
            if goal.Magnitude > 0.01 then goal = goal.Unit end
            mode = "JAGD"
            AP.preyPos = pr.Position

            -- kein Fortschritt trotz Verfolgung? Dann ist das Ziel gerade
            -- nicht erreichbar (Dach, andere Ebene) — kurz ignorieren.
            local nowP = tick()
            local vGap = pr.Position.Y - pos.Y
            if AP.chaseTarget ~= prey then
                AP.chaseTarget, AP.chaseSince, AP.chaseBestD = prey, nowP, preyD
            else
                if preyD < (AP.chaseBestD or preyD) - 3 then
                    AP.chaseBestD, AP.chaseSince = preyD, nowP
                elseif nowP - (AP.chaseSince or nowP) > 6 and math.abs(vGap) > 15 then
                    state.skipPrey = state.skipPrey or {}
                    state.skipPrey[prey] = nowP + 10
                    LOG(("Ziel %s unerreichbar (%.0f Studs Hoehenunterschied) — 10 s uebersprungen")
                        :format(prey.Name, vGap))
                    AP.chaseTarget = nil
                end
            end

            -- DUELL: Kann das Ziel mich ebenfalls taggen, wird nicht blind
            -- hineingerannt. Unsere Reichweite ist groesser als seine (7 Studs),
            -- also auf Kante bleiben: von aussen antippen statt in seine
            -- Reichweite zu laufen.
            local preyMobile = speedOf(prey, pr) > 4
            local mutual = preyMobile
                and canTag(prey.PlayerRole and prey.PlayerRole.Value or "", state.role or "")
            AP.duel = false
            if mutual then
                local edge = math.max(state.reach * 0.85, 8.5)
                if preyD < edge - 1.5 then
                    -- zu nah: auf Kante zurueckweichen (seitlich, nicht stumpf rueckwaerts)
                    local back = (pos - pr.Position) * Vector3.new(1, 0, 1)
                    if back.Magnitude > 0.1 then
                        local side = Vector3.new(-back.Unit.Z, 0, back.Unit.X)
                        goal = (back.Unit * 0.8 + side * 0.6)
                        if goal.Magnitude > 0.01 then goal = goal.Unit end
                    end
                    AP.duel = true
                elseif preyD < edge + 4 then
                    -- genau auf Kante halten: seitlich umkreisen statt annaehern
                    local toT = (pr.Position - pos) * Vector3.new(1, 0, 1)
                    if toT.Magnitude > 0.1 then
                        local side = Vector3.new(-toT.Unit.Z, 0, toT.Unit.X)
                        goal = (toT.Unit * 0.35 + side * 0.9)
                        if goal.Magnitude > 0.01 then goal = goal.Unit end
                    end
                    AP.duel = true
                end
            end

            -- nicht frontal in einen Jaeger hineinlaufen: leicht herumbogen
            local rep = Vector3.zero
            for _, t in ipairs(state.threats or {}) do
                local v = (pos - t.pos) * Vector3.new(1, 0, 1)
                local d = v.Magnitude
                if d > 0.5 and d < 22 then rep = rep + v.Unit * ((22 - d) / 22) end
            end
            if rep.Magnitude > 0.01 and not AP.duel then goal = goal + rep.Unit * 0.75 end
        end
    elseif threat and mobileThreatD and (mobileThreatD <= p.fleeR or purePrey) then
        -- Fluchtrichtung = Summe der Abstossung aller Verfolger (1/d^2),
        -- damit man nicht dem naechsten ausweicht und dem zweiten reinlaeuft
        local away = Vector3.zero
        for _, t in ipairs(state.threats or {}) do
            local v = (pos - t.pos) * Vector3.new(1, 0, 1)
            if v.Magnitude > 0.5 then
                local d = math.max(v.Magnitude, 3)
                away = away + v.Unit * (900 / (d * d)) * (t.mobile and 1 or 0.15)
            end
        end
        if away.Magnitude < 0.05 then
            local th = hrpOf(threat)
            away = th and ((pos - th.Position) * Vector3.new(1, 0, 1)) or Vector3.zero
        end
        if away.Magnitude > 0.05 then
            goal = away.Unit
            mode = "FLUCHT"

            -- In die Kartenmitte ziehen, sobald man in den Randbereich geraet:
            -- am Rand hat man kaum Fluchtwege und wird in die Ecke gedraengt.
            local c, r = playfield()
            if not c then c, r = mapCenterRadius() end
            if c then
                local toC = (c - pos) * Vector3.new(1, 0, 1)
                local dc = toC.Magnitude
                local edge = r * 0.45
                if dc > edge and toC.Magnitude > 0.05 then
                    -- je weiter draussen, desto mehr uebernimmt die Mitte.
                    -- Am Rand dominiert sie die Fluchtrichtung komplett —
                    -- in der Ecke wird man sonst zuverlaessig gestellt.
                    local pull = math.clamp((dc / edge - 1) * 2.0, 0, 4)
                    if AP.trapped then pull = pull + 1.5 end   -- aus der Ecke heraus
                    goal = goal + toC.Unit * pull * 2.5
                    if goal.Magnitude > 0.05 then goal = goal.Unit end
                    AP.centerPull = pull
                else
                    AP.centerPull = 0
                end
            end

            -- Zustandswerte fuer alle folgenden Manoever (muss VOR dem ersten
            -- Zugriff stehen — genau das war der Absturz im Frame-Schritt)
            local AKs = ankles()
            local nowS = tick()

            ------------------------------------------------------------------
            -- ROLL-CUT: waehrend einer laufenden Rolle die Richtung wechseln.
            -- Die Rolle traegt Momentum und der Move-Vektor wirkt weiter — der
            -- Verfolger ist auf die alte Linie festgelegt und laeuft vorbei.
            ------------------------------------------------------------------
            local rolling = RENV.shared.boosts and RENV.shared.boosts.Roll ~= nil
            if AKs.rollcut and rolling then
                if not AP.rollCutDir then
                    local sideR = Vector3.new(-goal.Z, 0, goal.X)
                        * ((math.random() < 0.5) and 1 or -1)
                    local cand = (goal * 0.25 + sideR * 1.1)
                    cand = cand * Vector3.new(1, 0, 1)
                    if cand.Magnitude > 0.05 and not movesTowardThreat(pos, cand.Unit) then
                        AP.rollCutDir = cand.Unit
                        AP.rollCutCount = (AP.rollCutCount or 0) + 1
                        AP.lastDir = nil            -- abrupt, nicht ausgefahren
                        LOG("Roll-Cut: Richtungswechsel in der Rolle")
                    end
                end
                if AP.rollCutDir then goal = AP.rollCutDir end
            else
                AP.rollCutDir = nil
            end

            ------------------------------------------------------------------
            -- CORNER-PEEL: dicht an einer Kante vorbei und direkt dahinter
            -- abbiegen. Bricht die Sichtlinie und der Verfolger schiesst vorbei.
            ------------------------------------------------------------------
            if AKs.cornerPeel and not AP.peelUntil and threatD < 32
               and nowS - (AP.peelAt or 0) > 5 then
                local wallA = workspace:Raycast(pos + Vector3.new(0, 2.4, 0), goal * 7, AP.rp)
                if wallA and math.abs(wallA.Normal.Y) < 0.3 then
                    local tanC = wallA.Normal:Cross(Vector3.new(0, 1, 0)) * Vector3.new(1, 0, 1)
                    if tanC.Magnitude > 0.05 then
                        tanC = tanC.Unit
                        for _, sgn in ipairs({ 1, -1 }) do
                            local along = tanC * sgn
                            -- hinter der Kante muss es offen sein
                            local past = pos + along * 9
                            local behind = workspace:Raycast(past + Vector3.new(0, 2.4, 0),
                                                             -wallA.Normal * 9, AP.rp)
                            if not behind and not movesTowardThreat(pos, along) then
                                AP.peelDir, AP.peelUntil, AP.peelAt = along, nowS + 1.1, nowS
                                AP.peelCount = (AP.peelCount or 0) + 1
                                LOG("Corner-Peel: um die Kante abgebogen")
                                break
                            end
                        end
                    end
                end
            end
            if AP.peelUntil then
                if nowS < AP.peelUntil and AP.peelDir then
                    goal = AP.peelDir
                else
                    AP.peelUntil, AP.peelDir = nil, nil
                end
            end

            ------------------------------------------------------------------
            -- HOCH HINAUS: erhoehte Flaeche in Fluchtrichtung ansteuern und
            -- im richtigen Moment draufspringen.
            ------------------------------------------------------------------
            local hiDir, hiSpot = findHighSpot(pos, goal)
            if hiDir and hiSpot and not movesTowardThreat(pos, hiDir) then
                local flat = (hiSpot - pos) * Vector3.new(1, 0, 1)
                local dFlat = flat.Magnitude
                goal = (goal * 0.35 + hiDir * 1.0)
                if goal.Magnitude > 0.05 then goal = goal.Unit end
                AP.seekingHigh = true
                -- kurz davor abspringen (Vault/Sprung traegt uns hoch)
                if dFlat < 5.5 and tick() - (AP.lastJump or 0) > 0.45 then
                    AP.lastJump = tick()
                    AP.highJumps = (AP.highJumps or 0) + 1
                    tryJump()
                end
            else
                AP.seekingHigh = false
            end

            ------------------------------------------------------------------
            -- SQUEEZE: eine Luecke suchen, die gerade breit genug fuer einen
            -- Charakter ist (ca. 2.5-5 Studs), und hindurch. Verfolger bleiben
            -- an solchen Stellen gern haengen.
            ------------------------------------------------------------------
            if AKs.squeeze and not AP.squeezeUntil and threatD < 40
               and nowS - (AP.squeezeAt or 0) > 3 then
                local bestGap, bestScore
                for i = 0, 35 do
                    local a = i * (math.pi * 2 / 36)
                    local d = Vector3.new(math.cos(a), 0, math.sin(a))
                    if d:Dot(goal) > 0.1 then                -- grob in Fluchtrichtung
                        local mid = rayClear(pos, d, 2.4, 11)
                        if mid > 0.6 then                     -- Durchgang frei
                            -- links und rechts daneben muss es dicht sein
                            local function side(deg)
                                local r = (CFrame.Angles(0, math.rad(deg), 0) * d)
                                r = r * Vector3.new(1, 0, 1)
                                return r.Magnitude > 0.05 and rayClear(pos, r.Unit, 2.4, 7) or 1
                            end
                            local l, r2 = side(25), side(-25)
                            if l < 0.7 and r2 < 0.7 then      -- beidseitig eng
                                local sc = mid + d:Dot(goal) - (l + r2)
                                if not bestScore or sc > bestScore then
                                    bestGap, bestScore = d, sc
                                end
                            end
                        end
                    end
                end
                if bestGap and not movesTowardThreat(pos, bestGap) then
                    AP.squeezeDir, AP.squeezeUntil, AP.squeezeAt = bestGap, nowS + 1.3, nowS
                    AP.squeezeCount = (AP.squeezeCount or 0) + 1
                    LOG("Squeeze: Luecke gefunden und durchgezogen")
                end
            end
            if AP.squeezeUntil then
                if nowS < AP.squeezeUntil and AP.squeezeDir then
                    goal = AP.squeezeDir
                else
                    AP.squeezeUntil, AP.squeezeDir = nil, nil
                end
            end

            ------------------------------------------------------------------
            -- BAMBOOZLE: auf eine Kante zuhalten, als ginge es runter — und
            -- direkt an der Kante kehrt machen. Wer hinterherhetzt, geht drueber.
            ------------------------------------------------------------------
            if AKs.bamboozle and not AP.bamboozleUntil and threatD < 30
               and nowS - (AP.bamboozleAt or 0) > 6 then
                -- Kante in Fluchtrichtung? (Boden jetzt da, weiter vorne weg)
                local dirE = goal
                local nearOk = select(1, groundAt(pos, dirE, 3, 8))
                local farOk = select(1, groundAt(pos, dirE, 9, 10))
                if nearOk and not farOk then
                    AP.bamboozleDir = dirE
                    AP.bamboozleUntil = nowS + 1.6
                    AP.bamboozleAt = nowS
                    AP.bamboozlePhase = "anlauf"
                    AP.bamboozleCount = (AP.bamboozleCount or 0) + 1
                    LOG("Bamboozle: Kante erkannt, Anlauf")
                end
            end
            if AP.bamboozleUntil then
                if nowS < AP.bamboozleUntil and AP.bamboozleDir then
                    local edgeClose = not select(1, groundAt(pos, AP.bamboozleDir, 4, 8))
                    if AP.bamboozlePhase == "anlauf" and not edgeClose then
                        goal = AP.bamboozleDir                     -- auf die Kante zu
                    else
                        -- an der Kante: harte Kehre
                        if AP.bamboozlePhase ~= "kehre" then
                            AP.bamboozlePhase = "kehre"
                            AP.bamboozleUntil = nowS + 0.45
                            AP.lastDir = nil                       -- abrupt drehen
                            LOG("Bamboozle: Kehre an der Kante")
                        end
                        goal = -AP.bamboozleDir
                    end
                else
                    AP.bamboozleUntil, AP.bamboozleDir, AP.bamboozlePhase = nil, nil, nil
                end
            end

            ------------------------------------------------------------------
            -- JUKE-MOVES: kleine Choreografien statt einzelner Haken.
            --   Double-Back : eine Seite antaeuschen, dann scharf zurueck
            --                 hinter ihm durch — er ist da schon festgelegt
            --   Orbit       : eng um ihn herumziehen, er kann nicht mitdrehen
            --   Stutter     : eine Zehntelsekunde stehen, er laeuft vorbei
            ------------------------------------------------------------------
            local AKm = ankles()
            local nowM = tick()
            local closeT
            for _, t in ipairs(state.threats or {}) do
                if t.mobile and (not closeT or t.d < closeT.d) then closeT = t end
            end

            if AP.move and nowM < (AP.move.tEnd or 0) and closeT then
                local mv = AP.move
                local toHim = (closeT.pos - pos) * Vector3.new(1, 0, 1)
                if toHim.Magnitude > 0.5 then
                    local fwd = -toHim.Unit                      -- stumpf weg
                    local side = Vector3.new(-toHim.Unit.Z, 0, toHim.Unit.X) * (mv.side or 1)
                    local prog = (nowM - mv.tStart) / math.max(mv.tEnd - mv.tStart, 0.01)
                    if mv.name == "doubleBack" then
                        -- erste Haelfte eine Seite, dann hart auf die andere
                        local dir = (prog < 0.42) and (side * 1.1 + fwd * 0.3)
                                                  or (-side * 1.25 + fwd * 0.25)
                        if dir.Magnitude > 0.05 then goal = dir.Unit end
                    end
                end
            else
                AP.move = nil
                local gapNeeded = 2.6
                if closeT and closeT.d < 15 and (closeT.sp or 0) > 12
                   and nowM - (AP.moveAt or 0) > gapNeeded then
                    local pool = {}
                    if AKm.doubleBack then pool[#pool + 1] = "doubleBack" end
                    if #pool > 0 then
                        local pick = pool[math.random(1, #pool)]
                        local dur = 0.6
                        AP.move = {
                            name = pick, tStart = nowM, tEnd = nowM + dur,
                            side = (math.random() < 0.5) and -1 or 1,
                        }
                        AP.moveAt = nowM
                        LOG(("Juke: %s gegen Verfolger auf %.1f Studs"):format(pick, closeT.d))
                    end
                end
            end

            -- Bewegungshilfen: Zipline/Jumppad/Rail/SwingBar in Fluchtrichtung
            -- werden angesteuert — Zipline und Pad bringen Tempo und Hoehe,
            -- also genau das, was beim Weglaufen zaehlt.
            local hBest, hScore, hKind
            for _, h in ipairs(helpers()) do
                local part = h.part
                if part.Parent then
                    local v = (part.Position - pos) * Vector3.new(1, 0, 1)
                    local dh = v.Magnitude
                    -- Reichweite von 45 auf 70 Studs: Trampolin und Zipline
                    -- sind die besten Fluchtmittel der Map, es lohnt sich,
                    -- auch von weiter weg darauf zuzuhalten.
                    if dh > 2 and dh < 70 then
                        local align = v.Unit:Dot(goal)
                        -- Jaeger darf nicht naeher dran sein als wir
                        local safe = true
                        for _, t in ipairs(state.threats or {}) do
                            if ((part.Position - t.pos) * Vector3.new(1, 0, 1)).Magnitude < dh * 0.9 then
                                safe = false break
                            end
                        end
                        -- Auch gegen die grobe Fluchtrichtung erlaubt, wenn es
                        -- Hoehe bringt: ein Trampolin schraeg hinter einem ist
                        -- mehr wert als geradeaus weiterlaufen.
                        local lift = part.Position.Y - pos.Y
                        local liftBonus = math.clamp(lift / 12, 0, 2.5)
                        if safe and align > (liftBonus > 0.6 and -0.6 or -0.15) then
                            local sc = h.w * 1.6 + align * 1.3
                                     + (70 - dh) / 70 * 0.8 + liftBonus * 1.4
                            if not hScore or sc > hScore then hBest, hScore, hKind = v.Unit, sc, h.kind end
                        end
                    end
                end
            end
            if hBest and movesTowardThreat(pos, hBest) then hBest = nil end
            if hBest and hScore > 1.4 then
                goal = goal + hBest * 2.2
                if goal.Magnitude > 0.05 then goal = goal.Unit end
                AP.helper = hKind
            else
                AP.helper = nil
            end

            -- Abstecher: liegt ein taggbares Ziel nah und grob in Fluchtrichtung,
            -- wird es im Vorbeilaufen mitgenommen (sicheres Ziel eher als eines,
            -- das selbst taggen darf).
            local grabBest, grabScore
            for _, q in ipairs(state.preys or {}) do
                local v = (q.pos - pos) * Vector3.new(1, 0, 1)
                local dq = v.Magnitude
                local limit = q.risky and 16 or 30
                if dq > 1 and dq < limit then
                    local align = v.Unit:Dot(goal)
                    if align > (q.risky and 0.45 or 0.05) then
                        local sc = align + (limit - dq) / limit * 0.6 - (q.risky and 0.5 or 0)
                        if not grabScore or sc > grabScore then grabBest, grabScore = v.Unit, sc end
                    end
                end
            end
            if grabBest and movesTowardThreat(pos, grabBest) then grabBest = nil end
            if grabBest then
                goal = goal + grabBest * 1.1
                if goal.Magnitude > 0.05 then goal = goal.Unit end
                AP.grabbing = true
            else
                AP.grabbing = false
            end

            -- Finten: regelmaessige Richtungswechsel, abwechselnd links/rechts.
            -- Nah am Verfolger schaerfer und kuerzer, weiter weg flacher.
            local nowF = tick()
            local AK = ankles()
            -- Auf einer geplanten Route wurde bisher gar nicht gefintet. Bei
            -- einem Verfolger im Nacken ist ein kurzer Haken aber wichtiger
            -- als der Routenplan — deshalb ab 25 Studs trotzdem erlaubt.
            if AK.on and threatD < 45 and threatD > AK.minDist
               and (not AP.usingPath or threatD < 25)
               and not AP.wallFollow then
                -- Nach einer Finte wird erst wieder sauber Abstand gelaufen.
                -- Ohne das kettet er Haken aneinander, bleibt auf der Stelle
                -- und der Verfolger holt genau dabei auf.
                local recovered = (not AP.feintEndD)
                    or threatD > (AP.feintEndD + 3.0)
                    or threatD > 18
                if (not AP.feintNext or nowF > AP.feintNext) and recovered
                   and math.random() < (AK.chance or 1) then
                    local sharp = threatD < 15
                    AP.feintSide = -(AP.feintSide or 1)
                    -- BURNER: ab Stufe 8 gibt es die harte Kehre direkt auf ihn
                    -- zu. Bewusst gegen die Sicherheitsregel, aber nur ein
                    -- Wimpernschlag lang — genau das bricht die Knoechel.
                    local burner = AK.burner and threatD > 11 and threatD < 30
                                   and math.random() < (AK.burnerP or 0.45)
                    if burner then
                        AP.feintAngle = (165 + math.random() * 25) * AP.feintSide
                        AP.feintUntil = nowF + 0.12 + math.random() * 0.06
                        AP.feintBurner = true
                        AP.burnerCount = (AP.burnerCount or 0) + 1
                    else
                        local base = sharp and AK.maxAngle or (AK.maxAngle * 0.75)
                        AP.feintAngle = (base * (0.8 + math.random() * 0.2)) * AP.feintSide
                        AP.feintUntil = nowF + AK.dur + math.random() * 0.1
                        AP.feintBurner = false
                    end
                    AP.feintNext = AP.feintUntil + AK.gap * (0.7 + math.random() * 0.6)
                end
                if AP.feintUntil and AP.feintUntil > 0 and nowF >= AP.feintUntil
                   and not AP.feintClosed then
                    AP.feintClosed = true
                    AP.feintEndD = threatD          -- ab hier muss Abstand her
                end
                if AP.feintUntil and nowF < AP.feintUntil then
                    AP.feintClosed = false
                    -- Eine Finte darf NIE in Richtung eines Verfolgers zeigen.
                    -- Erst die gewaehlte Seite pruefen, dann die andere, sonst
                    -- wird die Finte fuer diesen Zyklus verworfen.
                    -- Ab hoher Ankles-Stufe ist ein Haken quer am Verfolger
                    -- vorbei erlaubt, solange der schnell auf uns zurennt
                    -- (er kann dann nicht mehr korrigieren) und Platz da ist.
                    local towardThreat = function(cand)
                        if AP.feintBurner then return false end   -- Burner darf das
                        if not movesTowardThreat(pos, cand) then return false end
                        if not AK.cross then return true end
                        local fast = false
                        for _, t in ipairs(state.threats or {}) do
                            if t.d < 26 and (t.sp or 0) > 20 then fast = true break end
                        end
                        if not fast then return true end
                        return rayClear(pos, cand, 2.4, 10) < 0.8    -- nur mit Platz
                    end
                    local function rot(ang)
                        local c = CFrame.Angles(0, math.rad(ang), 0) * goal
                        c = c * Vector3.new(1, 0, 1)
                        return c.Magnitude > 0.05 and c.Unit or nil
                    end
                    local a = AP.feintAngle or 0
                    local cand = rot(a)
                    if not cand or towardThreat(cand) then
                        cand = rot(-a)
                        if cand and not towardThreat(cand) then
                            AP.feintSide = -(AP.feintSide or 1)
                            AP.feintAngle = -a
                        else
                            cand = nil
                            AP.feintUntil = 0          -- Finte verwerfen
                        end
                    end
                    if cand then goal = cand end
                end
            end
        end
    end

    -- STREIFEN: kein Jaeger, kein Ziel -> trotzdem nie stehen bleiben.
    -- Es wird zwischen Kartenpunkten gependelt (mittig/hoch bevorzugt), damit
    -- Tempo und Momentum erhalten bleiben.
    if not goal or goal.Magnitude < 0.1 then
        buildNodes()
        local list = NODES.list
        local nowR = tick()
        -- Streifziel laenger halten: es alle 14 s zu wechseln hat den Bot
        -- staendig neu ausrichten lassen, was sich als groesster Abstand
        -- zum Sollweg niederschlug (6 Studs gegenueber 1.3 beim Jagen).
        local need = not AP.roamNode
            or nowR - (AP.roamAt or 0) > 26
            or ((AP.roamNode - pos) * Vector3.new(1, 0, 1)).Magnitude < 16
        if need and list and #list > 8 then
            -- unter den brauchbaren Punkten einen zufaelligen waehlen, damit er
            -- nicht immer dieselbe Ecke ansteuert
            local cand = {}
            local center, radius = mapCache.center, mapCache.radius
            for _, n in ipairs(list) do
                local dv = (n - pos) * Vector3.new(1, 0, 1)
                local dy = n.Y - pos.Y
                if dv.Magnitude > 45 and dv.Magnitude < 260 and dy > -60 and dy < 45 then
                    local centrality = center and
                        (1 - math.clamp(((n - center) * Vector3.new(1, 0, 1)).Magnitude / radius, 0, 1)) or 0
                    if centrality > 0.35 or #cand < 10 then cand[#cand + 1] = n end
                end
            end
            if #cand > 0 then
                AP.roamNode, AP.roamAt = cand[math.random(1, #cand)], nowR
            end
        end
        if AP.roamNode then
            local v = (AP.roamNode - pos) * Vector3.new(1, 0, 1)
            if v.Magnitude > 1 then
                goal = v.Unit
                mode = "STREIFEN"
                -- unterwegs Erhoehungen mitnehmen statt stumpf geradeaus
                local hd, hs = findHighSpot(pos, goal)
                if hd and hs then
                    goal = (goal * 0.5 + hd * 0.9)
                    if goal.Magnitude > 0.05 then goal = goal.Unit end
                    if ((hs - pos) * Vector3.new(1, 0, 1)).Magnitude < 5.5
                       and tick() - (AP.lastJump or 0) > 0.45 then
                        AP.lastJump = tick()
                        AP.highJumps = (AP.highJumps or 0) + 1
                        tryJump()
                    end
                end
            end
        end
        if not goal or goal.Magnitude < 0.1 then
            -- absoluter Notnagel: letzte Richtung weiterlaufen
            if AP.lastDir then
                goal, mode = AP.lastDir, "STREIFEN"
            else
                local a = math.random() * math.pi * 2
                goal, mode = Vector3.new(math.cos(a), 0, math.sin(a)), "STREIFEN"
            end
        end
    end

    if not goal or goal.Magnitude < 0.1 then
        AP.mode, AP.vec, AP.samplePos = nil, nil, nil
        return
    end
    goal = goal.Unit

    ------------------------------------------------------------------
    -- FESTGEFAHREN? -> WANDVERFOLGUNG (Bug-Algorithmus)
    -- Ein reines Kraftfeld (weg vom Jaeger / hin zum Ziel) bleibt in
    -- konkaver Geometrie zuverlaessig haengen. Statt zufaellig auszuscheren
    -- wird die Wand konsequent an EINER Seite entlang verfolgt, bis das Ziel
    -- wieder naeher UND frei erreichbar ist.
    -- Erkennung nach drei Kriterien: kaum Vorankommen, Kurs weicht >90 Grad
    -- vom Ziel ab, oder wir kommen an den Startpunkt zurueck (Kreisen).
    ------------------------------------------------------------------
    local now2 = tick()
    local goalDist = (AP.wallFollowGoal and (AP.wallFollowGoal - pos).Magnitude) or nil

    if not AP.sampleAt or now2 - AP.sampleAt > 0.5 then
        local moved = AP.samplePos and (pos - AP.samplePos).Magnitude or 99
        local headingBad = false
        if AP.lastDir and goal.Magnitude > 0.1 then
            headingBad = AP.lastDir:Dot(goal.Unit) < 0
        end
        if AP.samplePos and (moved < 2.5 or headingBad) and now2 > AP.manualUntil then
            AP.stuckRun = (AP.stuckRun or 0) + 1
        elseif moved > 6 then
            AP.stuckRun = 0
        end
        AP.sampleAt, AP.samplePos = now2, pos

        -- Wandverfolgung starten
        if (AP.stuckRun or 0) >= 2 and not AP.wallFollow then
            local probe = workspace:Raycast(pos + Vector3.new(0, 2.4, 0), goal * 7, AP.rp)
            if not probe then
                -- keine Wand direkt voraus: naechste Wand ringsum suchen
                local bd
                for i = 0, 11 do
                    local a8 = i * (math.pi * 2 / 12)
                    local d8 = Vector3.new(math.cos(a8), 0, math.sin(a8))
                    local h8 = workspace:Raycast(pos + Vector3.new(0, 2.4, 0), d8 * 8, AP.rp)
                    if h8 and math.abs(h8.Normal.Y) < 0.4 then
                        local dd = (h8.Position - pos).Magnitude
                        if not bd or dd < bd then probe, bd = h8, dd end
                    end
                end
            end
            if probe then
                local tan = probe.Normal:Cross(Vector3.new(0, 1, 0)) * Vector3.new(1, 0, 1)
                if tan.Magnitude > 0.05 then
                    tan = tan.Unit
                    -- Seite waehlen, die eher Richtung Ziel zeigt, und behalten
                    AP.wallSide = (tan:Dot(goal) >= 0) and 1 or -1
                    AP.wallFollow = true
                    AP.wallFollowAt = now2
                    AP.wallFollowGoal = pos + goal * 60
                    AP.wallHitDist = 60
                    AP.wallHitPos = pos
                    LOG("festgefahren — Wandverfolgung gestartet")
                end
            end
            AP.stuckRun = 0
        end
    end

    -- laufende Wandverfolgung
    if AP.wallFollow then
        local abort = false
        local dGoal = AP.wallFollowGoal and (AP.wallFollowGoal - pos).Magnitude or 0
        -- Ausstieg: naeher am Ziel als beim Start UND freie Sicht dorthin
        if AP.wallFollowGoal then
            local toG = (AP.wallFollowGoal - pos) * Vector3.new(1, 0, 1)
            if toG.Magnitude > 1 then
                local clear = not workspace:Raycast(pos + Vector3.new(0, 2.4, 0),
                                                    toG.Unit * math.min(toG.Magnitude, 16), AP.rp)
                if clear and dGoal < (AP.wallHitDist or 1e9) - 3 then abort = true end
            end
        end
        if now2 - (AP.wallFollowAt or 0) > 5 then abort = true end
        -- Kreisen erkannt: Seite wechseln statt weiterzulaufen
        if not abort and AP.wallHitPos and now2 - (AP.wallFollowAt or 0) > 1.5
           and (pos - AP.wallHitPos).Magnitude < 5 then
            AP.wallSide = -(AP.wallSide or 1)
            AP.wallFollowAt = now2
        end
        if abort then
            AP.wallFollow = false
            AP.lastDir = nil
        else
            -- Wand rechts/links halten und an ihr entlanglaufen
            local side = Vector3.new(-goal.Z, 0, goal.X) * (AP.wallSide or 1)
            local probe2
            for _, dirTry in ipairs({ side, goal, -side }) do
                local h9 = workspace:Raycast(pos + Vector3.new(0, 2.4, 0), dirTry * 8, AP.rp)
                if h9 and math.abs(h9.Normal.Y) < 0.4 then probe2 = h9 break end
            end
            if probe2 then
                local tan = probe2.Normal:Cross(Vector3.new(0, 1, 0)) * Vector3.new(1, 0, 1)
                if tan.Magnitude > 0.05 then
                    tan = tan.Unit * (AP.wallSide or 1)
                    -- leicht zur Wand ziehen, damit der Kontakt nicht abreisst
                    local follow = tan - probe2.Normal * 0.22
                    if follow.Magnitude > 0.05 then
                        goal = follow.Unit
                        mode = (mode or "") .. ""
                        AP.following = true
                    end
                end
            else
                AP.wallFollow = false     -- keine Wand mehr da: normal weiter
            end
        end
    else
        AP.following = false
    end

    ---------------------------------------------------------------
    -- LEITERN: muss es hoch und steht eine Leiter in der Naehe, wird sie
    -- benutzt. Beim Klettern wird weiter in die Leiter gedrueckt (so klettert
    -- der Humanoid hoch), oben angekommen wird abgesprungen.
    ---------------------------------------------------------------
    local hum = char:FindFirstChildOfClass("Humanoid")
    local climbing = (hum and hum:GetState() == Enum.HumanoidStateType.Climbing)
                     or RENV.shared.touchingTruss
    local targetPos, forcedUp
    if mode == "JAGD" and prey then
        local pr = hrpOf(prey)
        targetPos = pr and pr.Position
    end
    local wantUp = targetPos and (targetPos.Y - pos.Y > 6)
                   or (mode == "FLUCHT" and (AP.stuckRun or 0) >= 1)
    local climbGoal

    if climbing then
        local l = AP.ladder
        if l and l.Parent then
            local v = (l.Position - pos) * Vector3.new(1, 0, 1)
            if v.Magnitude > 0.1 then climbGoal = v.Unit end
        end
        climbGoal = climbGoal or goal
        -- oben genug: abspringen und normal weiter
        if targetPos and pos.Y >= targetPos.Y - 2.5 then
            tryJump(true)          -- oben angekommen: bewusst abspringen
            AP.ladder = nil
            climbGoal = nil
        end
    elseif wantUp then
        -- Nahbereichs-Notloesung. Die eigentliche Vertikalplanung macht der
        -- Navigationsgraph; das hier greift nur, wenn gerade kein Weg laeuft.
        -- Eine Leiter wird NUR benutzt, wenn sie wirklich hilft: grob in
        -- Zielrichtung, naeher als das Ziel, hoch genug — und nur, wenn der
        -- direkte Weg zum Ziel tatsaechlich blockiert ist. Sonst klettert er
        -- sinnlos herum, waehrend der Gegner ebenerdig davonlaeuft.
        local toTarget, tDist
        if targetPos then
            local v = (targetPos - pos) * Vector3.new(1, 0, 1)
            tDist = v.Magnitude
            if v.Magnitude > 0.1 then toTarget = v.Unit end
        end
        local directBlocked = true
        if toTarget then
            directBlocked = rayClear(pos, toTarget, 2.4, math.min(tDist, 25)) < 0.6
        end
        local best, bestD
        if directBlocked and (not targetPos or (targetPos.Y - pos.Y) > 10) then
            for _, l in ipairs(ladders()) do
                if l.Parent then
                    local top = l.Position.Y + l.Size.Y * 0.5
                    local v = (l.Position - pos) * Vector3.new(1, 0, 1)
                    local d = v.Magnitude
                    local towardOk = (not toTarget) or (d > 0.1 and v.Unit:Dot(toTarget) > 0.2)
                    local closerThanTarget = (not tDist) or d < tDist * 0.8
                    if top > pos.Y + 8 and d < 24 and towardOk and closerThanTarget
                       and (not bestD or d < bestD) then
                        best, bestD = l, d
                    end
                end
            end
        end
        if best then
            AP.ladder = best
            local v = (best.Position - pos) * Vector3.new(1, 0, 1)
            if v.Magnitude > 0.1 then climbGoal = v.Unit end
        end
    end

    if climbGoal then goal = climbGoal end
    AP.climbing = climbing and AP.ladder ~= nil

    -- Steht er bereits auf Eis, zaehlt nur noch: runter davon. Die Richtung
    -- mit festem Boden in der Naehe wird bevorzugt.
    if hum and (hum.FloorMaterial == Enum.Material.Ice
                or hum.FloorMaterial == Enum.Material.Glacier) then
        AP.onIce = true
        local bestOut, bestScoreOut
        for i = 0, 11 do
            local a = i * (math.pi * 2 / 12)
            local d = Vector3.new(math.cos(a), 0, math.sin(a))
            local g, slip = groundAt(pos, d, 9, 12)
            if g and not slip then
                local sc = d:Dot(goal) * 0.5 + 1
                if not bestScoreOut or sc > bestScoreOut then bestOut, bestScoreOut = d, sc end
            end
        end
        if bestOut then goal = bestOut end
    else
        AP.onIce = false
    end

    -- Beim Weglaufen an eine Wand: hochklettern statt daran entlangzuschrammen.
    -- Hoehe ist der beste Fluchtvorteil, und Wallclimb/Tic-Tac sind aktiv.
    if mode == "FLUCHT" and not climbGoal and goal and tick() - (AP.lastJump or 0) > 0.2 then
        local ahead = rayClear(pos, goal, 2.4, 5)
        local low = rayClear(pos, goal, 0.5, 5)
        if ahead < 0.55 or low < 0.45 then
            local hrpF = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
            local vy = hrpF and hrpF.AssemblyLinearVelocity.Y or 0
            -- seitlich an der Wand entlang statt dagegen: nur so greift Wallrun
            local hitW = workspace:Raycast(pos + Vector3.new(0, 2.4, 0), goal * 5, AP.rp)
            if hitW and math.abs(hitW.Normal.Y) < 0.35 then
                local tan = hitW.Normal:Cross(Vector3.new(0, 1, 0)) * Vector3.new(1, 0, 1)
                if tan.Magnitude > 0.05 then
                    tan = tan.Unit
                    if tan:Dot(goal) < 0 then tan = -tan end
                    goal = (tan - hitW.Normal * 0.25)
                    if goal.Magnitude > 0.05 then goal = goal.Unit end
                end
            end
            if vy < 4 then           -- Kette: erst nachsetzen, wenn der Impuls weg ist
                AP.lastJump = tick()
                tryJump(true)
                AP.wallclimb = true
            end
        else
            AP.wallclimb = false
        end
    end

    -- KLETTER-ASSISTENT: Vault und Wallclimb loesen nur aus, wenn man wirklich
    -- gegen die Kante laeuft. Die normale Hindernislogik weicht Waenden aber
    -- aus — deshalb wird beim Hochwollen bewusst draufgehalten und im richtigen
    -- Moment gesprungen (kurz vor der Wand, dann nachsetzen fuer die Kette).
    -- Wallride-Klettern ueber die gemeinsame Routine (siehe climbStep):
    -- greift, wenn das Ziel hoeher liegt und der Direktanlauf nicht vorankommt.
    local climbAllowed = wantUp and (not AP.chaseSince or (tick() - AP.chaseSince > 1.2))
    if not climbGoal and climbAllowed and targetPos then
        local flatV = (targetPos - pos) * Vector3.new(1, 0, 1)
        local dirT = flatV.Magnitude > 0.1 and flatV.Unit or nil
        local cdir = climbStep(pos, dirT)
        if cdir then
            climbGoal = cdir
        elseif dirT and (targetPos.Y - pos.Y) > 8 then
            -- keine Wand in Reichweite: kletterbare Flaeche Richtung Ziel ansteuern
            local bestW, bestScore
            for i = 0, 15 do
                local a9 = i * (math.pi * 2 / 16)
                local d9 = Vector3.new(math.cos(a9), 0, math.sin(a9))
                if d9:Dot(dirT) > -0.2 then
                    local h9 = workspace:Raycast(pos + Vector3.new(0, 2, 0), d9 * 40, AP.rp)
                    if h9 and math.abs(h9.Normal.Y) < 0.15
                       and workspace:Raycast(h9.Position + Vector3.new(0, 9, 0), -h9.Normal * 4, AP.rp) then
                        local sc = d9:Dot(dirT) * 2 - (h9.Position - pos).Magnitude / 40
                        if not bestScore or sc > bestScore then bestW, bestScore = h9, sc end
                    end
                end
            end
            if bestW then
                local toW = (bestW.Position - pos) * Vector3.new(1, 0, 1)
                if toW.Magnitude > 3 then
                    climbGoal = toW.Unit
                    AP.climbApproach = true
                end
            end
        else
            AP.climbApproach = false
        end
    end
    if climbGoal then goal = climbGoal end

    -- Kein Leiterweg, Ziel aber deutlich hoeher: gegen die Wand springen.
    -- Mit aktivem Wallclimb/Tic-Tac zieht sich der Charakter daran hoch.
    if not climbGoal and wantUp and targetPos then
        local up = (targetPos.Y - pos.Y)
        local flat = ((targetPos - pos) * Vector3.new(1, 0, 1)).Magnitude
        if up > 6 and flat < 30 and tick() - (AP.lastJump or 0) > 0.5 then
            local ahead = rayClear(pos, ((targetPos - pos) * Vector3.new(1, 0, 1)).Unit, 2.4, 6)
            if ahead < 0.6 then
                AP.lastJump = tick()
                tryJump()
            end
        end
    end

    ---------------------------------------------------------------
    -- Pfad statt Gier: bei weiten Wegen und beim Haengenbleiben
    ---------------------------------------------------------------
    -- Jeden Frame zuruecksetzen: der Jagdzweig setzt es gleich wieder, aber
    -- beim Wechsel in die Flucht bliebe es sonst dauerhaft haengen und die
    -- Finten waeren fuer den Rest der Runde aus.
    rawset(CFG, "__chasing", false)
    local wantPath = false
    local pathTarget = nil
    if mode == "JAGD" and prey and preyD then
        -- Beim aktiven Verfolgen zaehlt Tempo: erst mal schnurgerade drauf zu.
        -- Ein Pfad wird nur gerechnet, wenn die direkte Linie laenger blockiert
        -- ist oder wir haengen — Pfade scheitern in diesen Maps oft ohnehin.
        local pr = hrpOf(prey)
        if pr then
            local toT = (pr.Position - pos) * Vector3.new(1, 0, 1)
            local blockedNow = toT.Magnitude > 8
                and rayClear(pos, toT.Unit, 2.4, math.min(toT.Magnitude, 28)) < 0.55
            if blockedNow then
                AP.blockedSince = AP.blockedSince or tick()
            else
                AP.blockedSince = nil
            end
            local blockedLong = AP.blockedSince and (tick() - AP.blockedSince > 1.2)
            -- Ziel deutlich hoeher/tiefer: die Luftlinie hilft nicht weiter,
            -- da braucht es einen echten Weg (Treppe, Rampe, Umweg).
            local vGap = pr.Position.Y - pos.Y
            -- Hoehenunterschied ALLEIN ist kein Grund fuer einen Umweg — oft
            -- liegt eine Rampe direkt davor. Erst wenn die Linie wirklich zu
            -- ist oder kein Fortschritt kommt, wird gerechnet.
            local levelDiff = math.abs(vGap) > 8 and blockedNow
            if blockedLong or levelDiff or (AP.stuckRun or 0) >= 1 then
                wantPath, pathTarget = true, pr.Position
            elseif not blockedNow then
                PATH.wps = nil          -- Linie frei: direkt drauf zu
            end
        end
    elseif mode == "FLUCHT" then
        -- Fluchtziel bewusst waehlen (mittig, hoch, weg von allen Jaegern) und
        -- dorthin pfaden. Nur wenn der Jaeger direkt im Nacken sitzt, zaehlt
        -- die unmittelbare Ausweichrichtung mehr als der Plan.
        buildNodes()
        local closeDanger = (threatD or 999) < 14
        local nowE = tick()

        -- Gibt es taggbare Spieler, wird IMMER zu ihnen gepfadet statt auf
        -- hoch/mittig gelegene Kartenpunkte. Sicheres Ziel (kann mich nicht
        -- taggen) zaehlt mehr als eines, das selbst taggen darf; Ziele, die
        -- hinter einem Verfolger liegen, werden abgewertet.
        local preyTarget, preyScore
        for _, q in ipairs(state.preys or {}) do
            if q.pl and q.pl.Character then
                local v = (q.pos - pos) * Vector3.new(1, 0, 1)
                local dq = v.Magnitude
                if dq > 3 then
                    local dir = v.Unit
                    local pass = 0
                    for _, t in ipairs(state.threats or {}) do
                        local tv = (t.pos - pos) * Vector3.new(1, 0, 1)
                        local proj = tv:Dot(dir)
                        if proj > 0 and proj < dq then
                            local perp = (tv - dir * proj).Magnitude
                            if perp < 20 then pass = pass + (20 - perp) / 20 end
                        end
                    end
                    local sc = (q.risky and -1.2 or 1.8)
                             - math.clamp(dq / 300, 0, 1) * 1.5
                             + (goal and dir:Dot(goal) or 0) * 0.9
                             - pass * 2.2
                    if not preyScore or sc > preyScore then preyTarget, preyScore = q, sc end
                end
            end
        end
        if preyTarget and not closeDanger then
            AP.escNode = nil
            -- fester Verfolgungspunkt statt der zappelnden Live-Position
            local cp = chasePoint(pos, preyTarget.pl)
            wantPath, pathTarget = true, cp or preyTarget.pos
            AP.chasePoint = cp
            AP.routeTo = preyTarget.pl and preyTarget.pl.Name or nil
            rawset(CFG, "__chasing", true)    -- schaltet AYIP ab
        else
            AP.chasePoint = nil
            rawset(CFG, "__chasing", false)
        end

        -- Das Fluchtziel bekommt eine Haltefrist. Vorher wurde alle 2.5 s
        -- neu gewaehlt und zusaetzlich sofort verworfen, sobald irgendein
        -- Jaeger naeher dran war — bei laufenden Verfolgern kippt das
        -- staendig zwischen zwei Punkten, und der Bot rennt sichtbar hin
        -- und her, ohne je irgendwo anzukommen.
        local held = nowE - (AP.escAt or 0)
        -- SOLANGE EIN WEG ZU DIESEM ZIEL NOCH GEFAHREN WIRD, NICHT UMDISPONIEREN.
        -- Jeder Zielwechsel wirft den berechneten Weg weg: gemessen wurden im
        -- Schnitt nur 26 bis 32 Prozent jedes Weges abgefahren, bei einer
        -- mittleren Weglebensdauer von 2.7 Sekunden. Das Ziel wurde alle
        -- hoechstens sechs Sekunden neu gewuerfelt, und weil der neue Punkt
        -- weit weg lag, galt der alte Weg sofort als veraltet.
        local onRoute = PATH.wps and PATH.target and AP.escNode
            and (PATH.target - AP.escNode).Magnitude < 5
            and (PATH.idx or 1) < #PATH.wps * 0.7
        local needNew = not AP.escNode
            or (held > 6.0 and not onRoute)
            or ((AP.escNode - pos) * Vector3.new(1, 0, 1)).Magnitude < 18
        if needNew and not closeDanger and not preyTarget then
            -- Zuerst den Graphen fragen: er kennt Hoehe und Auswege und
            -- schickt den Bot nach oben statt in die naechste Ecke.
            local node = pickEscapeGraph(pos, state.threats or {})
                      or pickEscapeNode(pos, state.threats or {}, state.preys or {})
            if node then
                -- einen laufenden Lauf nicht fuer einen minimal anderen
                -- Punkt aufgeben: der neue muss spuerbar woanders liegen
                local keepOld = AP.escNode
                    and (onRoute
                         or (held < 2.5
                             and ((node - AP.escNode) * Vector3.new(1, 0, 1)).Magnitude < 40))
                if not keepOld then
                    AP.escNode, AP.escAt = node, nowE
                end
            elseif not AP.escNode then
                AP.escNode = nil
            end
        end
        -- Ziel nur aufgeben, wenn ein Jaeger DEUTLICH besser steht, und
        -- auch dann erst nach einer kurzen Mindestlaufzeit. Sonst entsteht
        -- genau das Flattern, das den Bot hin und her laufen laesst.
        if AP.escNode and held > 1.2 then
            local dMe = ((AP.escNode - pos) * Vector3.new(1, 0, 1)).Magnitude
            for _, t in ipairs(state.threats or {}) do
                if ((AP.escNode - t.pos) * Vector3.new(1, 0, 1)).Magnitude < dMe * 0.55 then
                    AP.escNode, AP.escAt = nil, nil
                    break
                end
            end
        end
        if preyTarget and not closeDanger then
            -- schon oben gesetzt
        elseif AP.escNode and not closeDanger then
            wantPath, pathTarget = true, AP.escNode
            AP.routeTo = "Kartenpunkt"
        elseif (AP.stuckRun or 0) >= 1 then
            local c = select(1, mapCenterRadius())
            local esc = goal
            if c then
                local toC = (c - pos) * Vector3.new(1, 0, 1)
                if toC.Magnitude > 1 then esc = (goal * 0.6 + toC.Unit * 0.6) end
            end
            if esc.Magnitude > 0.05 then
                wantPath, pathTarget = true, pos + esc.Unit * 80
            end
        end
    end

    if climbGoal then wantPath = false end
    if mode == "STREIFEN" and AP.roamNode then
        local dRoam = ((AP.roamNode - pos) * Vector3.new(1, 0, 1)).Magnitude
        if dRoam > 30 then
            wantPath, pathTarget = true, AP.roamNode
            AP.routeTo = "Streifzug"
        end
    end

    -- ZWEI REICHWEITEN.
    -- Der Graph ist fuer die grobe Route da: er kennt Leitern, Stufen und
    -- Ziplines ueber die ganze Karte, sein Raster ist aber 4 bis 9 Studs
    -- weit und damit blind fuer alles Kleinteilige. Im Nahbereich taugt er
    -- deshalb nicht — dort ist die freie Steuerung besser, die jeden Frame
    -- die Umgebung abtastet und sofort reagiert.
    -- Also: weit weg planen, nah dran direkt steuern.
    -- Mit einer einzigen Schwelle kippt der Modus am Uebergang staendig
    -- hin und her und verwirft dabei jedes Mal den Weg. Darum getrennte
    -- Grenzen: ab 70 Studs wird geplant, erst unter 45 wieder direkt
    -- gesteuert.
    if wantPath and pathTarget then
        -- ECHTE Entfernung, nicht nur die horizontale. Ein Ziel 30 Studs
        -- unter einem, aber nur 10 Studs seitlich, galt sonst als "nah":
        -- die freie Steuerung lief dann auf die Position ueber ihm zu und
        -- kreiste dort, weil sie da nie ankommt. Wer in einer Hoehle oder
        -- einem Stockwerk darunter sitzt, braucht immer eine Route.
        -- HOEHE ZAEHLT IN DIESER ENTSCHEIDUNG MEHRFACH.
        -- Fuer die freie Nahbereichssteuerung ist ein Ziel 20 Studs ueber dem
        -- Bot nicht "20 Studs weg" — sie kann gar nicht hoch, sie laeuft nur
        -- darunter herum. Horizontale Strecke frisst sie dagegen einfach weg.
        -- Deshalb geht der Hoehenunterschied dreifach in die Entfernung ein,
        -- die ueber Route oder Direktsteuerung entscheidet.
        local dxz = ((pathTarget - pos) * Vector3.new(1, 0, 1)).Magnitude
        local dyG = math.abs(pathTarget.Y - pos.Y)
        local toGoal = math.sqrt(dxz * dxz + (dyG * 3) ^ 2)
        -- Hoehenunterschied bleibt Sache des Graphen, auch auf kurze
        -- Distanz: eine Leiter direkt vor der Nase findet die freie
        -- Steuerung nie. Schwelle von 8 auf 6 Studs gesenkt — schon eine
        -- Kistenreihe oder ein Absatz reicht, um die Direktsteuerung
        -- scheitern zu lassen.
        local climbNeed = dyG > 6
        -- Gemessen nach Modus getrennt (GlassHouses, je Minute):
        --   FLUCHT   mit Route 337 Fehler, ohne Route  96
        --   STREIFEN mit Route  34 Fehler, ohne Route  29
        --   JAGD     ohne Route  21 Fehler bei 35.8 Studs/s
        -- Auf der Flucht schadet die Route also massiv: das Ziel ist nur
        -- eine grobe Himmelsrichtung, und stur abgefahrene Wegpunkte
        -- kosten dort mehr als sie bringen. Beim Jagen zaehlt dagegen der
        -- genaue Punkt. Darum greift die Route auf der Flucht erst sehr
        -- spaet, sonst frueh.
        local farEnough = (mode == "FLUCHT") and 150 or 70
        local nearEnough = (mode == "FLUCHT") and 110 or 45
        if climbNeed then
            AP.longRange = true
        elseif toGoal > farEnough then
            AP.longRange = true
        elseif toGoal < nearEnough then
            AP.longRange = false
        end
        if not AP.longRange then
            wantPath = false
            -- kein Fehlschlag, sondern der geplante Wechsel: nah genug am
            -- Ziel uebernimmt die Direktsteuerung. Die Messung soll das
            -- nicht als abgebrochenen Weg zaehlen.
            if PATH.wps then PATH.endWhy = "nahbereich" end
            -- bewusster Moduswechsel, kein verlorener Weg: sonst meldet die
            -- Fehlererkennung hier faelschlich "pfad_verloren"
            if PATH.wps then PATH.wps = nil ; PATH.target = nil end
            AP.usingPath = false
            AP.routeTo = "direkt"
        end
    end

    if wantPath and pathTarget then
        local age = tick() - (PATH.at or 0)
        local moved = PATH.target and (PATH.target - pathTarget).Magnitude or math.huge
        -- nach mehreren Fehlschlaegen seltener neu rechnen (spart Last)
        local minAge = (PATH.fails >= 3) and 4.0 or 0.8
        -- Alter allein reicht als Ausloeser nicht: bei Vollgas (37 Studs/s)
        -- sind 2.5 s ganze 92 Studs Fahrt, der Pfad ist dann laengst Makulatur
        -- — bei WalkSpeed 16 dagegen nur 40. Darum zusaetzlich die seit der
        -- letzten Rechnung zurueckgelegte Strecke pruefen.
        local runSince = PATH.from and (pos - PATH.from).Magnitude or math.huge
        -- Ein STEHENDES Ziel braucht keine Neuberechnung. Beim Weglaufen ist
        -- der Fluchtpunkt fix, da war "alle 2.5 s neu" reine Last — genau
        -- daher kamen 50 Anfragen in 30 s. Neu gerechnet wird jetzt nur bei
        -- fehlendem Weg, bewegtem Ziel (Jagd) oder viel gelaufener Strecke;
        -- die 8 s sind nur noch ein Sicherheitsnetz gegen veraltete Wege.
        -- WEGE NICHT WEGWERFEN, DIE NOCH GEFAHREN WERDEN.
        -- Gemessen ueber 56 Wege: im Schnitt wurden nur 26 Prozent davon
        -- abgefahren, 46 endeten vorzeitig, und der Grund war fast immer
        -- "neuer Weg" — der alte war noch gut, wurde aber nach 70 gelaufenen
        -- Studs (bei 28 Studs/s also alle 2.5 s) durch einen frischen
        -- ersetzt. Jede Rechnung kostet 12 bis 30 ms und setzt den
        -- Fortschritt zurueck.
        -- Die Strecken-Regel greift deshalb nur noch, wenn der Weg auch
        -- weitgehend abgefahren ist; laeuft der Bot noch mittendrin, bleibt
        -- sein Weg stehen. Ein bewegtes Ziel (Jagd) rechnet weiter sofort neu.
        local wpsNow = PATH.wps
        local nearEnd = (not wpsNow) or #wpsNow < 2
            or (PATH.idx or 1) >= #wpsNow * 0.6
        -- WELCHE BEDINGUNG HAT DIE NEUBERECHNUNG AUSGELOEST?
        -- Ohne das laesst sich die Rechnerei nicht abstellen: die Wege werden
        -- gemessen nur zu 8 bis 14 Prozent abgefahren, und mehr als die
        -- Haelfte endet mit "neuer Weg".
        -- ZIELWECHSEL ENTPRELLEN.
        -- Gemessen springt das Ziel im Schnitt 91.6 Studs (bis 258) und hat
        -- damit 941 Neuberechnungen in drei Minuten ausgeloest — mit Abstand
        -- der haeufigste Grund. Dahinter steckt meist ein kurzes Hin und Her
        -- zwischen zwei Kandidaten (Fluchtpunkt gegen Verfolgungspunkt beim
        -- Moduswechsel). Ein neues Ziel muss sich deshalb erst eine halbe
        -- Sekunde halten, bevor darauf neu gerechnet wird; springt es
        -- zurueck, bleibt der laufende Weg stehen.
        local far = moved > 18
        if far then
            if not PATH.newTarget
               or (PATH.newTarget - pathTarget).Magnitude > 12 then
                PATH.newTarget, PATH.newTargetAt = pathTarget, tick()
            end
            if tick() - (PATH.newTargetAt or 0) < 0.5 then
                far = false
                diagStat("ziel_entprellt").n = diagStat("ziel_entprellt").n + 1
            end
        else
            PATH.newTarget = nil
        end

        local trig
        if not PATH.wps and age > minAge then trig = "kein_weg"
        elseif far then trig = "ziel_bewegt"
        elseif runSince > 70 and nearEnd then trig = "strecke_gelaufen"
        elseif age > 8 then trig = "alter"
        end
        if trig then
            diagStat("neu_" .. trig).n = diagStat("neu_" .. trig).n + 1
            if trig == "ziel_bewegt" and moved < 1e6 then
                diagVal("neu_ziel_bewegt", "studs", moved)
            end
        end
        if trig then
            local v = pathTarget - pos
            local cands = { pathTarget }
            local down = workspace:Raycast(pathTarget + Vector3.new(0, 4, 0), Vector3.new(0, -80, 0), AP.rp)
            if down then cands[#cands + 1] = down.Position + Vector3.new(0, 2.5, 0) end
            -- Punkt auf der EBENE des Ziels: so kommt er ueberhaupt erst nach
            -- oben, statt unter dem Gegner stehen zu bleiben.
            if math.abs(pathTarget.Y - pos.Y) > 8 then
                local bestN, bestNd
                for _, n in ipairs(NODES.list or {}) do
                    if math.abs(n.Y - pathTarget.Y) < 7 then
                        local dn = ((n - pathTarget) * Vector3.new(1, 0, 1)).Magnitude
                        if dn < 30 and (not bestNd or dn < bestNd) then bestN, bestNd = n, dn end
                    end
                end
                if bestN then table.insert(cands, 2, bestN) end
            end
            cands[#cands + 1] = pos + v * 0.65     -- nur in die Naehe ...
            cands[#cands + 1] = pos + v * 0.4      -- ... notfalls noch kuerzer
            requestPath(pos, cands)
        end
        local pdir = followPath(pos, mode)
        if pdir then
            goal = pdir
            AP.pdirDbg = pdir          -- Diagnose: was der Folger wollte
            AP.usingPath = true
        else
            AP.usingPath = false
        end
    else
        -- KEIN ZIEL GERADE? DANN DEN VORHANDENEN WEG WEITERFAHREN.
        -- Gemessen: 660 Frames ohne Weg bei nur 85 gebauten Wegen, und der
        -- haeufigste Ausloeser einer Neuberechnung war schlicht "es gibt
        -- keinen Weg". Der Kreislauf war: Ziel faellt kurz weg -> Weg
        -- wegwerfen -> naechster Frame hat keinen Weg -> neu rechnen. Ein
        -- Weg ohne aktuelles Ziel fuehrt aber immer noch irgendwohin, und
        -- das ist besser als planlos dazustehen. Weggeworfen wird er erst,
        -- wenn er abgefahren oder wirklich alt ist.
        local keep = PATH.wps and (tick() - (PATH.at or 0) < 6)
        local pdir = keep and followPath(pos, mode) or nil
        if pdir then
            goal = goal or pdir
            AP.usingPath = true
            diagStat("weg_weitergefahren").n = diagStat("weg_weitergefahren").n + 1
        else
            AP.usingPath = false
            if PATH.wps then PATH.endWhy = PATH.endWhy or "kein_ziel" end
            PATH.wps = nil
        end
    end

    -- AYIP: das Juke-Repertoire hat Vorrang vor der normalen Richtung,
    -- solange ein Manoever laeuft. Nur beim Weglaufen und Streifen —
    -- wer jagt, soll nicht vor seinem eigenen Ziel herumtanzen.
    -- Waehrend eines Sprungs nicht finten: ein Manoever in der Luft dreht den
    -- Bot von seinem Landepunkt weg.
    if goal and (mode == "FLUCHT" or mode == "STREIFEN") and not PATH.air then
        local lvl = math.clamp(CFG.ayip or 0, 0, 3)
        if lvl > 0 then
            -- Der Parameter "threat" ist nur im Fluchtzweig gesetzt; beim
            -- Streifen bleibt er leer, wodurch nie ein Manoever ausgeloest
            -- wurde. Darum den naechsten Verfolger direkt aus der Lage
            -- nehmen.
            local tp, td = nil, math.huge
            for _, t in ipairs(state.threats or {}) do
                local d = ((t.pos - pos) * Vector3.new(1, 0, 1)).Magnitude
                if d < td then tp, td = t.pos, d end
            end
            -- ACHTUNG: "threat" ist ein SPIELER-Objekt, kein Eintrag aus
            -- state.threats — ein Feld .pos gibt es daran nicht, der Zugriff
            -- wirft. Das hat assistStep in jedem Frame mit Verfolger
            -- abgebrochen, sobald AYIP eingeschaltet war (mit AYIP 0 lief der
            -- Zweig nie, deshalb ist es nie aufgefallen). Weil dabei auch
            -- RotateInMoveDirection nicht mehr gesetzt wurde, richtete sich
            -- der Charakter wieder nach der Kamera aus statt in Laufrichtung.
            if threat and threatD and threatD < td then
                local thHrp = hrpOf(threat)
                if thHrp then tp, td = thHrp.Position, threatD end
            end
            local toThreat
            if tp then
                local v = (tp - pos) * Vector3.new(1, 0, 1)
                if v.Magnitude > 0.1 then toThreat = v.Unit end
            end
            -- Abgesichert: ein Fehler in einem Manoever hat frueher den
            -- gesamten Autopilot-Schritt abgebrochen, bevor die Richtung
            -- gesetzt wurde. Die zuletzt gueltige blieb dann im Move-Hook
            -- stehen, und der Bot lief stur immer weiter geradeaus -
            -- gemessen in 91.5 Prozent der Frames mit veralteter Richtung,
            -- die aelteste 41 Sekunden alt.
            local okJ, jd = pcall(jukeStep, pos, goal, toThreat, td, lvl)
            if not okJ then
                jd = nil
                JUKE.active, AP.jukeName = nil, nil
                failNote("juke_fehler", tostring(jd))
            end
            if jd then
                goal = jd
                AP.usingPath = false
            end
        end
    end

    -- auch die Nahbereichsrichtung sichtbar machen, nicht nur geplante Wege
    pcall(visDirection, pos, (not AP.usingPath) and goal or nil)

    pcall(failTick, pos, hum, goal ~= nil)

    -- AUSBRUCH: steckt er beim Jagen in einer Kammer/Hoehle fest (kein Pfad,
    -- Luftlinie blockiert, kaum Auswege), hat das Rauskommen Vorrang vor dem
    -- Ziel — sonst rennt er dauerhaft gegen die Innenwand.
    local nowX = tick()
    if mode == "JAGD" then
        local noPath = (not PATH.wps) and (PATH.fails or 0) > 0
        local blockedNow2 = AP.blockedSince and (nowX - AP.blockedSince > 1.4)
        if AP.trapped and blockedNow2 and noPath then
            -- entprellt: hoechstens alle 4 s ein neuer Ausbruch
            if (not AP.extractUntil or nowX > AP.extractUntil)
               and nowX - (AP.extractAt or 0) > 4 then
                AP.extractUntil, AP.extractAt = nowX + 3.0, nowX
                LOG("steckt fest beim Jagen — Ausbruch aus der Kammer")
            end
        end
    end
    if AP.extractUntil and nowX < AP.extractUntil then
        -- Richtung mit den meisten Auswegen, ersatzweise zur Kartenmitte
        local bestOut, bestRoutes
        for i = 0, 11 do
            local a7 = i * (math.pi * 2 / 12)
            local d7 = Vector3.new(math.cos(a7), 0, math.sin(a7))
            local r7 = escapeRoutes(pos, d7, 20)
            if not bestRoutes or r7 > bestRoutes then bestOut, bestRoutes = d7, r7 end
        end
        local c7 = select(1, playfield())
        if c7 and (not bestRoutes or bestRoutes < 2) then
            local toC7 = (c7 - pos) * Vector3.new(1, 0, 1)
            if toC7.Magnitude > 1 then bestOut = toC7.Unit end
        end
        if bestOut then
            goal = bestOut
            mode = "RAUS"
            AP.lastDir = nil
        end
        -- wieder frei: erst nach kurzer Bestaetigung zurueck zur Jagd,
        -- sonst flackert es zwischen Ausbruch und Verfolgung
        if AP.trapped == false and bestRoutes and bestRoutes >= 4 then
            AP.freeSince = AP.freeSince or nowX
            if nowX - AP.freeSince > 0.6 then AP.extractUntil = nil end
        else
            AP.freeSince = nil
        end
    end

    local dir
    if climbGoal then
        dir = climbGoal          -- an der Leiter nicht "um das Hindernis herum"
    else
        dir = pickDirection(pos, goal, hrp.AssemblyLinearVelocity)
    end
    if not dir then AP.mode, AP.vec = nil, nil return end

    ------------------------------------------------------------------
    -- ROLLE (C): Der Roll-Baustein merkt sich den C-Druck und macht daraus
    -- beim Aufsetzen eine Rolle, wenn die Landung innerhalb 1.25 s folgt.
    -- Die Rolle erhaelt Tempo, gibt JumpPower x1.3 und geht bei gehaltenem C
    -- in einen Slide ueber. Also: kurz vor dem Aufsetzen ausloesen.
    ------------------------------------------------------------------
    do
        local hum7 = char:FindFirstChildOfClass("Humanoid")
        local vy7 = hrp.AssemblyLinearVelocity.Y
        if hum7 and vy7 < -20 and hum7.FloorMaterial == Enum.Material.Air then
            local hit7 = workspace:Raycast(pos, Vector3.new(0, -math.min(-vy7 * 0.35, 30), 0), AP.rp)
            if hit7 and tick() - (AP.rollAt or 0) > 1.0 then
                AP.rollAt = tick()
                AP.rollCount = (AP.rollCount or 0) + 1
                pcall(function() Utils.GetEvent("SlideInput"):Fire() end)
            end
        end
        -- Der Tempo-Slide ist raus. Er sollte auf gerader Strecke Tempo
        -- bringen, hielt aber zu lange an - der Slide laeuft, solange die
        -- Taste gilt, und bremst danach aus. Die Lande-Rolle oben bleibt,
        -- die ist kurz und bringt Hoehe mit.
        -- (frueher: ab 28 Studs/s alle 3.5 s ausgeloest)
    end

    -- MENSCHLICHE DREHUNG: nicht in die neue Richtung springen, sondern mit
    -- einer festen Drehrate hinueberdrehen. Schnell genug fuer harte Haken
    -- (eine 180-Grad-Kehre dauert ~0.2 s), aber mit echten Zwischenwinkeln —
    -- so sieht es aus wie eine schnelle Mausbewegung statt wie ein Teleport.
    local nowT = tick()
    local dtT = math.clamp(nowT - (AP.turnAt or nowT), 0, 0.2)
    AP.turnAt = nowT
    do
        local cur = AP.smoothDir
        if not cur or cur.Magnitude < 0.05 then
            cur = dir
        else
            local juking3 = (AP.feintUntil and nowT < AP.feintUntil)
                            or (AP.move and nowT < (AP.move.tEnd or 0))
            local ak3 = math.clamp(CFG.ankles or 3, 0, 10)
            -- Grad pro Sekunde: normal zuegig, beim Haken deutlich schneller
            local degPerSec = juking3 and (780 + ak3 * 45) or (330 + ak3 * 30)
            -- Beim Abfahren eines berechneten Weges gibt es KEINE
            -- Drehbegrenzung mehr. Sie existierte nur, damit die Bewegung
            -- menschlich aussieht — aber bei 420 Grad/s und 32 Studs/s ist
            -- der engste fahrbare Kurvenradius 4.4 Studs, waehrend die
            -- Wegpunkte im Rasterabstand von 4 bis 6 stehen. Der Bot konnte
            -- die Kurven schlicht nicht fahren, schnitt sie ab und driftete
            -- gemessen 4 bis 8 Studs neben den Weg — bei hohem Tempo mehr.
            -- Die Aufhebung gilt nur beim harten Abfahren eines Weges (Jagd).
            -- Ist der Weg nur ein Vorschlag (Weglaufen), bleibt die normale,
            -- menschlich aussehende Drehrate — es gibt dort keine engen
            -- Wegpunkte, die eine Sofortdrehung noetig machen.
            if AP.usingPath and not AP.pathLoose and not juking3 then
                degPerSec = 100000
            end
            local maxRad = math.rad(degPerSec) * dtT
            local dot = math.clamp(cur:Dot(dir), -1, 1)
            local ang = math.acos(dot)
            if ang > maxRad then
                local sgn = (cur:Cross(dir).Y >= 0) and 1 or -1
                local rotd = (CFrame.Angles(0, maxRad * sgn, 0) * cur) * Vector3.new(1, 0, 1)
                if rotd.Magnitude > 0.05 then cur = rotd.Unit else cur = dir end
            else
                cur = dir
            end
        end
        AP.smoothDir = cur
        dir = cur
    end

    -- in Kamera-Koordinaten umrechnen (so wie echter Tasten-Input aussieht)
    local rel = camY.Value:VectorToObjectSpace(dir)
    rel = Vector3.new(rel.X, 0, rel.Z)
    if rel.Magnitude < 0.05 then AP.mode, AP.vec, AP.vecWorld = nil, nil, nil return end
    AP.vec = rel.Unit
    -- zusaetzlich die Weltrichtung merken; der Move-Hook rechnet sie mit
    -- der aktuellen Kamera um, damit Mausdrehungen den Kurs nicht verbiegen
    AP.vecWorld = dir.Unit
    AP.vecAt = tick()
    AP.mode = mode

    local m = RENV.shared.multipliers
    if m then
        -- in alle Richtungen sprinten duerfen (sonst zaehlt nur "vorwaerts")
        m.RunInAllDirections = true
    end

    -- Hindernis vor der Nase oder Ziel deutlich hoeher -> springen
    -- (mit aktivem Wallrun/Klettern greift dann die Parkour-Mechanik)
    local now = tick()
    if now - AP.lastJump > 0.55 and tick() > AP.manualUntil then
        local blocked = AP.needJump or (rayClear(pos, dir, 2.4) < 0.33)
        local higher = false
        if mode == "JAGD" and prey then
            local pr = hrpOf(prey)
            higher = pr and (pr.Position.Y - pos.Y) > 4 and preyD < 22 or false
        end
        if blocked or higher then
            AP.lastJump = now
            tryJump()
        end
    end
end

------------------------------------------------------------------
-- 4) Der eigentliche Assist (laeuft jeden Frame vor der Bewegung)
------------------------------------------------------------------
ENV.cfg = CFG

-- weiche Rampe: 0 weit weg -> 1 direkt daneben, quadratisch = spaet spuerbar
local function ramp(d, radius)
    if not d or d >= radius then return 0 end
    local t = (radius - d) / radius
    return t * t
end

-- Flachere Rampe fuer die Flucht: schon auf Distanz ein spuerbarer Anteil,
-- damit bei Lag ueberhaupt erst Abstand entsteht (statt erst kurz vor dem Tag).
local function rampSoft(d, radius)
    if not d or d >= radius then return 0 end
    local t = (radius - d) / radius
    return t ^ 1.25
end

local function lerp(a, b, f) return a + (b - a) * math.min(f, 1) end

-- Ergebnismessung fortschreiben. Laeuft jeden Frame mit, kostet nichts
-- ausser ein paar Zahlen.
local function survTick(dt, mode, threatD)
    if not SURV.on then return end
    local now = tick()
    -- Rolle beobachten: ein Wechsel mitten in der Runde heisst gefangen
    local r = myRole()
    if SURV.role and r and r ~= SURV.role and inLiveRound() then
        local streak = now - SURV.lastTag
        if streak > SURV.bestStreak then SURV.bestStreak = streak end
        SURV.tags = SURV.tags + 1
        SURV.lastTag = now
        if SURV.close then
            SURV.caught = SURV.caught + 1
            SURV.close = nil
        end
        diagEvent("gefangen", ("%.0f"):format(streak), SURV.tags, "",
                  ("beste=%.0f"):format(SURV.bestStreak))
        LOG(("GEFANGEN nach %.0f s (%d insgesamt, beste Serie %.0f s)")
            :format(streak, SURV.tags, SURV.bestStreak))
    end
    SURV.role = r

    if mode ~= "FLUCHT" or not threatD then
        SURV.close = nil
        return
    end
    SURV.fleeTime = SURV.fleeTime + dt
    if threatD < 12 then SURV.dangerTime = SURV.dangerTime + dt end
    if now - SURV.sampleAt > 0.25 then
        SURV.sampleAt = now
        SURV.dSum, SURV.dN = SURV.dSum + threatD, SURV.dN + 1
        if threatD < SURV.dMin then SURV.dMin = threatD end
    end
    -- AUSBRUCH: kommt einer auf acht Studs heran und ist vier Sekunden
    -- spaeter ueber 25 Studs weg, war es ein gewonnener Zweikampf.
    if not SURV.close and threatD < 8 then
        SURV.close = { at = now, d0 = threatD, used = {} }
    elseif SURV.close then
        if AP.usingPath and PATH.wps and PATH.wps[PATH.idx] then
            local k = PATH.wps[PATH.idx].kind
            if k then SURV.close.used[k] = true end
        end
        if threatD > 25 then
            SURV.escapes = SURV.escapes + 1
            local tags = {}
            for k in pairs(SURV.close.used) do
                tags[#tags + 1] = k
                SURV.used[k] = (SURV.used[k] or 0) + 1
            end
            diagEvent("ausbruch", ("%.1f"):format(now - SURV.close.at),
                      ("%.0f"):format(SURV.close.d0), ("%.0f"):format(threatD),
                      "benutzt=" .. table.concat(tags, ","))
            LOG(("ABGESCHUETTELT nach %.1f s (von %.0f auf %.0f Studs)%s")
                :format(now - SURV.close.at, SURV.close.d0, threatD,
                        #tags > 0 and ("  benutzt: " .. table.concat(tags, ",")) or ""))
            SURV.close = nil
        elseif now - SURV.close.at > 12 then
            SURV.close = nil
        end
    end
end

function ENV.survival()
    local now = tick()
    local out = { "=== WIE SCHWER ZU FANGEN " .. os.date("%H:%M:%S") .. " ===" }
    local fm = SURV.fleeTime / 60
    out[#out + 1] = ("Fluchtzeit gesamt        %.1f min"):format(fm)
    out[#out + 1] = ("Gefangen                 %dx  (%.2f je Minute Flucht)")
        :format(SURV.tags, fm > 0.01 and SURV.tags / fm or 0)
    out[#out + 1] = ("laufende Serie           %.0f s   (beste %.0f s)")
        :format(now - SURV.lastTag, SURV.bestStreak)
    out[#out + 1] = ("Gefahrzeit unter 12 Studs %.0f %% der Fluchtzeit")
        :format(SURV.fleeTime > 0 and SURV.dangerTime * 100 / SURV.fleeTime or 0)
    out[#out + 1] = ("Verfolgerabstand          Schnitt %.1f, engster %.1f Studs")
        :format(SURV.dN > 0 and SURV.dSum / SURV.dN or 0,
                SURV.dMin < 1e9 and SURV.dMin or 0)
    out[#out + 1] = ("Zweikaempfe               %d abgeschuettelt, %d verloren (%d %% gewonnen)")
        :format(SURV.escapes, SURV.caught,
                (SURV.escapes + SURV.caught) > 0
                    and math.floor(SURV.escapes * 100 / (SURV.escapes + SURV.caught)) or 0)
    local u = {}
    for k, v in pairs(SURV.used) do u[#u + 1] = ("%s=%d"):format(k, v) end
    table.sort(u)
    out[#out + 1] = "bei Ausbruechen benutzt   " .. (#u > 0 and table.concat(u, "  ") or "nur Gehen")
    local txt = table.concat(out, string.char(10))
    DIAG.ring[#DIAG.ring + 1] = txt
    DIAG.dirty = true
    diagFlush(true)
    return txt
end

function ENV.survReset()
    SURV.fleeTime, SURV.dangerTime = 0, 0
    SURV.dSum, SURV.dN, SURV.dMin = 0, 0, 1e9
    SURV.tags, SURV.lastTag, SURV.bestStreak = 0, tick(), 0
    SURV.escapes, SURV.caught, SURV.used, SURV.close = 0, 0, {}, nil
    return "Ergebnismessung zurueckgesetzt"
end

local function assistStep(dt)
    local S = RENV.shared
    local m = S.multipliers
    if not (m and S.boosts) then return end

    local threat, threatD, prey, preyD = scanField()
    pcall(survTick, dt, AP.mode, threatD)
    state.threatD, state.preyD = threatD, preyD
    local p = P()

    ---------------------------------------------------------------
    -- A) WEGLAUFEN: Naehe-Boost ueber das spieleigene Boost-System
    ---------------------------------------------------------------
    local wantSpeed, wantAccel, wantJump = 1, 1, 1
    if CFG.escape and threatD then
        local r = rampSoft(threatD, p.escRadius)
        wantSpeed = 1 + p.escBoost * r
        wantAccel = lerp(1, p.escAccel, r)
        wantJump  = lerp(1, p.escJump,  r)
    end
    -- B) JAGEN: gleiches Prinzip, wenn ich der Faenger bin
    if CFG.chase and preyD then
        -- Im Chase wirkt der Boost auch auf Distanz (Grundanteil), damit weite
        -- Verfolgungen ueberhaupt aufholen; nah dran kommt der Rest dazu.
        local r = ramp(preyD, p.chsRadius)
        -- Grundanteil beim Jagen gesenkt (0.7 -> 0.5): zusammen mit dem
        -- halbierten Jagd-Boost lag die Spitze sonst bei WalkSpeed 42 bis 47,
        -- waehrend auf der Flucht bewusst bei 37 gedeckelt wird. Jagen soll
        -- nicht auffaelliger sein als Weglaufen.
        local base = (AP.mode == "JAGD") and 0.5 or 0   -- auch auf Distanz Tempo
        local f = math.min(base + (1 - base) * r, 1)
        local sp = 1 + p.chsBoost * f
        if sp > wantSpeed then wantSpeed, wantAccel = sp, lerp(1, p.escAccel, f) end
    end

    -- OHNE AYIP UND OHNE NAHEN VERFOLGER: hoechstens +7 Prozent.
    -- Tempo faellt vor allem dann auf, wenn gar kein Grund dafuer zu sehen
    -- ist — laeuft niemand in der Naehe, wirkt ein schneller Laeufer sofort
    -- verdaechtig. Nah dran bleibt die volle Rampe, da rettet sie den Fang.
    if (CFG.ayip or 0) == 0 and (not threatD or threatD > 25) then
        wantSpeed = math.min(wantSpeed, 1.07)
    end

    -- GEGENSEITIGE MODI (FFA Royal, Slasher, Team): dort ist man gleichzeitig
    -- Jaeger und Gejagter, also greifen Flucht- und Jagdboost abwechselnd und
    -- praktisch dauerhaft. Genau dort faellt Tempo am meisten auf, weil alle
    -- dieselbe Rolle haben und direkt vergleichbar sind. Deshalb hier ein
    -- harter Deckel von +6 % statt der sonst moeglichen +15 %.
    if (state.nThreat or 0) > 0 and (state.nPrey or 0) > 0 then
        wantSpeed = math.min(wantSpeed, 1.06)
        wantAccel = math.min(wantAccel, 1.25)
    end

    -- Auf einem geplanten Weg zaehlt vor allem, die vorgegebene Richtung
    -- SCHNELL einzunehmen. Gemessen lag die Steuerungskette bei 2.7 Grad
    -- Abweichung, die tatsaechlich gefahrene Richtung aber 27.5 Grad
    -- daneben — die Traegheit war also der ganze Fehler. Beschleunigung
    -- wurde bisher nur bei nahem Verfolger angehoben.
    if AP.usingPath then
        -- 2.2 war zu hastig und liess das Tempo sichtbar rampen. 1.5 reicht,
        -- um die vorgegebene Richtung zuegig einzunehmen.
        wantAccel = math.max(wantAccel, 1.5)
        -- VOR KRITISCHEN PUNKTEN ABBREMSEN. Leiter, Sprung, Zipline,
        -- Jumppad und Durchgaenge muessen genau getroffen werden - bei
        -- 32 Studs/s legt er pro Frame einen halben Stud zurueck und
        -- schiesst darueber hinaus. Genau diese Punkte tragen aber die
        -- guten Routen: wer sie verfehlt, faellt auf den Fussweg zurueck.
        -- HIER STAND DER FEHLER, DER DEN BOT KOMPLETT ANGEHALTEN HAT:
        -- "pos" ist in dieser Funktion nicht definiert (das ist eine lokale
        -- Variable von autopilotStep). Der Zugriff lief also auf einen
        -- globalen nil-Wert, die Rechnung warf einen Fehler, und weil
        -- assistStep im pcall der Renderstufe haengt, brach damit JEDER
        -- Frame ab — noch bevor autopilotStep ueberhaupt aufgerufen wurde.
        -- Zusammen mit dem Verfallsdatum der Richtung im Move-Hook (0.4 s)
        -- heisst das: der Autopilot bewegt den Charakter gar nicht mehr.
        local hrpS = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
        local posS = hrpS and hrpS.Position
        -- VOR GENAUEN PUNKTEN WIRD GEBREMST — AUCH BEIM WEGLAUFEN.
        -- Gemessen an 9 Leiteranlaeufen: in allen Fehlversuchen kam er mit
        -- 32 bis 35 Studs/s an, blieb 0.0 bis 0.4 s im Greifbereich und
        -- shared.touchingTruss wurde kein einziges Mal gesetzt. Der eine
        -- saubere Aufstieg lief mit 14 Studs/s. Das Spiel prueft den Truss
        -- mit einem Strahl aus der Blickrichtung auf 6 Studs — bei 34
        -- Studs/s ist dieses Fenster in 90 Millisekunden durchquert.
        -- Der Tempoverlust vor dem Verfolger ist der Preis dafuer, dass die
        -- Leiter ueberhaupt genommen wird; oben ist man ohnehin sicherer.
        local pw = PATH.wps and PATH.wps[PATH.idx] or nil
        if pw and posS then
            local k = pw.kind
            -- "jump" ist hier bewusst NICHT dabei. Die Sprungkante braucht
            -- das volle Tempo: der Bogen ist mit prof.speed (32) geplant,
            -- mit halbem Tempo traegt er statt 25 nur noch 11 Studs weit.
            if pw.takeoff then
                -- Absprung: gar keine Bremse, sondern Vollgas.
            elseif k == "climb" then
                -- Leitern besonders frueh und deutlich: ab 16 Studs
                -- herunterregeln, im Greifbereich auf gut ein Drittel.
                local d = ((pw.Position - posS) * Vector3.new(1, 0, 1)).Magnitude
                if d < 16 then
                    wantSpeed = math.min(wantSpeed, math.clamp(d / 16, 0.36, 1))
                    wantAccel = math.min(wantAccel, 1.1)
                end
            elseif AP.ladder and AP.ladder.Parent
                   and ((AP.ladder.Position - posS) * Vector3.new(1, 0, 1)).Magnitude < 12 then
                -- Leiter angesteuert, ohne dass der Wegpunkt selbst vom Typ
                -- climb ist: zwei der drei gemessenen Fehlversuche liefen
                -- genau so, mit 27 bis 37 Studs/s ungebremst vorbei.
                wantSpeed = math.min(wantSpeed, 0.42)
                wantAccel = math.min(wantAccel, 1.1)
            elseif k == "zip" or k == "pad" or k == "via" then
                local d = ((pw.Position - posS) * Vector3.new(1, 0, 1)).Magnitude
                if d < 14 then
                    -- weich herunterregeln statt abrupt bremsen
                    local f = math.clamp(d / 14, 0.45, 1)
                    wantSpeed = math.min(wantSpeed, f)
                end
            end
        end
    end

    -- weich nachziehen, damit kein sichtbarer Speed-Sprung entsteht
    state.speedMul = lerp(state.speedMul, wantSpeed, dt * 6)
    if math.abs(state.speedMul - 1) < 0.004 and wantAccel <= 1.01 then
        state.speedMul = 1
        S.boosts.__utg = nil
    else
        S.boosts.__utg = { Speed = state.speedMul, Accel = wantAccel, Jump = wantJump }
    end
    -- Waehrend einer Finte zusaetzlich Tempo geben: das Manoever soll den
    -- Verfolger abhaengen, und der Umweg, den ein Bogen kostet, muss
    -- wieder hereingeholt werden. Eigener Boost-Eintrag, damit er den
    -- normalen nicht ueberschreibt und mit dem Manoever endet.
    if S.boosts then
        if AP.jukeName then
            -- Waehrend eines Manoevers einen Tick mehr Tempo (1.18 -> 1.25,
            -- Nutzer-Vorgabe): der Bogen kostet Strecke, und genau in diesen
            -- knapp zwei Sekunden entscheidet sich, ob der Verfolger
            -- aufschliesst. Mehr Beschleunigung dazu, damit die neue Richtung
            -- schnell anliegt.
            local mut = (state.nThreat or 0) > 0 and (state.nPrey or 0) > 0
            S.boosts.__utgjuke = { Speed = mut and 1.08 or 1.25,
                                   Accel = mut and 1.3 or 1.6, Jump = 1 }
        else
            S.boosts.__utgjuke = nil
        end
    end

    ---------------------------------------------------------------
    -- C) FANGEN: Reichweite + Trefferkegel weich hochfahren
    ---------------------------------------------------------------
    local wantReach, wantSpread = 7, 1
    if CFG.chase and preyD then
        -- In gegenseitigen Modi (FFA Royal, Slasher, Team) faellt lange
        -- Reichweite auf, weil dort auf Tuchfuehlung gekaempft wird. Dort
        -- wird der Deckel deutlich niedriger angesetzt.
        -- volle Reichweite in allen Modi (die Kappung fuer FFA Royal ist raus)
        local rMax, sMax, rFrom = p.reachMax, p.spreadMax, p.reachFrom
        if preyD <= rFrom then
            wantReach = math.clamp(preyD + 1.5, 7, math.max(rMax, 7))
            local r = ramp(preyD, rFrom)
            wantSpread = lerp(1, sMax, r)
        end
    end
    state.reach  = lerp(state.reach,  wantReach,  dt * 10)
    state.spread = lerp(state.spread, wantSpread, dt * 10)
    m.RangeMultiplier = state.reach / 7
    m.TagRaySpread    = state.spread
    if CFG.chase and p.cdMul < 1 then
        m.TagCooldown = (m.TagCooldown or 0.6) * p.cdMul
    end

    ---------------------------------------------------------------
    -- D) PARKOUR: Mechaniken freischalten / leicht tunen
    ---------------------------------------------------------------
    if CFG.parkour then
        -- WALLRIDE BLEIBT IM UNFANGBAR-MODUS AUS (Nutzer-Vorgabe).
        -- Mit AYIP aus soll die Unfangbarkeit allein aus der Route kommen,
        -- nicht aus einer Mechanik, die ohne den Schalter gar nicht ginge.
        m.EnableWallrunning    = (CFG.ayip or 0) > 0
        m.EnableTictacs        = true
        m.DisableWallClimbs    = false
        m.DisableVaulting      = false
        m.DisableSliding       = false
        m.DisableRolling       = false
        m.DisableRailGrinding  = false
        m.DisableRopeSwinging  = false
        m.DisableSwingBars     = false
        m.DisableZipLining     = false
        m.DisableTightropes    = false
        m.DisableWindowSmashing= false
        -- Klettern/Vaulten: der Vault gibt Aufwaerts-Impuls (Hoehe/1.5*30) und
        -- Momentum (3 x VaultMomentumMultiplier). Ketten-Vaults innerhalb 0.5 s
        -- stapeln zusaetzlich — mit vollem Stacking-Faktor wird daraus eine
        -- echte Kletterkette statt Einzelsprung.
        m.WallclimbMultiplier  = 2.6
        m.WallrunCooldown      = 0.12
        m.VaultCooldown        = 0.04
        m.VaultMomentumMultiplier = 2.4
        m.VaultStackingMomentumMultiplier = 1.0
        m.SlopesMultiplier     = 1.4
        m.SlideSpeedMultiplier = 1 + p.escBoost
        m.SlideLengthMultiplier= 1 + p.escBoost
        m.RollBoostMultiplier  = 1 + p.escBoost
        m.MomentumMultiplier   = 1 + p.escBoost * 0.6
        m.MomentumSpeed        = 1 + p.escBoost * 0.4
        m.GravityMultiplier    = p.gravity
    end

    ---------------------------------------------------------------
    -- D2) AUTOPILOT: weglaufen / verfolgen
    ---------------------------------------------------------------
    -- Vermessungen laufen asynchron und unabhaengig vom Modus, damit sie
    -- fertig sind, bevor die erste Flucht kommt
    if not state.surveyAt or tick() - state.surveyAt > 3 then
        state.surveyAt = tick()
        mapCenterRadius()
        buildNodes()
        helpers()
        ladders()
        ensureGraph()
    end

    -- Anzeige-Flags gehoeren zum Fluchtzweig; ohne Ruecksetzen bleiben sie
    -- nach dem Moduswechsel stehen und die Statuszeile luegt.
    if AP.mode ~= "FLUCHT" then AP.helper, AP.grabbing = nil, false end

    -- Die Kletter-Ausrichtung schaltet die Drehung in Laufrichtung ab. Das Flag
    -- wird JEDEN Frame geloescht und nur von climbStep neu gesetzt — sonst
    -- bleibt es nach dem Klettern haengen und der Charakter schaut dauerhaft
    -- in Kamerarichtung statt in Laufrichtung.
    AP.climbRotating = false

    -- ABGESICHERT. Ein Fehler im Autopilotschritt darf nicht verhindern, dass
    -- die Grundeinstellungen darunter gesetzt werden — die Drehung in
    -- Laufrichtung steht drei Zeilen weiter. Genau daran hing die
    -- "Kamerakopplung": ein einziger fehlerhafter Feldzugriff brach den
    -- Schritt jeden Frame ab, RotateInMoveDirection blieb aus, und der
    -- Charakter richtete sich wieder nach der Kamera aus.
    local okAP, errAP = pcall(autopilotStep, threat, threatD, prey, preyD)
    if not okAP then
        AP.stepFails = (AP.stepFails or 0) + 1
        if AP.stepFails % 120 == 1 then
            LOG("FEHLER autopilotStep: " .. tostring(errAP))
        end
    end
    -- Seitwaerts-/Rueckwaerts-Sprint nur waehrend der Autopilot wirklich faehrt
    if not AP.mode then m.RunInAllDirections = false end
    -- Charakter schaut immer in die Laufrichtung, die Kamera bleibt frei drehbar
    -- (spieleigener Schalter — kein CFrame-Gefummel, Taggen zielt weiter per Kamera)
    m.RotateInMoveDirection = (not AP.climbRotating) and CFG.faceRun or false

    ---------------------------------------------------------------
    -- E) AUTO-TAG: nur wenn Ziel wirklich vor mir und in Reichweite
    ---------------------------------------------------------------
    -- Stand von vor der Reichweiten-Reduktion: nur Distanz, Cooldown und
    -- Blickrichtung. KEINE NoTagBack-Pruefung (die hat 253x blockiert und
    -- damit jeden Tag verhindert), keine Sichtlinien-/Sichtfeld-Sperre.
    if CFG.autotag and not AP.immobile and prey and preyD and preyD <= state.reach then
        local now = tick()
        local cd = (S.cooldowns and S.cooldowns.Tag or 0)
        if now - state.lastTag > (AP.duel and 0.12 or 0.25)
           and now >= (state.nextTagAt or 0)
           and not (cd > time()) then
            local cam = workspace.CurrentCamera
            local h = hrpOf(prey)
            if cam and h then
                local dir = (h.Position - cam.CFrame.Position).Unit
                if dir:Dot(cam.CFrame.LookVector) > (AP.duel and 0.3 or 0.55) then
                    state.lastTag = now
                    task.delay(AP.duel and 0.03 or (0.08 + math.random() * 0.1), function()
                        ENV.fireTag(prey, preyD)
                    end)
                end
            end
        end
    end
end

------------------------------------------------------------------
-- 5) Tag ausloesen — bevorzugt ueber den spieleigenen Tag-Button,
--    damit Animation/Sound/Cooldown exakt wie normal laufen.
------------------------------------------------------------------
local TagPlayerRemote = Utils.GetEvent("TagPlayer")
local SoundEvent      = Utils.GetEvent("SoundEvent")
local AnimateEvent    = Utils.GetEvent("AnimateEvent")
local TagSwing        = Utils.GetEvent("TagSwing")

local function nativeTagButton()
    local gui = LP:FindFirstChild("PlayerGui")
    local t = gui and gui:FindFirstChild("TouchGuiUTG")
    local b = t and t:FindFirstChild("UTGButtons")
    return b and b:FindFirstChild("TagButton")
end

-- Beim Taggen zum Ziel schauen. Die Kamera-Gierachse liegt in
-- values.CameraY (reine Rotation) und wird vom Spiel fortgeschrieben — ein
-- weiches Hinueberziehen sieht aus wie eine normale Mausbewegung.
local function faceTarget(target, dur)
    local char = LP.Character
    local vals = char and char:FindFirstChild("values")
    local camY = vals and vals:FindFirstChild("CameraY")
    local me, th = hrpOf(LP), hrpOf(target)
    if not (camY and me and th) then return end
    local flat = (th.Position - me.Position) * Vector3.new(1, 0, 1)
    if flat.Magnitude < 0.5 then return end
    local goalCF = CFrame.lookAt(Vector3.zero, flat.Unit)
    task.spawn(function()
        local t0 = tick()
        while tick() - t0 < (dur or 0.16) do
            local okC = pcall(function()
                camY.Value = camY.Value:Lerp(goalCF, 0.35)
            end)
            if not okC then break end
            task.wait()
        end
    end)
end

function ENV.fireTag(target, dist)
    -- Das Remote yieldet. Ohne diese Sperre feuert der naechste Versuch waehrend
    -- der Server noch antwortet — genau daher die Kette "angenommen, dann sofort
    -- zweimal abgelehnt".
    -- Wachhund: bleibt die Sperre haengen (Fehler mitten im Ablauf), waere
    -- danach NIE wieder ein Tag moeglich. Nach 2 s wird sie zwangsweise frei.
    if state.tagPending then
        if state.tagPendingAt and tick() - state.tagPendingAt > 2 then
            state.tagPending = false
            LOG("Tag-Sperre haing fest — automatisch geloest")
        else
            return false
        end
    end

    state.tagPending, state.tagPendingAt = true, tick()
    state.nextTagAt = tick() + (state.learnedCd or 0.9)   -- vorsorglich sperren
    -- WICHTIG: Der spieleigene Tag-Button zielt ueber die KAMERA. Beim Autopilot
    -- schaut die Kamera aber selten genau auf das Ziel, dann findet die
    -- Spiel-Logik gar niemanden. Deshalb wird das Remote direkt mit der
    -- Ziel-ID geschickt (Server akzeptiert das bis ~30 Studs) und die
    -- Effekte lokal nachgezogen.
    -- Serial-ID des Ziels. getPlayer() liefert nicht immer etwas (z.B. bei
    -- spaet beigetretenen Spielern) — dann wird das Attribut serialID benutzt,
    -- das jeder Spieler ohnehin traegt. Frueher brach die Funktion hier
    -- LAUTLOS ab: kein Tag, kein Zaehler, kein Logeintrag.
    local serial = SerialisedData.getPlayer(target)
    if not serial then
        local attr = target:GetAttribute("serialID")
        if typeof(attr) == "number" then serial = attr end
    end
    local me = hrpOf(LP)
    local h = hrpOf(target)
    if not (serial and me and h) then
        state.tagPending = false
        state.nextTagAt = 0
        state.tagsNoSerial = (state.tagsNoSerial or 0) + 1
        if (state.tagsNoSerial % 5) == 1 then
            LOG(("Tag nicht moeglich: keine Serial-ID fuer %s (%dx)")
                :format(target.Name, state.tagsNoSerial))
        end
        return false
    end
    local camCF = CFrame.lookAt(me.Position + Vector3.new(0, 1.5, 0), h.Position)
    local b = buffer.create(7)
    buffer.writeu8(b, 0, serial)
    local x, y, z = camCF:ToEulerAnglesYXZ()
    buffer.writeu16(b, 1, math.floor((x + math.pi) / (2 * math.pi) * 65535 + 0.5))
    buffer.writeu16(b, 3, math.floor((y + math.pi) / (2 * math.pi) * 65535 + 0.5))
    buffer.writeu16(b, 5, math.floor((z + math.pi) / (2 * math.pi) * 65535 + 0.5))
    pcall(function() SoundEvent:Fire("Tag", me, 0.25, true) end)
    pcall(function() AnimateEvent:Fire("Tag", 0.1, 1) end)
    pcall(function() TagSwing:Fire() end)
    pcall(function() Utils.ApplyCooldown("Tag") end)
    local ok, res = pcall(function() return TagPlayerRemote:InvokeServer(b) end)
    local landed = ok and res and true or false
    if landed then
        state.tagsOk = (state.tagsOk or 0) + 1
        -- Der Server hat einen eigenen Cooldown. Statt ihn zu raten, wird er
        -- eingemessen: kam der Treffer im ersten Versuch nach der Wartezeit,
        -- wird die Wartezeit langsam verkuerzt; brauchte es Fehlversuche,
        -- wird sie verlaengert. So stellt sich der Wert je Rolle selbst ein.
        if (state.tagMissRun or 0) == 0 then
            state.learnedCd = math.max((state.learnedCd or 0.9) * 0.97, 0.45)
        end
        state.tagMissRun = 0
        state.nextTagAt = tick() + (state.learnedCd or 0.9)
    else
        state.tagsMiss = (state.tagsMiss or 0) + 1
        state.tagMissRun = (state.tagMissRun or 0) + 1
        -- abgelehnt: Wartezeit nach oben korrigieren und gestaffelt zurueckhalten
        state.learnedCd = math.min((state.learnedCd or 0.9) + 0.2, 3.0)
        local wait = math.min(0.3 * state.tagMissRun, 1.2)
        state.nextTagAt = tick() + wait
    end
    LOG(("AutoTag -> %s  %.1f Studs  %s  (Treffer %d / abgelehnt %d, Cooldown %.2fs)")
        :format(target.Name, dist, landed and "ANGENOMMEN" or "abgelehnt",
                state.tagsOk or 0, state.tagsMiss or 0, state.learnedCd or 0))
    state.tagPending = false
    -- Notnagel: wenn der Server ablehnt, zusaetzlich den nativen Weg probieren
    if not landed then
        local btn = nativeTagButton()
        if btn and getconnections then
            for _, c in ipairs(getconnections(btn.Activated)) do
                if c.Function then task.spawn(c.Function) end
            end
        end
    end
    return landed
end

------------------------------------------------------------------
-- 5b) 3RD PERSON (Taste T)
--     Eigener RenderStep NACH dem Spiel-Kamerascript, damit unsere CFrame
--     gewinnt. Steuerung und Zielrichtung bleiben unveraendert.
------------------------------------------------------------------
local TP = { dist = 12, min = 4, max = 26 }
ENV.tp = TP
local TP_STEP = "UTG_ThirdPerson_Step"

local function thirdStart()
    RunService:BindToRenderStep(TP_STEP, Enum.RenderPriority.Camera.Value + 20, function()
        if not CFG.thirdPerson then return end
        local cam = workspace.CurrentCamera
        local char = LP.Character
        local head = char and (char:FindFirstChild("Head") or char:FindFirstChild("HumanoidRootPart"))
        if not (cam and head) then return end

        -- Blickrichtung kommt weiter vom Spiel (Zielen/Taggen bleibt gleich),
        -- die Kamera wird nur nach hinten herausgezogen
        local rot = cam.CFrame.Rotation
        local origin = head.Position + Vector3.new(0, 0.8, 0)
        local back = -rot.LookVector

        local rp = RaycastParams.new()
        rp.FilterType = Enum.RaycastFilterType.Exclude
        rp.RespectCanCollide = true
        local ig = { cam }
        for _, pl in ipairs(Players:GetPlayers()) do
            if pl.Character then ig[#ig + 1] = pl.Character end
        end
        rp.FilterDescendantsInstances = ig

        local d = TP.dist
        local hit = workspace:Raycast(origin, back * (d + 1.5), rp)
        if hit then d = math.max((hit.Position - origin).Magnitude - 1.2, 1.5) end

        cam.CFrame = CFrame.new(origin + back * d) * rot

        -- eigenen Koerper sichtbar machen (im Ego-Modus blendet das Spiel ihn aus)
        for _, part in ipairs(char:GetChildren()) do
            if part:IsA("BasePart") and part.LocalTransparencyModifier > 0 then
                part.LocalTransparencyModifier = 0
            elseif part:IsA("Accessory") then
                local h = part:FindFirstChild("Handle")
                if h and h.LocalTransparencyModifier > 0 then h.LocalTransparencyModifier = 0 end
            end
        end
    end)
    LOG("3rd Person AN")
end

local function thirdStop()
    pcall(function() RunService:UnbindFromRenderStep(TP_STEP) end)
    -- Die Kamera zurueckgeben: der Modus setzt sie auf Scriptable, und
    -- ohne Ruecksetzen bleibt sie daran haengen. Sie folgt dann weiter dem
    -- Charakter und laesst sich nicht mehr frei drehen - genau das war als
    -- "Kamera ist an den Spieler gekoppelt" sichtbar.
    pcall(function()
        local cam = workspace.CurrentCamera
        if cam then
            cam.CameraType = Enum.CameraType.Custom
            local ch = LP.Character
            local h = ch and ch:FindFirstChildOfClass("Humanoid")
            if h then cam.CameraSubject = h end
        end
    end)
    LOG("3rd Person AUS")
end

-- Klettertest von aussen ausloesbar
function ENV.testClimb(sec)
    AP.forceClimbUntil = tick() + (sec or 12)
    LOG("Klettertest gestartet")
end

function ENV.toggleThird()
    CFG.thirdPerson = not CFG.thirdPerson
    if CFG.thirdPerson then thirdStart() else thirdStop() end
    return CFG.thirdPerson
end

------------------------------------------------------------------
-- 6) GUI
------------------------------------------------------------------
local parentGui = (gethui and gethui()) or LP:WaitForChild("PlayerGui")
for _, g in ipairs(parentGui:GetChildren()) do
    if g.Name == "UTG_TagAssist" then g:Destroy() end
end

local sg = Instance.new("ScreenGui")
sg.Name = "UTG_TagAssist"
sg.ResetOnSpawn = false
sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
sg.Parent = parentGui

local main = Instance.new("Frame")
main.Size = UDim2.fromOffset(250, 302)
main.Position = UDim2.new(0, 18, 0.5, -151)
main.BackgroundColor3 = Color3.fromRGB(18, 18, 22)
main.BorderSizePixel = 0
main.Parent = sg
Instance.new("UICorner", main).CornerRadius = UDim.new(0, 8)
local stroke = Instance.new("UIStroke", main)
stroke.Color = Color3.fromRGB(70, 120, 90)
stroke.Thickness = 1

local header = Instance.new("TextLabel")
header.Size = UDim2.new(1, 0, 0, 30)
header.BackgroundColor3 = Color3.fromRGB(28, 34, 30)
header.BorderSizePixel = 0
header.Text = "  TAG ASSIST"
header.TextXAlignment = Enum.TextXAlignment.Left
header.TextColor3 = Color3.fromRGB(120, 230, 160)
header.Font = Enum.Font.GothamBold
header.TextSize = 13
header.Parent = main
Instance.new("UICorner", header).CornerRadius = UDim.new(0, 8)

-- ziehbar
do
    local dragging, dragStart, startPos
    header.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
            dragging, dragStart, startPos = true, i.Position, main.Position
        end
    end)
    header.InputEnded:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)
    UserInputService.InputChanged:Connect(function(i)
        if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
            local d = i.Position - dragStart
            main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
        end
    end)
end

local y = 38
-- Schieberegler (klicken oder ziehen)
local function makeSlider(label, minV, maxV, getter, setter, fmt)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, -16, 0, 30)
    row.Position = UDim2.new(0, 8, 0, y)
    row.BackgroundColor3 = Color3.fromRGB(32, 32, 38)
    row.BorderSizePixel = 0
    row.Parent = main
    Instance.new("UICorner", row).CornerRadius = UDim.new(0, 6)
    y = y + 34

    local fill = Instance.new("Frame")
    fill.BackgroundColor3 = Color3.fromRGB(38, 78, 96)
    fill.BorderSizePixel = 0
    fill.Parent = row
    Instance.new("UICorner", fill).CornerRadius = UDim.new(0, 6)

    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(1, 0, 1, 0)
    lbl.BackgroundTransparency = 1
    lbl.Font = Enum.Font.Gotham
    lbl.TextSize = 12
    lbl.TextColor3 = Color3.fromRGB(215, 235, 240)
    lbl.Parent = row

    local function refresh()
        local v = getter()
        fill.Size = UDim2.new((v - minV) / math.max(maxV - minV, 0.001), 0, 1, 0)
        lbl.Text = (fmt or "%s  %d"):format(label, v)
    end
    local dragging = false
    local function setFromX(px)
        local rel = (px - row.AbsolutePosition.X) / math.max(row.AbsoluteSize.X, 1)
        setter(math.clamp(math.floor(minV + rel * (maxV - minV) + 0.5), minV, maxV))
        refresh()
    end
    row.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1
           or i.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            task.spawn(function() setFromX(i.Position.X) end)
        end
    end)
    row.InputEnded:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1
           or i.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)
    conns[#conns + 1] = UserInputService.InputChanged:Connect(function(i)
        if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement
                         or i.UserInputType == Enum.UserInputType.Touch) then
            setFromX(i.Position.X)
        end
    end)
    refresh()
    return refresh
end

local function makeButton(text, getter, onClick)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(1, -16, 0, 28)
    b.Position = UDim2.new(0, 8, 0, y)
    b.BackgroundColor3 = Color3.fromRGB(32, 32, 38)
    b.BorderSizePixel = 0
    b.Font = Enum.Font.Gotham
    b.TextSize = 12
    b.TextColor3 = Color3.fromRGB(230, 230, 230)
    b.AutoButtonColor = true
    b.Parent = main
    Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
    y = y + 32
    local function refresh()
        local on = getter()
        b.Text = text .. "   " .. (on and "AN" or "AUS")
        b.BackgroundColor3 = on and Color3.fromRGB(28, 62, 40) or Color3.fromRGB(40, 28, 30)
        b.TextColor3 = on and Color3.fromRGB(150, 245, 180) or Color3.fromRGB(215, 150, 150)
    end
    b.Activated:Connect(function()
        task.spawn(function()      -- getconnections/Handler nie blockieren
            onClick()
            refresh()
        end)
    end)
    refresh()
    return b, refresh
end

local rFree

-- EIN Schalter fuer das komplette Spielverhalten
local _, rAuto = makeButton("Autopilot (alles)", function() return CFG.autopilot end,
    function()
        CFG.autopilot = not CFG.autopilot
        if ENV.saveSettings then ENV.saveSettings() end
        if not CFG.autopilot then
            AP.mode, AP.vec, AP.move = nil, nil, nil
            local m = RENV.shared.multipliers
            if m then
                m.RangeMultiplier, m.TagRaySpread = 1, 1
                m.RotateInMoveDirection, m.RunInAllDirections = false, false
            end
            if RENV.shared.boosts then
                RENV.shared.boosts.__utg = nil
                RENV.shared.boosts.__utgjuke = nil
            end
        end
    end)

-- AYIP: 3 Stufen Juke-Aggressivitaet (frueher Ankles 6 / 8 / 10)
local ayipBtn = Instance.new("TextButton")
ayipBtn.Size = UDim2.new(1, -16, 0, 30)
ayipBtn.Position = UDim2.new(0, 8, 0, y)
ayipBtn.BackgroundColor3 = Color3.fromRGB(58, 34, 76)
ayipBtn.BorderSizePixel = 0
ayipBtn.Font = Enum.Font.GothamBold
ayipBtn.TextSize = 12
ayipBtn.TextColor3 = Color3.fromRGB(226, 198, 250)
ayipBtn.Parent = main
Instance.new("UICorner", ayipBtn).CornerRadius = UDim.new(0, 6)
y = y + 34
local function refreshAyip()
    local a = CFG.ayip or 0
    local names = { [0] = "aus", [1] = "Stufe 1", [2] = "Stufe 2", [3] = "Stufe 3" }
    ayipBtn.Text = "AYIP:  " .. (names[a] or "aus")
    ayipBtn.BackgroundColor3 = (a == 0) and Color3.fromRGB(40, 28, 30)
        or Color3.fromRGB(48 + a * 16, 28, 70 + a * 12)
end
ayipBtn.Activated:Connect(function()
    task.spawn(function()
        CFG.ayip = ((CFG.ayip or 0) + 1) % 4
        if ENV.saveSettings then ENV.saveSettings() end
        refreshAyip()
        LOG("AYIP -> Stufe " .. tostring(CFG.ayip))
    end)
end)
refreshAyip()

-- Sound nach gelungener Finte. Beim Einschalten wird der Ordner neu
-- eingelesen, damit frisch hineingelegte Dateien sofort mitspielen.
local _, rSnd = makeButton("Finten-Sound", function() return CFG.jukeSound end,
    function()
        CFG.jukeSound = not CFG.jukeSound
        if CFG.jukeSound then
            fetchWebSounds(true)      -- beim Einschalten die Liste frisch holen
            local n, nf, ni, nd, nw = ENV.reloadSounds()
            state.sndCount = n
            if n > 0 then
                LOG(("Finten-Sound an: %d Sounds (%d eigene Dateien, %d eigene IDs, "
                     .. "%d von GitHub, %d mitgeliefert)")
                    :format(n, nf, ni, nw or 0, nd or 0))
            else
                LOG("Finten-Sound an, aber nichts ladbar — eigene mp3/ogg/wav in den "
                    .. "Ordner 'utg_sounds' legen oder Asset-IDs zeilenweise in "
                    .. "'utg_sounds.txt' schreiben")
            end
        end
        if ENV.saveSettings then ENV.saveSettings() end
    end)

local _, rSelf = makeButton("   ... selbst mithoeren",
    function() return CFG.jukeSoundSelf end,
    function()
        CFG.jukeSoundSelf = not CFG.jukeSoundSelf
        if ENV.saveSettings then ENV.saveSettings() end
    end)

local _, rVC = makeButton("   ... in den Voicechat",
    function() return CFG.jukeSoundVC end,
    function()
        CFG.jukeSoundVC = not CFG.jukeSoundVC
        if CFG.jukeSoundVC and not ENV.vcAlive() then
            LOG("Voicechat-Ausgabe an, aber das Begleitprogramm laeuft nicht "
                .. "— utg_vc_start.bat starten")
        end
        if ENV.saveSettings then ENV.saveSettings() end
    end)

-- Knopf zum Ausprobieren: spielt sofort einen Sound, genau so wie nach
-- einer gelungenen Finte — also auch ueber den Voicechat, wenn das
-- Begleitprogramm laeuft. Kein Schalter, sondern ein Ausloeser.
local sndTestBtn = Instance.new("TextButton")
sndTestBtn.Size = UDim2.new(1, -16, 0, 28)
sndTestBtn.Position = UDim2.new(0, 8, 0, y)
sndTestBtn.BackgroundColor3 = Color3.fromRGB(30, 46, 62)
sndTestBtn.BorderSizePixel = 0
sndTestBtn.Font = Enum.Font.Gotham
sndTestBtn.TextSize = 12
sndTestBtn.TextColor3 = Color3.fromRGB(170, 215, 245)
sndTestBtn.Text = "Sound abspielen  (Probe)"
sndTestBtn.Parent = main
Instance.new("UICorner", sndTestBtn).CornerRadius = UDim.new(0, 6)
y = y + 32
sndTestBtn.Activated:Connect(function()
    task.spawn(function()
        if #SND.list == 0 then
            local n = ENV.reloadSounds()
            state.sndCount = n
        end
        if #SND.list == 0 then
            sndTestBtn.Text = "Sound abspielen  —  keine Sounds gefunden"
        else
            playJukeSound()
            sndTestBtn.Text = ("Sound abspielen  —  %s%s"):format(
                tostring(SND.lastName),
                (CFG.jukeSoundVC and ENV.vcAlive()) and "  (+VC)" or "")
        end
        task.wait(2)
        sndTestBtn.Text = "Sound abspielen  (Probe)"
    end)
end)

local _, rThird = makeButton("3rd Person  [RightAlt]", function() return CFG.thirdPerson end,
                      function() ENV.toggleThird() end)
rFree = rThird

local status = Instance.new("TextLabel")
status.Size = UDim2.new(1, -16, 0, 72)
status.Position = UDim2.new(0, 8, 0, y)
status.BackgroundColor3 = Color3.fromRGB(24, 24, 28)
status.BorderSizePixel = 0
status.Font = Enum.Font.Code
status.TextSize = 11
status.TextColor3 = Color3.fromRGB(170, 190, 180)
status.TextXAlignment = Enum.TextXAlignment.Left
status.TextYAlignment = Enum.TextYAlignment.Top
status.Text = ""
status.Parent = main
Instance.new("UICorner", status).CornerRadius = UDim.new(0, 6)

------------------------------------------------------------------
-- 6b) FAIL-LOG
--     Ringpuffer der letzten Sekunden. Sobald man getaggt wird / stirbt,
--     wird der Vorlauf ausgeschrieben — damit sichtbar ist, WIE es dazu kam
--     (Abstand, Tempo, ob der Autopilot fuhr, ob er haing, welcher Modus).
------------------------------------------------------------------
local TRACE, TRACE_N = {}, 30          -- 30 x 0.2 s = 6 s Vorlauf
local traceAt = 0

local function traceSample()
    local now = tick()
    if now - traceAt < 0.2 then return end
    traceAt = now
    local char = LP.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    TRACE[#TRACE + 1] = {
        t = now,
        threatD = state.threatD,
        preyD = state.preyD,
        mode = AP.mode,
        ws = hum and hum.WalkSpeed or 0,
        vel = hrp and (hrp.AssemblyLinearVelocity * Vector3.new(1, 0, 1)).Magnitude or 0,
        boost = state.speedMul,
        path = AP.usingPath and 1 or 0,
        helper = AP.helper,
        stuck = AP.stuckRun or 0,
        role = state.role,
        grounded = hum and tostring(hum.FloorMaterial) ~= "Enum.Material.Air" or false,
    }
    if #TRACE > TRACE_N then table.remove(TRACE, 1) end
end

local function dumpTrace(reason)
    LOG("---------- FAIL: " .. reason .. " ----------")
    local gd = RENV.shared.gamemodeData
    LOG(("  Modus=%s  Rolle=%s  Jaeger=%d  Ziele=%d  Preset=%s  Autopilot=%s")
        :format(tostring(gd and gd.Name), tostring(state.role), state.nThreat or 0,
                state.nPrey or 0, P().name, tostring(CFG.autopilot)))
    local t0 = TRACE[1] and TRACE[1].t or tick()
    for _, e in ipairs(TRACE) do
        LOG(("  %+5.1fs  Faenger=%-6s Tempo=%5.1f (ws %5.1f, Boost %.2f) %-7s %s%s%s%s")
            :format(e.t - t0 - (tick() - t0),
                    e.threatD and ("%.1f"):format(e.threatD) or "-",
                    e.vel, e.ws, e.boost, tostring(e.mode or "-"),
                    e.path == 1 and "Route " or "",
                    e.helper and (e.helper .. " ") or "",
                    e.stuck > 0 and ("haengt:" .. e.stuck .. " ") or "",
                    e.grounded and "" or "in der Luft"))
    end
    LOG("-------------------------------------------")
    flushLog(true)
end
ENV.dumpTrace = dumpTrace

-- Wer hat mich getaggt? Das Spiel schreibt es in das Character-Attribut.
local function watchCharacter(char)
    if not char then return end
    local conn
    conn = char:GetAttributeChangedSignal("LastTagger"):Connect(function()
        local who = char:GetAttribute("LastTagger")
        if not who then return end
        local other = Players:FindFirstChild(tostring(who))
        local oh = other and hrpOf(other)
        local me = hrpOf(LP)
        local d = (oh and me) and (oh.Position - me.Position).Magnitude or -1
        dumpTrace(("getaggt von %s aus %.1f Studs"):format(tostring(who), d))
    end)
    conns[#conns + 1] = conn
    local hum = char:FindFirstChildOfClass("Humanoid")
    if hum then
        local dc = hum.Died:Connect(function() dumpTrace("gestorben") end)
        conns[#conns + 1] = dc
    end
end

------------------------------------------------------------------
-- 7) Loops
------------------------------------------------------------------
local RENDER_NAME = "UTG_TagAssist_Step"

RunService:BindToRenderStep(RENDER_NAME, Enum.RenderPriority.Input.Value - 1, function(dt)
    local ok, err = pcall(assistStep, dt)
    if not ok then
        LOG("FEHLER assistStep: " .. tostring(err))
    end
end)

conns[#conns + 1] = RunService.Heartbeat:Connect(function()
    traceSample()
    flushLog(false)
    diagFlush(false)
end)

-- War der Finten-Sound beim letzten Mal an, gleich die Sounds einlesen —
-- sonst steht der Schalter auf AN und es kommt nichts.
if CFG.jukeSound then
    task.spawn(function()
        local n = ENV.reloadSounds()
        state.sndCount = n
        LOG(("Finten-Sound aktiv: %d Sounds geladen"):format(n))
    end)
end

watchCharacter(LP.Character)
conns[#conns + 1] = Players.PlayerRemoving:Connect(function(pl)
    velTrack[pl] = nil
end)
conns[#conns + 1] = LP.CharacterAdded:Connect(function(c)
    task.wait(0.5)
    watchCharacter(c)
end)

task.spawn(function()
    local sndCheck = 0
    while ENV.alive ~= false do
        task.wait(0.15)
        if not sg.Parent then break end
        -- Sound-Ordner im Blick behalten: alle fuenf Sekunden schauen, ob
        -- Dateien dazugekommen sind. Dann reicht "Datei reinlegen".
        sndCheck = sndCheck + 1
        if CFG.jukeSound and CFG.jukeSoundVC and sndCheck % 20 == 0 then
            state.vcOk = ENV.vcAlive()
        end
        if CFG.jukeSound and sndCheck % 33 == 0 then
            local fp = sndFingerprint()
            if fp ~= SND.fp then
                local n = ENV.reloadSounds()
                state.sndCount = n
                LOG(("Sound-Ordner geaendert — %d Sounds geladen"):format(n))
            end
        end
        local t = state.threatD and ("%.0f"):format(state.threatD) or "–"
        local pr = state.preyD and ("%.0f"):format(state.preyD) or "–"
        local nl = string.char(10)
        local modeTxt = CFG.autopilot
            and ((AP.mode or "bereit")
                .. (AP.climbing and " (Leiter)"
                or (AP.helper and (" (" .. AP.helper .. ")")
                or (AP.grabbing and " (Mitnahme)"
                or (AP.usingPath and (AP.mode == "FLUCHT"
                        and (" -> " .. tostring(AP.routeTo or "Route")) or " (Pfad)")
                    or "")))))
            or "Autopilot aus"
        -- Deutlich anzeigen, wenn die eigene Rolle gar nicht taggen DARF —
        -- sonst sucht man den Fehler im Tool, obwohl das Spiel es verbietet.
        local gdS = RENV.shared.gamemodeData
        local roleCanTag = gdS and gdS.Roles and state.role
            and gdS.Roles[state.role] and gdS.Roles[state.role].TagTables ~= nil
        local roleNote = (state.role and not roleCanTag) and "  (darf nicht taggen)" or ""
        status.Text = ("  Rolle: %s%s   [%d jagen mich | %d jagbar]"):format(
                tostring(state.role or "-"), roleNote, state.nThreat or 0, state.nPrey or 0)
            .. nl .. ("  Faenger: %s   Opfer: %s  (Studs)"):format(t, pr)
            .. nl .. ("  Speed +%d%%   Reach %.1f   Tags %d/%d"):format(
                math.floor((state.speedMul - 1) * 100 + 0.5), state.reach,
                state.tagsOk or 0, state.tagsMiss or 0)
            .. nl .. ("  %s   AYIP %s%s"):format(modeTxt,
                (CFG.ayip or 0) == 0 and "aus" or tostring(CFG.ayip),
                CFG.jukeSound and ("   Sounds " .. tostring(state.sndCount or 0)
                    .. (CFG.jukeSoundVC
                        and (state.vcOk and "  VC: an" or "  VC: Player aus") or ""))
                or "")
    end
end)

-- Ein-/Ausblenden mit RightControl, Freecam mit T
conns[#conns + 1] = UserInputService.InputBegan:Connect(function(i, gp)
    if gp then return end
    if i.KeyCode == Enum.KeyCode.RightControl then
        main.Visible = not main.Visible
    elseif i.KeyCode == Enum.KeyCode.RightAlt then
        -- Frueher lag das auf T. Die Taste wird im Spiel anderweitig
        -- gebraucht, und jeder Druck hat unbemerkt die Verfolgerkamera
        -- eingeschaltet - die haengt hinter dem Charakter und wirkt wie
        -- eine Kopplung von Kamera und Spieler. Jetzt auf RightAlt.
        task.spawn(function()
            ENV.toggleThird()
            if rFree then rFree() end
        end)
    end
end)

-- Kamera-Abstand per Mausrad
conns[#conns + 1] = UserInputService.InputChanged:Connect(function(i, gp)
    if not CFG.thirdPerson then return end
    if i.UserInputType == Enum.UserInputType.MouseWheel then
        TP.dist = math.clamp(TP.dist - i.Position.Z * 2, TP.min, TP.max)
    end
end)

-- Rollenwechsel protokollieren
local roleVal = LP:FindFirstChild("PlayerRole")
if roleVal then
    conns[#conns + 1] = roleVal.Changed:Connect(function(v)
        LOG("Rolle -> " .. tostring(v))
    end)
end

------------------------------------------------------------------
-- 8) Cleanup
------------------------------------------------------------------
ENV.alive = true
function ENV.cleanup()
    ENV.alive = false
    pcall(function() RunService:UnbindFromRenderStep(RENDER_NAME) end)
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    pcall(visClear)     -- nur der eigene Ordner, sonst nichts in workspace
    -- eigene Sound-Instanzen mitnehmen, sonst haengen sie nach einer
    -- Neuinjektion doppelt im SoundService
    if SND and SND.holder then pcall(function() SND.holder:Destroy() end) end
    AP.mode, AP.vec = nil, nil
    if CFG.thirdPerson then CFG.thirdPerson = false pcall(thirdStop) end
    -- Hooks zurueckbauen
    if hookedCM and AP.origGetMoveVector then
        pcall(function() hookedCM.GetMoveVector = AP.origGetMoveVector end)
        hookedCM = nil
    end
    local S = RENV.shared
    if S and S.boosts then S.boosts.__utg = nil ; S.boosts.__utgjuke = nil end
    if S and S.multipliers then
        S.multipliers.RangeMultiplier = 1
        S.multipliers.TagRaySpread = 1
        S.multipliers.RunInAllDirections = false
        S.multipliers.RotateInMoveDirection = false
    end
    for _, g in ipairs(parentGui:GetChildren()) do
        if g.Name == "UTG_TagAssist" then pcall(function() g:Destroy() end) end
    end
    flushLog(true)
end

LOG("bereit — Preset " .. P().name)
flushLog(true)
print("[UTG Tag Assist] aktiv. Log: " .. LOGFILE .. "  |  RightControl blendet die GUI aus.")
