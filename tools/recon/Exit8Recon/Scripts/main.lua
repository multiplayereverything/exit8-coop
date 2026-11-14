-- Recon mod (lab only, never shipped): logs what the co-op mod needs to know about The Exit 8.
local dir = debug.getinfo(1, "S").source:match("^@(.*[\\/])Scripts[\\/]") or ".\\"
local out = io.open(dir .. "recon.txt", "w")
local function W(...) local s = string.format(...); out:write(s, "\n"); out:flush(); print("[E8RECON] " .. s .. "\n") end

W("package=%s loadlib=%s cpath=%s", type(package), package and type(package.loadlib) or "nil", package and tostring(package.cpath) or "nil")
W("os.getenv TEMP=%s", tostring(os.getenv("TEMP")))

local function name(o) local ok, r = pcall(function() return o:GetFullName() end); return ok and r or "?" end

local function snapshot(tag)
    W("==== snapshot %s", tag)
    for _, cls in ipairs({ "GameModeBase", "GameStateBase", "PlayerController", "Pawn", "GameInstance", "HUD", "LevelScriptActor", "UserWidget" }) do
        local all = FindAllOf(cls)
        if all then for _, o in ipairs(all) do if o:IsValid() then W("%s: %s", cls, name(o)) end end end
    end
    local pc = FindFirstOf("PlayerController")
    if pc and pc:IsValid() and pc.Pawn and pc.Pawn:IsValid() then
        local l = pc.Pawn:K2_GetActorLocation()
        W("pawn at %.1f %.1f %.1f", l.X, l.Y, l.Z)
    end
    local counts = {}
    local actors = FindAllOf("Actor") or {}
    for _, a in ipairs(actors) do
        if a:IsValid() then
            local c = a:GetClass():GetFName():ToString()
            counts[c] = (counts[c] or 0) + 1
        end
    end
    local keys = {}
    for k in pairs(counts) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do W("actorclass %s x%d", k, counts[k]) end
end

local t = 0
local dumped = false
LoopAsync(5000, function()
    t = t + 5
    ExecuteInGameThread(function()
        local ok, err = pcall(snapshot, tostring(t) .. "s")
        if not ok then W("snapshot error %s", tostring(err)) end
        if t >= 40 and not dumped then
            dumped = true
            local ok2, err2 = pcall(function() DumpAllObjects() end)
            W("DumpAllObjects ok=%s %s", tostring(ok2), tostring(err2))
        end
    end)
    return t >= 90
end)
W("recon loaded")
