-- Lab-only: can this UE4SS build spawn an actor on UE 5.2? Logs each step before it runs.
local function W(fmt, ...) print(string.format("[E8SPAWN] " .. fmt .. "\n", ...)) end
local t = 0
LoopAsync(1000, function()
    t = t + 1
    ExecuteInGameThread(function()
        local ok, err = pcall(function()
            if t == 8 then
                local pc = FindFirstOf("GamePC_C")
                local world = pc:GetWorld()
                W("world %s", world:GetFullName())
                local cls = StaticFindObject("/Script/Engine.SkeletalMeshActor")
                W("class %s, calling SpawnActor", cls:GetFullName())
                local a = world:SpawnActor(cls, { X = 1120, Y = 2000, Z = 0 }, { Pitch = 0, Yaw = 0, Roll = 0 })
                W("SpawnActor returned %s", a and a:IsValid() and a:GetFullName() or "nil")
            end
            if t == 10 then
                for _, a in ipairs(FindAllOf("SkeletalMeshActor") or {}) do W("sma %s", a:GetFullName()) end
                local a = FindFirstOf("SkeletalMeshActor")
                if a and a:IsValid() then
                    local smc = a.SkeletalMeshComponent
                    local mesh = StaticFindObject("/Game/Scanned3DPeoplePack/RP_Character/rp_claudia_rigged_002_Mobile_ue4/rp_claudia_rigged_002_Mobile_ue4.rp_claudia_rigged_002_Mobile_ue4")
                    W("mesh %s", mesh and mesh:IsValid() and "found" or "missing")
                    smc:SetSkeletalMeshAsset(mesh)
                    W("mesh set")
                    local anim = StaticFindObject("/Game/Scanned3DPeoplePack/RP_Character/00_rp_master/Mannequin/Idle.Idle")
                    smc:SetAnimationMode(1); smc:PlayAnimation(anim, true)
                    W("anim set")
                    a:K2_SetActorLocation({ X = 1120, Y = 2300, Z = 0 }, false, {}, true)
                    local l = a:K2_GetActorLocation()
                    W("moved to %.0f,%.0f,%.0f", l.X, l.Y, l.Z)
                end
            end
        end)
        if not ok then W("ERROR %s", tostring(err)) end
    end)
    return t >= 14
end)
W("spawn probe loaded")
