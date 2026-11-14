-- Lab-only probe: get a puppet SkeletalMeshActor that ticks its animation.
-- A) UE4SS World:SpawnActor, then tick enabled after the mesh is set; B) GameplayStatics deferred spawn + finish.
-- Evidence: tick flag, play position and bone movement over time.
local function W(fmt, ...) print(string.format("[E8ANIM] " .. fmt .. "\n", ...)) end
local MESH = "/Game/Scanned3DPeoplePack/RP_Character/rp_claudia_rigged_002_Mobile_ue4/rp_claudia_rigged_002_Mobile_ue4.rp_claudia_rigged_002_Mobile_ue4"
local IDLE = "/Game/Scanned3DPeoplePack/RP_Character/00_rp_master/Mannequin/Idle.Idle"
local WALK = "/Game/CitySampleCrowd/Character/Anims/Loco/MTN_N_Walk_F_noroot.MTN_N_Walk_F_noroot"
local function v(x) return string.format("%.1f,%.1f,%.1f", x.X, x.Y, x.Z) end
local function nm(o) local ok, r = pcall(function() return o:GetFName():ToString() end) return ok and r or "nil" end
local smcs = {}
local t = 0
local function setup(key, a, clip)
    local smc = a.SkeletalMeshComponent
    local function try(label, f) local ok2, e2 = pcall(f); if not ok2 then W("%s: %s failed: %s", key, label, tostring(e2)) end end
    try("mesh", function() smc:SetSkeletalMeshAsset(StaticFindObject(MESH)) end)
    try("tickopt", function() smc.VisibilityBasedAnimTickOption = 0 end)
    try("tickon", function() smc:SetComponentTickEnabled(true) end)
    try("play", function() smc:SetAnimationMode(1); smc:PlayAnimation(StaticFindObject(clip), true) end)
    try("info", function() W("%s: actor=%s tick=%s playing=%s", key, nm(a), tostring(smc:IsComponentTickEnabled()), tostring(smc:IsPlaying())) end)
    try("accepted", function() local i = smc:GetSingleNodeInstance(); W("%s: accepted clip %s", key, nm(i:GetAnimationAsset())) end)
    smcs[key] = smc
end
LoopAsync(250, function()
    t = t + 0.25
    ExecuteInGameThread(function()
        local ok, err = pcall(function()
            if t == 8 then
                local pc = FindFirstOf("GamePC_C")
                local cls = StaticFindObject("/Script/Engine.SkeletalMeshActor")
                local WALKF = "/Game/CitySampleCrowd/Character/Anims/Loco/FTN_Set/FTN_N_Walk_F.FTN_N_Walk_F"
                local y = 1900
                for _, kc in ipairs({ { "idle", IDLE }, { "walk_m", WALK }, { "walk_f", WALKF } }) do
                    local before = {}
                    for _, a in ipairs(FindAllOf("SkeletalMeshActor") or {}) do before[a:GetAddress()] = true end
                    local ret = pc:GetWorld():SpawnActor(cls, { X = 1120, Y = y, Z = 0 }, { Pitch = 0, Yaw = 0, Roll = 0 })
                    W("%s: SpawnActor returned %s", kc[1], nm(ret))
                    for _, a in ipairs(FindAllOf("SkeletalMeshActor") or {}) do if not before[a:GetAddress()] then setup(kc[1], a, kc[2]) end end
                    y = y + 300
                end
            end
            if t > 8 and t < 12 then
                for key, c in pairs(smcs) do
                    if c:IsValid() then
                        local okp, pos = pcall(function() return c:GetPosition() end)
                        W("%s t=%.0f pos=%s tick=%s foot_l=%s hand_l=%s", key, t, okp and string.format("%.2f", pos) or "?", tostring(c:IsComponentTickEnabled()),
                            v(c:GetSocketLocation(FName("foot_l"))), v(c:GetSocketLocation(FName("hand_l"))))
                    end
                end
            end
        end)
        if not ok then W("ERROR %s", tostring(err)) end
    end)
    return t >= 18
end)
W("anim probe loaded")
