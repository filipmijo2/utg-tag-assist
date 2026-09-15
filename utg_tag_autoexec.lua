-- Untitled Tag Game: startet den Tag-Assist bei jeder Injection,
-- aber nur in genau diesem Spiel.
task.spawn(function()
    if game.PlaceId ~= 14044547200 then return end
    for _ = 1, 30 do
        if game:IsLoaded() then break end
        task.wait(1)
    end
    -- warten bis die Spiel-Skripte ihre shared-Tabellen aufgebaut haben
    local renv = getrenv and getrenv() or nil
    for _ = 1, 60 do
        local S = renv and renv.shared
        if S and S.multipliers and S.boosts then break end
        task.wait(0.5)
    end
    local ok = false
    for _ = 1, 10 do
        ok = pcall(function() loadstring(readfile("tag_gui.lua"))() end)
        if ok then break end
        task.wait(3)
    end
    if not ok then warn("[UTG] Tag-Assist konnte nicht geladen werden") end
end)
