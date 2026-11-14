-- Lab-only lineup: candidate puppet looks side by side in front of the start, facing the player.
-- A) scanned woman + her own Idle pose; B) UE5 mannequin (SKM_Manny) + CitySample idle; C) mannequin walking, tinted.
-- Logs whether each clip plays (position advancing, foot moving) and the mannequin material's parameters.
local function W(fmt, ...) print(string.format("[E8LOOK] " .. fmt .. "\n", ...)) end
local CLAUDIA = "/Game/Scanned3DPeoplePack/RP_Character/rp_claudia_rigged_002_Mobile_ue4/rp_claudia_rigged_002_Mobile_ue4.rp_claudia_rigged_002_Mobile_ue4"
local MANNY = "/Game/Characters/Mannequins/Meshes/SKM_Manny.SKM_Manny"
local SCAN_IDLE = "/Game/Scanned3DPeoplePack/RP_Character/00_rp_master/Mannequin/Idle.Idle"
local MTN_IDLE = "/Game/CitySampleCrowd/Character/Anims/Loco/MTN_N_Idle.MTN_N_Idle"
local MTN_WALK = "/Game/CitySampleCrowd/Character/Anims/Loco/MTN_N_Walk_F_noroot.MTN_N_Walk_F_noroot"
local function v(x) return string.format("%.1f,%.1f,%.1f", x.X, x.Y, x.Z) end
local function nm(o) local ok, r = pcall(function() return o:GetFName():ToString() end) return ok and r or "nil" end
local function find(path)
    local o = StaticFindObject(path)
    if o and o:IsValid() then return o end
    local ok, r = pcall(function() return LoadAsset(path) end)
    if ok and r and r:IsValid() then return r end
end
local cands = {}
local function spawn(key, x, meshPath, clipPath, tint)
    local pc = FindFirstOf("GamePC_C")
    local a = pc:GetWorld():SpawnActor(StaticFindObject("/Script/Engine.SkeletalMeshActor"), { X = x, Y = 2050, Z = 0 }, { Pitch = 0, Yaw = -180, Roll = 0 })
    local smc = a.SkeletalMeshComponent
    local function try(label, f) local ok, e = pcall(f); if not ok then W("%s: %s failed: %s", key, label, tostring(e)) end end
    local mesh, clip = find(meshPath), find(clipPath)
    W("%s: mesh %s clip %s", key, nm(mesh), nm(clip))
    try("setup", function()
        smc:SetSkeletalMeshAsset(mesh)
        smc.VisibilityBasedAnimTickOption = 0
        smc:SetComponentTickEnabled(true)
        smc:SetAnimationMode(1)
        smc:PlayAnimation(clip, true)
    end)
    try("materials", function()
        local m = smc:GetMaterial(0)
        W("%s: material 0 = %s", key, m and m:GetFullName() or "nil")
        if tint then
            local dm = smc:CreateDynamicMaterialInstance(0, m, FName("E8Tint"))
            for _, pname in ipairs({ "Tint", "BaseColor", "Color", "Base Color", "Albedo" }) do
                dm:SetVectorParameterValue(FName(pname), tint)
            end
            local okp, got = pcall(function() return dm:K2_GetVectorParameterValue(FName("Tint")) end)
            W("%s: tint applied; Tint now %s", key, okp and string.format("%.2f,%.2f,%.2f", got.R, got.G, got.B) or "?")
        end
    end)
    cands[key] = smc
end
local t = 0
LoopInGameThreadAfterFrames(10, function()
    t = t + 1
    local ok, err = pcall(function()
        if t == 40 then
            spawn("A_scan_idle", 990, CLAUDIA, SCAN_IDLE)
            spawn("B_manny_idle", 1120, MANNY, MTN_IDLE)
            spawn("C_manny_walk", 1250, MANNY, MTN_WALK, { R = 0.15, G = 0.45, B = 1.0, A = 1.0 })
        end
        if t > 40 and t < 60 and t % 3 == 0 then
            for key, smc in pairs(cands) do
                local okp, pos = pcall(function() return smc:GetPosition() end)
                W("%s pos=%s foot_l=%s hand_l=%s", key, okp and string.format("%.2f", pos) or "?",
                    v(smc:GetSocketLocation(FName("foot_l"))), v(smc:GetSocketLocation(FName("hand_l"))))
            end
        end
    end)
    if not ok then W("ERROR %s", tostring(err)) end
    return false
end)
W("look probe loaded")
