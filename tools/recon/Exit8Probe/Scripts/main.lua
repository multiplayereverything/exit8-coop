-- Probe mod (lab only): logs the loop's real call order, the trigger geometry and the state, and steps the player
-- through the corridor triggers so the game runs its own transitions without keyboard input.
local function W(fmt, ...) print(string.format("[E8PROBE] " .. fmt .. "\n", ...)) end
local function vec(v) return string.format("%.0f,%.0f,%.0f", v.X, v.Y, v.Z) end
local function nm(o) local ok, r = pcall(function() return o:GetFName():ToString() end) return ok and r or "?" end

local hooked = false
local hookList = {
    "/Game/_Exit8/BP/BP_ChangeManager.BP_ChangeManager_C:RandomChange",
    "/Game/_Exit8/BP/BP_ChangeManager.BP_ChangeManager_C:SetNoChange",
    "/Game/_Exit8/BP/BP_ChangeManager.BP_ChangeManager_C:SpawnChangeActor",
    "/Game/_Exit8/BP/BP_ChangeManager.BP_ChangeManager_C:ChangeFound",
    "/Game/_Exit8/BP/BP_ChangeManager.BP_ChangeManager_C:CountRandom",
    "/Game/_Exit8/BP/BP_ChangeManager.BP_ChangeManager_C:SetChangeActor",
    "/Game/_Exit8/BP/BP_ChangeManager.BP_ChangeManager_C:Spawn",
    "/Game/_Exit8/BP/BP_ChangeManager.BP_ChangeManager_C:Random",
    "/Game/_Exit8/BP/BP_PathBP1.BP_PathBP1_C:MoveFloor",
    "/Game/_Exit8/BP/BP_PathBP1.BP_PathBP1_C:NextExit",
    "/Game/_Exit8/BP/BP_PathBP1.BP_PathBP1_C:SpawnNextPath",
    "/Game/_Exit8/BP/BP_PathBP1.BP_PathBP1_C:ResetPath",
    "/Game/_Exit8/BP/BP_PathBP1.BP_PathBP1_C:Reset",
    "/Game/_Exit8/BP/BP_PathBP1.BP_PathBP1_C:Check",
    "/Game/_Exit8/BP/BP_PathBP1.BP_PathBP1_C:SetChangeActor",
    "/Game/_Exit8/BP/BP_PathBP1.BP_PathBP1_C:BeginHumanSpawn",
    "/Game/_Exit8/BP/BP_PathBP1.BP_PathBP1_C:TutorialSetting",
    "/Game/_Exit8/Core/PlayerState_Exit8.PlayerState_Exit8_C:SetFloor",
    "/Game/_Exit8/Core/GameState_Exit8.GameState_Exit8_C:GameOver",
    "/Game/_Exit8/BP/Base/BP_ChangeActorBase.BP_ChangeActorBase_C:ChangeEvent",
    "/Game/_Exit8/BP/Base/BP_ChangeActorBase.BP_ChangeActorBase_C:Base_Reset",
}

local function state(tag)
    local mark = os.getenv("E8_PROBE_MARKS") == "1"
    local function M(x) if mark then W("mark %s", x) end end
    M("a")
    local cm = FindFirstOf("BP_ChangeManager_C")
    local ps = FindFirstOf("PlayerState_Exit8_C")
    local pc = FindFirstOf("GamePC_C")
    M("b")
    local pawn = pc and pc:IsValid() and pc:K2_GetPawn() or nil
    M("c")
    local s = tag
    if pawn and pawn:IsValid() then s = s .. " pawn=" .. vec(pawn:K2_GetActorLocation()) end
    M("d")
    if pc and pc:IsValid() then s = s .. " yaw=" .. string.format("%.0f", pc:GetControlRotation().Yaw) end
    M("e")
    if ps and ps:IsValid() then s = s .. " floor=" .. tostring(ps.FloorNumber) end
    M("f")
    if cm and cm:IsValid() then
        s = s .. " change=" .. tostring(cm.Change) .. " remain=" .. tostring(cm.Remain) .. " nochg=" .. tostring(cm.noChangeCount)
        M("g")
        local p = cm.CurrentPathBP
        if p and p:IsValid() then s = s .. " path=" .. nm(p) end
        M("h")
        local a = cm.CurrentChangeActor
        if a and a:IsValid() then s = s .. " cur=" .. nm(a) end
        M("i")
        local tg = cm.CurrentChangeTag
        M("j")
        if tg then s = s .. " tag=" .. tg.TagName:ToString() end
    end
    W("%s", s)
end

local boxClass
local function geometry()
    boxClass = boxClass or StaticFindObject("/Script/Engine.PrimitiveComponent")
    for _, p in ipairs(FindAllOf("BP_PathBP1_C") or {}) do
        if p:IsValid() then
            local o = p:K2_GetActorLocation()
            W("path %s at %s yaw %.0f number=%s return=%s", nm(p), vec(o), p:K2_GetActorRotation().Yaw, tostring(p.Number), tostring(p.Return))
            local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
            local comps = p:K2_GetComponentsByClass(boxClass)
            for i = 1, #comps do
                local c = comps[i]:get()
                if c:GetGenerateOverlapEvents() and c:GetCollisionEnabled() ~= 0 then
                    local org, ext, rad = {}, {}, {}
                    ksl:GetComponentBounds(c, org, ext, rad)
                    W("  trig %s [%s] center=%.0f,%.0f,%.0f ext=%.0f,%.0f,%.0f", nm(c), c:GetClass():GetFName():ToString(),
                        org.X - o.X, org.Y - o.Y, org.Z - o.Z, ext.X, ext.Y, ext.Z)
                end
            end
            for _, cn in ipairs({ "SpawnPivot", "SpawnPivot_Return", "BP_Path_Corner1", "BP_Path_Corner2", "BP_Path_End", "BP_Path" }) do
                local c = p[cn]
                if c and c:IsValid() then local l = c:K2_GetComponentLocation(); W("  pt %s local=%.0f,%.0f yaw=%.0f", cn, l.X - o.X, l.Y - o.Y, c:K2_GetComponentRotation().Yaw) end
            end
        end
    end
end

local function installHooks()
    for _, path in ipairs(hookList) do
        local ok, err = pcall(function()
            RegisterHook(path, function(self, ...)
                local short = path:match(":(.*)$")
                local owner = nm(self:get())
                W("CALL %s on %s", short, owner)
                ExecuteInGameThread(function() state("  after " .. short) end)
            end)
        end)
        W("hook %s %s", path:match(":(.*)$"), ok and "ok" or ("FAILED " .. tostring(err)))
    end
end

local Bot = require("e8bot")
Bot.setLog(function(m) W("%s", m) end)
local plan = {}
for c in (os.getenv("E8_PROBE_PLAN") or "forward,forward,back,forward,forward"):gmatch("[^,]+") do plan[#plan + 1] = c end
local force = os.getenv("E8_PROBE_FORCE")   -- e.g. "Light.Off": after each natural spawn, force this anomaly instead
local forced = false
local t, leg, idle = 0, 0, 0
LoopAsync(200, function()
    t = t + 0.2
    ExecuteInGameThread(function()
        local ok, err = pcall(function()
            if not hooked and t >= 6 then hooked = true; if os.getenv("E8_PROBE_NOHOOKS") ~= "1" then installHooks() end; state("start") end
            if t >= 6 and math.floor(t * 5 + 0.5) % 10 == 0 then state(string.format("t=%.0f", t)) end
            if t == 10 then geometry() end
            Bot.step()
            if t > 12 and not Bot.busy() then
                idle = idle + 0.2
                if idle >= 4 and leg < #plan then
                    idle = 0; leg = leg + 1
                    W("LEG %d %s", leg, plan[leg])
                    Bot.go(plan[leg], 1700)
                    forced = false
                end
                if force and not forced and idle >= 2 then
                    forced = true
                    local cm = FindFirstOf("BP_ChangeManager_C")
                    W("FORCE %s (was change=%s tag=%s)", force, tostring(cm.Change), cm.CurrentChangeTag.TagName:ToString())
                    local ok2, e2 = pcall(function() cm:SpawnChangeActor({ TagName = FName(force) }) end)
                    W("FORCE result ok=%s %s", tostring(ok2), tostring(e2))
                    state("after-force")
                end
            else
                idle = 0
            end
        end)
        if not ok then W("ERROR %s", tostring(err)) end
    end)
    return t >= 170
end)
W("probe loaded")
