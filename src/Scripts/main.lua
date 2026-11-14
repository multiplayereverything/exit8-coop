-- Exit 8 Together: co-op for The Exit 8 (UE 5.2.1) as a UE4SS Lua mod.
-- Host-authoritative. The host's game decides everything about the loop: which way the group goes (forward / turn
-- back), the exit count and the anomaly. A client's own choice triggers are switched off; when the host crosses one,
-- the client is walked across the same trigger in its own game, so the game's own transition code runs there too.
-- Then the client's exit count and anomaly are corrected to the host's. Each player streams their pose; the others see
-- a puppet built from a mesh the game already ships.
-- Networking lives in native\e8net.dll (TCP LAN/direct + Steam lobby/P2P); see native\e8net.cpp for the file protocol.
local VERSION = "0.2.1"
local PROTO = "2"
local DEFAULT_PORT = 27080

local Bot = require("e8bot")

------------------------------------------------------------------------------ paths, config, log
local modDir = package.cpath:match("([^;]*[\\/]Mods[\\/]Exit8Together[\\/])Scripts[\\/]%?%.dll")
    or "Mods\\Exit8Together\\"
local ipcDir = modDir .. "ipc\\"

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
local cfg = { mode = "off", transport = "lan", address = "127.0.0.1", port = tostring(DEFAULT_PORT), name = "Player", lobby = "",
              choice = "vote" }   -- choice: vote (everyone at the same line) | host (the host's feet decide)
do
    local f = io.open(modDir .. "config.txt", "r")
    if f then
        for line in f:lines() do
            local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
            if k and not line:match("^%s*[#;]") then cfg[k:lower()] = v end
        end
        f:close()
    end
    for _, k in ipairs({ "mode", "transport", "address", "port", "name", "lobby", "choice" }) do
        local v = os.getenv("E8T_" .. k:upper())
        if v and v ~= "" then cfg[k] = v end
    end
end
local LAB = os.getenv("E8T_LAB") == "1"
local TOUR = os.getenv("E8T_TOUR") or ""
local MUTANT = os.getenv("E8T_MUTANT") or ""   -- lab only: switches one fix off so its check must fail
local function mutant(name) return LAB and MUTANT == name end

local function log(fmt, ...) print(string.format("[E8T] " .. fmt .. "\n", ...)) end
local function evidence(kind, fmt, ...) print(string.format("E8T-" .. kind .. " " .. fmt .. "\n", ...)) end

------------------------------------------------------------------------------ transport (e8net.dll via files)
local Net = { outSeq = 0, inSeq = 0, pending = {}, myId = 0, mode = "none", peers = {} }
do
    local ok, err = package.loadlib(modDir .. "native\\e8net.dll", "*")
    Net.loaded = ok and true or false
    if not ok then log("could not load e8net.dll: %s", tostring(err)) end
end
function Net.send(line) Net.pending[#Net.pending + 1] = line end
function Net.flush()
    if #Net.pending == 0 or not Net.loaded then return end
    local n = Net.outSeq + 1
    local p = ipcDir .. "out." .. n
    local f = io.open(p .. ".tmp", "wb")
    if not f then return end
    f:write(table.concat(Net.pending, "\n"), "\n")
    f:close()
    if os.rename(p .. ".tmp", p) then Net.outSeq = n; Net.pending = {} end
end
function Net.poll(handler)
    while Net.loaded do
        local p = ipcDir .. "in." .. (Net.inSeq + 1)
        local f = io.open(p, "rb")
        if not f then return end
        local s = f:read("a")
        f:close()
        os.remove(p)
        Net.inSeq = Net.inSeq + 1
        for line in s:gmatch("[^\n]+") do handler(line) end
    end
end
local function split(s)
    local t = {}
    for v in (s .. "|"):gmatch("([^|]*)|") do t[#t + 1] = v end
    return t
end

local function start()
    local name = cfg.name:gsub("[%s|]", "_")
    if cfg.transport == "steam" and cfg.mode ~= "off" then Net.send("!steamselftest") end   -- result in the log: #steamselftest ok/fail
    if cfg.mode == "host" then
        if cfg.transport == "steam" then Net.send(string.format("!host steam - %s %s %s", PROTO, VERSION, name))
        else Net.send(string.format("!host lan %s %s %s %s", cfg.port, PROTO, VERSION, name)) end
    elseif cfg.mode == "join" then
        if cfg.transport == "steam" then Net.send(string.format("!join steam %s - %s %s %s", (cfg.lobby ~= "" and cfg.lobby) or "auto", PROTO, VERSION, name))
        else Net.send(string.format("!join lan %s %s %s %s %s", cfg.address, cfg.port, PROTO, VERSION, name)) end
    end
    log("Exit 8 Together %s (protocol %s): mode=%s transport=%s", VERSION, PROTO, cfg.mode, cfg.transport)
end

------------------------------------------------------------------------------ game access
local function valid(o) return o and o:IsValid() end
local function gameCM() local o = FindFirstOf("BP_ChangeManager_C"); if valid(o) then return o end end
local function gamePS() local o = FindFirstOf("PlayerState_Exit8_C"); if valid(o) then return o end end
local function gameGS() local o = FindFirstOf("GameState_Exit8_C"); if valid(o) then return o end end

local function anomaly()
    local cm = gameCM()
    if not cm then return nil end
    local tag = "None"
    pcall(function() tag = cm.CurrentChangeTag.TagName:ToString() end)
    return { change = cm.Change and true or false, tag = tag }
end

-- Choice planes in a corridor's local frame (from the triggers' bounds, see handoff "Game facts").
local FORWARD_X, FORWARD_Y0, FORWARD_Y1 = 1780, 3590, 4590    -- Tri_Susumu, crossed towards +X
local BACK_X, BACK_Y0, BACK_Y1 = 459, 280, 1280                -- Tri_Turn, crossed towards -X
local ANO_X = 556                                                -- Tri_Ano_Spawn (same band as Tri_Turn), left towards +X
-- BP_ChangeManager's DEBUG anomaly list (index = DEBUG_ANOMALY_TYPE), read from its bytecode; see handoff.
local ANOMALY_INDEX = {}
for i, t in ipairs({ "Human.Smile", "Human.Large", "Human.Face", "Human.Fast", "Human.Look", "Duo", "Mimick", "Exit", "Water",
    "Light.Off", "Light.Flash", "Light.Scatter", "Ad.Big", "Ad.Part", "Ad.Fes", "CameraPoster.Chase", "CameraPoster.Look",
    "Sign.Rotate", "Sign.Turn", "Ceiling.Center.Smile", "Block.Stop", "Block.Strange", "Vent.Blood", "Camera.Look", "Door2.Open",
    "Door.Hidden", "Door2.Handle", "Door.Knock", "Door1.Look", "Ad.Change", "PosterSmk.Many", "Ad.Movie",
    "Light.YellowRoom_Movie", "Light.Off_in_order_Movie", "Mimick2_Movie", "Human.Stalker_Movie" }) do ANOMALY_INDEX[t] = i - 1 end

------------------------------------------------------------------------------ session state
local S = {
    role = (cfg.mode == "host" and "host") or (cfg.mode == "join" and "client") or "off",
    seq = 0,               -- decisions applied in this run (host: made; client: applied)
    run = 0,               -- bumps when the level restarts (new GameState)
    gsAddr = nil,
    lastLocal = nil,
    host = nil,            -- client: last host state {seq, floor, change, tag}
    pendingDecisions = {}, -- client: decisions to apply, in order
    applying = nil,        -- client: decision being walked across
    anoDone = true,        -- client: this corridor's anomaly already applied (the first corridor rolls none)
    peers = {},            -- id -> {pose = {...}, name, puppet}
    lastPose = 0, lastState = 0, mismatchSince = nil, floorMismatchSince = nil,
    t = 0,
}

local function myPos()
    local pawn = Bot.pawn()
    if not pawn then return nil end
    return pawn:K2_GetActorLocation(), pawn
end

-- Host: detect the player crossing a choice plane (the game's trigger fires at the same place).
local function detectCrossing(pos)
    local path = Bot.pathAt(pos)
    if not path then S.lastLocal = nil return nil end
    local x, y = Bot.toLocal(path, pos)
    local key = path:GetAddress()
    local dir
    local l = S.lastLocal
    if l and l.key == key and math.abs(x - l.x) < 200 and math.abs(y - l.y) < 200 then
        if y > FORWARD_Y0 and y < FORWARD_Y1 and l.x < FORWARD_X and x >= FORWARD_X then dir = "forward" end
        if y > BACK_Y0 and y < BACK_Y1 and l.x > BACK_X and x <= BACK_X then dir = "back" end
        if y > BACK_Y0 and y < BACK_Y1 and l.x < ANO_X + 50 and x >= ANO_X + 50 then dir = "ano" end
    end
    S.lastLocal = { key = key, x = x, y = y }
    return dir
end

------------------------------------------------------------------------------ puppets
-- Puppet look (owner's pick, 2026-11-14): the UE5 template mannequin the game ships, tinted per player. No face, so it
-- reads as "another player" rather than a stranger (the scanned woman's face looked dead close up and her idle was an
-- A-pose). The CitySample crowd clips play on it (measured: walk moves the feet, idle breathes); the walk is in place,
-- so the puppet's own movement is ours.
local PUPPET_MESH = "/Game/Characters/Mannequins/Meshes/SKM_Manny.SKM_Manny"
local PUPPET_ANIMS = {
    walk = { "/Game/CitySampleCrowd/Character/Anims/Loco/MTN_N_Walk_F_noroot.MTN_N_Walk_F_noroot" },
    idle = { "/Game/CitySampleCrowd/Character/Anims/Loco/MTN_N_Idle.MTN_N_Idle" },
}
-- player id -> tint (MI_Manny "Tint" parameter): 1 blue, 2 orange, 3 green, 4 purple
local PLAYER_TINTS = {
    { R = 0.15, G = 0.45, B = 1.00, A = 1 }, { R = 1.00, G = 0.45, B = 0.10, A = 1 },
    { R = 0.20, G = 0.85, B = 0.30, A = 1 }, { R = 0.65, G = 0.30, B = 0.95, A = 1 },
}
local function tintPuppet(smc, id)
    local tint = PLAYER_TINTS[((id - 1) % #PLAYER_TINTS) + 1]
    local n = 1
    pcall(function() n = smc:GetNumMaterials() end)
    local got
    for slot = 0, math.max(0, n - 1) do
        local ok = pcall(function()
            local dm = smc:CreateDynamicMaterialInstance(slot, smc:GetMaterial(slot), FName("E8Tint" .. slot))
            dm:SetVectorParameterValue(FName("Tint"), tint)
            got = got or dm:K2_GetVectorParameterValue(FName("Tint"))
        end)
        if not ok then log("tint failed on material slot %d", slot) end
    end
    return got, n
end
local WALK_SPEED = 40          -- cm/s above which the puppet walks
local CLIP_WALK_SPEED = 150    -- cm/s the walk clip covers at play rate 1
local puppetSpawn = nil   -- {before = set, peer = id, at = time}

local function findAsset(path)
    local o = StaticFindObject(path)
    if valid(o) then return o end
    local ok, r = pcall(function() return LoadAsset(path) end)
    if ok and valid(r) then return r end
end

local function puppetClip(which)
    for _, path in ipairs(PUPPET_ANIMS[which]) do
        local c = findAsset(path)
        if c then return c end
    end
end

-- Plays the walk or idle clip on a puppet; only touches the component when the state changes.
local function setPuppetAnim(p, which, rate)
    if not valid(p.smc) then return end
    if mutant("noanim") then which = "idle" end
    if p.anim ~= which then
        local clip = puppetClip(which)
        if clip then
            p.smc:SetAnimationMode(1)          -- single node
            p.smc:PlayAnimation(clip, true)
            p.anim = which
        end
    end
    if rate then p.smc:SetPlayRate(rate) end
end

-- UE4SS v4.0.0: World:SpawnActor returns the actor, and its components tick (v3.0.1 returned nil and the spawned
-- actor never animated). Diffing SkeletalMeshActors stays as a fallback. "summon" does nothing in Shipping.
local function requestPuppet(id)
    if puppetSpawn then return end
    local before = {}
    for _, a in ipairs(FindAllOf("SkeletalMeshActor") or {}) do before[a:GetAddress()] = true end
    local pc = FindFirstOf("GamePC_C")
    if not valid(pc) then return end
    local cls = StaticFindObject("/Script/Engine.SkeletalMeshActor")
    local pose = S.peers[id] and S.peers[id].pose
    local a = pc:GetWorld():SpawnActor(cls, { X = pose and pose.x or 0, Y = pose and pose.y or 0, Z = pose and pose.z - 90 or 0 }, { Pitch = 0, Yaw = 0, Roll = 0 })
    puppetSpawn = { before = before, peer = id, at = S.t, actor = valid(a) and a or nil }
end

local function finishPuppet()
    if not puppetSpawn then return end
    local found = puppetSpawn.actor
    if not found then
        for _, a in ipairs(FindAllOf("SkeletalMeshActor") or {}) do
            if valid(a) and not puppetSpawn.before[a:GetAddress()] then found = a break end
        end
    end
    for _, a in ipairs(found and { found } or {}) do
        if valid(a) then
            local smc = a.SkeletalMeshComponent
            local mesh = findAsset(PUPPET_MESH)
            local peer = S.peers[puppetSpawn.peer]
            if valid(smc) and valid(mesh) then
                smc:SetSkeletalMeshAsset(mesh)   -- UE 5.1+ name; SetSkeletalMesh is not a UFunction here
                smc.VisibilityBasedAnimTickOption = 0   -- keep animating when off screen (and in minimized lab copies)
                smc:SetComponentTickEnabled(true)
                local got, slots = tintPuppet(smc, puppetSpawn.peer)
                evidence("CHECK", "puppet-look id=%d mesh=%s slots=%d tint=%s", puppetSpawn.peer, mesh:GetFName():ToString(), slots,
                    got and string.format("%.2f,%.2f,%.2f", got.R, got.G, got.B) or "none")
                if peer then peer.smc = smc; peer.anim = nil; setPuppetAnim(peer, "idle") end
            end
            a:SetActorEnableCollision(false)
            if peer then peer.puppet = a end
            log("puppet for player %d ready (%s)", puppetSpawn.peer, a:GetFName():ToString())
            puppetSpawn = nil
            return
        end
    end
    if S.t - puppetSpawn.at > 5 then log("puppet spawn timed out; retrying"); puppetSpawn = nil end
end

-- Smooth puppets (runs every frame). Each remote player is drawn a little in the past, between two received poses
-- (snapshot interpolation): the delay adapts to the measured gap and jitter (Baldi 0.9.4: gap + 4 x jitter, clamped
-- 0.06-0.25 s). Short extrapolation covers a late packet; a jump of more than 3 m (corridor transition) snaps.
local function angleLerp(a, b, k)
    local d = (b - a + 540) % 360 - 180
    return a + d * k
end

local function samplePose(p, now)
    local buf = p.buf
    if not buf or #buf == 0 then return nil end
    local rt = now - p.offset - p.delay
    if rt <= buf[1].ts then return buf[1], buf[1], 0 end
    for i = 1, #buf - 1 do
        local a, b = buf[i], buf[i + 1]
        if rt <= b.ts then
            local span = b.ts - a.ts
            local k = span > 0 and (rt - a.ts) / span or 1
            if (b.x - a.x) ^ 2 + (b.y - a.y) ^ 2 > 300 ^ 2 then k = k < 0.5 and 0 or 1 end   -- teleport: no sliding
            return a, b, k
        end
    end
    local n = #buf
    local a, b = buf[n - 1] or buf[n], buf[n]
    local over = math.min(rt - b.ts, 0.15)   -- extrapolate a little, then hold
    local span = b.ts - a.ts
    return a, b, span > 0 and 1 + over / span or 1
end

local function updatePuppets(now, dt)
    for id, p in pairs(S.peers) do
        if p.pose then
            if not valid(p.puppet) then p.puppet = nil; requestPuppet(id)
            else
                local x, y, z, viewYaw
                if mutant("nosmooth") then
                    -- lab mutant: the 0.1.x behaviour (chase the newest pose, 10 steps a second)
                    local cur = p.puppet:K2_GetActorLocation()
                    if now - (p.lastStep or 0) < 0.1 then
                        x, y, z, viewYaw = cur.X, cur.Y, cur.Z + 90, p.pose.yaw   -- between steps it stands still
                    else
                        p.lastStep = now
                        x, y, z, viewYaw = p.pose.x, p.pose.y, p.pose.z, p.pose.yaw
                    end
                    local n = #p.buf
                    if n >= 2 and p.buf[n].ts > p.buf[n - 1].ts then
                        local a, b = p.buf[n - 1], p.buf[n]
                        local v = math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2) / (b.ts - a.ts)
                        p.speed = v < 900 and v or 0
                    end
                else
                    local a, b, k = samplePose(p, now)
                    if not a then goto continue end
                    x, y, z = a.x + (b.x - a.x) * k, a.y + (b.y - a.y) * k, a.z + (b.z - a.z) * k
                    viewYaw = angleLerp(a.yaw, b.yaw, math.max(0, math.min(1, k)))
                    -- speed from the two samples around the drawn moment
                    local span = b.ts - a.ts
                    local v = span > 0 and math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2) / span or 0
                    if v > 900 then v = 0 end   -- teleport
                    p.speed = (p.speed or 0) + (v - (p.speed or 0)) * math.min(1, dt * 8)
                end
                -- body faces where it walks; when still, where the player looks
                local sp = p.speed or 0
                local want = viewYaw
                if sp > WALK_SPEED and p.drawn then
                    local dx, dy = x - p.drawn.x, y - p.drawn.y
                    if dx * dx + dy * dy > 0.01 then want = math.deg(math.atan(dy, dx)) end
                end
                p.bodyYaw = p.bodyYaw and angleLerp(p.bodyYaw, want, math.min(1, dt * 8)) or want
                p.drawn = { x = x, y = y }
                p.puppet:K2_SetActorLocation({ X = x, Y = y, Z = z - 90 }, false, {}, true)
                p.puppet:K2_SetActorRotation({ Pitch = 0, Yaw = p.bodyYaw - 90, Roll = 0 }, true)
                p.puppet:SetActorHiddenInGame(p.pose.seq ~= S.seq)   -- only while in the same loop
                if now - (p.pose.rx or 0) > 0.4 then p.speed = 0 end   -- no fresh pose: stand still
                -- walk/idle with a little hysteresis so it doesn't flicker at the threshold
                if p.anim == "walk" and sp < WALK_SPEED * 0.5 then setPuppetAnim(p, "idle", 1.0)
                elseif p.anim ~= "walk" and sp > WALK_SPEED then setPuppetAnim(p, "walk", math.max(0.6, math.min(2.2, sp / CLIP_WALK_SPEED)))
                elseif p.anim == "walk" then setPuppetAnim(p, "walk", math.max(0.6, math.min(2.2, sp / CLIP_WALK_SPEED)))
                elseif not p.anim then setPuppetAnim(p, "idle", 1.0) end
                -- lab evidence: per-frame drawn speed, to judge smoothness (steady while walking, not stop-go)
                if LAB and p.prevDraw and dt > 0.004 then
                    local fs = math.sqrt((x - p.prevDraw.x) ^ 2 + (y - p.prevDraw.y) ^ 2) / dt
                    if sp > WALK_SPEED and fs < 2000 then
                        local m = p.smooth or { n = 0, s = 0, s2 = 0, moved = 0 }
                        m.n = m.n + 1; m.s = m.s + fs; m.s2 = m.s2 + fs * fs
                        if fs > 1 then m.moved = m.moved + 1 end
                        p.smooth = m
                    end
                end
                p.prevDraw = { x = x, y = y }
            end
        end
        ::continue::
    end
end

------------------------------------------------------------------------------ messages
-- P|id|seq|x|y|z|yaw        pose (world; the corridor layout is the same on every PC for the same choices)
-- D|1|seq|dir               host made a choice (forward/back); seq is the count after it
-- A|1|seq|change|tag        the host's game rolled this corridor's anomaly (host left Tri_Ano_Spawn)
-- V|id|seq|vote             a player's vote: forward | back | none (vote mode)
-- S|1|seq|floor|change|tag|run   host loop state
local function onLine(line)
    if line:sub(1, 1) == "#" then
        log("net %s", line)
        local ev, a, b = line:match("^#(%S+)%s*(%S*)%s*(.*)$")
        if ev == "connected" then Net.myId = tonumber(a) or 0; evidence("CHECK", "connected id=%d", Net.myId)
        elseif ev == "hosting" then Net.myId = 1; if a == "steam" then evidence("CHECK", "steam-lobby-created %s", b) end
        elseif ev == "joined" then evidence("CHECK", "steam-lobby-joined %s", b)
        elseif ev == "steamselftest" then evidence("CHECK", "steamselftest %s %s", a, b)
        elseif ev == "peer_join" then
            local id = tonumber(a)
            if id and id ~= Net.myId then S.peers[id] = S.peers[id] or { name = b }; evidence("CHECK", "peer_join id=%d", id) end
        elseif ev == "peer_left" then
            local id = tonumber(a)
            local p = id and S.peers[id]
            if p and valid(p.puppet) then p.puppet:K2_DestroyActor() end
            if id then S.peers[id] = nil end
        elseif ev == "status" then Net.status = line
        end
        return
    end
    local f = split(line)
    local op, from = f[1], tonumber(f[2])
    if not from or from == Net.myId then return end
    if op == "P" then
        local p = S.peers[from] or {}
        S.peers[from] = p
        local now = os.clock()   -- Windows CRT clock(): wall time since process start
        local s = { seq = tonumber(f[3]), x = tonumber(f[4]), y = tonumber(f[5]), z = tonumber(f[6]), yaw = tonumber(f[7]),
                    ts = tonumber(f[8]) or now, rx = now }
        p.pose = s
        -- playback buffer, oldest first (drop out-of-order samples)
        p.buf = p.buf or {}
        if #p.buf == 0 or s.ts > p.buf[#p.buf].ts then
            if #p.buf > 0 then
                local gap = s.ts - p.buf[#p.buf].ts
                p.gap = p.gap and (p.gap + (gap - p.gap) * 0.1) or gap
            end
            p.buf[#p.buf + 1] = s
            if #p.buf > 30 then table.remove(p.buf, 1) end
        end
        -- clock offset (receiver minus sender): the smallest seen is the least delayed; drift up slowly
        local o = now - s.ts
        if not p.offset or o < p.offset then p.offset = o else p.offset = p.offset + (o - p.offset) * 0.002 end
        local late = o - p.offset
        p.jitter = p.jitter and (p.jitter + (math.abs(late) - p.jitter) * 0.1) or 0
        p.delay = math.max(0.06, math.min(0.25, (p.gap or 0.05) + 4 * p.jitter))
    elseif op == "D" and S.role == "client" then
        S.pendingDecisions[#S.pendingDecisions + 1] = { seq = tonumber(f[3]), dir = f[4] }
    elseif op == "R" then
        -- Someone was caught: everyone goes back to the start together (GameState.GameOver -> OpenLevel(current)).
        -- R carries the sender's restart count: restart only if we are behind it (both caught at once: no echo).
        local g = tonumber(f[3]) or 0
        if S.run >= g or S.expectRestart then return end
        if mutant("norestartsync") then return end
        local gs = gameGS()
        if gs then
            S.expectRestart = true
            log("player %d was caught; restarting together", from)
            gs:GameOver(1.0, 0.5, true)
        end
    elseif op == "V" then
        local p = S.peers[from] or {}
        S.peers[from] = p
        p.vote = { seq = tonumber(f[3]), vote = f[4], rx = S.t }
    elseif op == "A" and S.role == "client" then
        S.pendingDecisions[#S.pendingDecisions + 1] = { seq = tonumber(f[3]), dir = "ano", change = f[4] == "1", tag = f[5] }
    elseif op == "S" and S.role == "client" then
        S.host = { seq = tonumber(f[3]), floor = tonumber(f[4]), change = f[5] == "1", tag = f[6], run = tonumber(f[7]) }
    end
end

------------------------------------------------------------------------------ client: follow the host's choices
local CROSS = {
    forward = { { FORWARD_X - 80, 4245 }, { FORWARD_X - 40, 4245 }, { FORWARD_X, 4245 }, { FORWARD_X + 40, 4245 }, { FORWARD_X + 90, 4245 } },
    back = { { BACK_X + 80, 735 }, { BACK_X + 40, 735 }, { BACK_X, 735 }, { BACK_X - 40, 735 }, { BACK_X - 90, 735 } },
    ano = { { ANO_X - 60, 735 }, { ANO_X - 20, 735 }, { ANO_X + 20, 735 }, { ANO_X + 60, 735 }, { ANO_X + 110, 735 } },
}

-- Make the client's own RandomChange roll the host's result with BP_ChangeManager's developer switches (bytecode:
-- DEBUG_MODE on; DEBUG_ANOMALY_ENABLE 1 = anomaly, 2 = none; DEBUG_ANOMALY_TYPE = index into its tag list).
local function forceNextRoll(change, tag)
    local cm = gameCM()
    if not cm then return false end
    if mutant("noanomalysync") then return true end
    local idx = ANOMALY_INDEX[tag]
    if change and not idx then log("unknown anomaly tag %s; the client rolls its own", tostring(tag)) return false end
    cm.DEBUG_MODE = true
    cm.DEBUG_ANOMALY_ENABLE = change and 1 or 2
    if idx then cm.DEBUG_ANOMALY_TYPE = idx end
    return true
end
local function clearForcedRoll()
    local cm = gameCM()
    if cm then cm.DEBUG_MODE = false; cm.DEBUG_ANOMALY_ENABLE = 0 end
end

-- Guard: invisible walls just before the lines nobody may cross alone, so a player's own game never makes a choice
-- (or, on a client, rolls an anomaly) by itself. Clients always have them; in vote mode the host has the choice walls
-- too. Returns true if the pawn was pushed back.
local function guard(pawn, pos)
    if mutant("noguard") and S.role == "client" then return false end
    local path = Bot.pathAt(pos)
    if not path then return false end
    local x, y = Bot.toLocal(path, pos)
    local nx = x
    if y > FORWARD_Y0 and y < FORWARD_Y1 and x > FORWARD_X - 60 and x < FORWARD_X + 40 then nx = FORWARD_X - 60 end
    if y > BACK_Y0 and y < BACK_Y1 and x > -100 and x < 1000 then
        if S.role == "client" and not S.anoDone and x > ANO_X - 60 then nx = ANO_X - 60 end
        if S.anoDone and x < ANO_X - 40 and x > BACK_X - 60 then nx = ANO_X - 40 end
    end
    if nx == x then return false end
    local w = Bot.toWorld(path, nx, y)
    pawn:K2_SetActorLocation({ X = w.X, Y = w.Y, Z = pos.Z }, false, {}, true)
    if not S.lastBlockLog or S.t - S.lastBlockLog > 3 then S.lastBlockLog = S.t; log("guard: waiting for the others at local %.0f,%.0f", x, y) end
    return true
end
local clientGuard = guard

-- Votes (vote mode). Standing in the zone just before a line is a vote for that way; walking away takes it back.
local FORWARD_ZONE = { FORWARD_X - 280, FORWARD_X - 40 }   -- local x range, in the exit corridor band
local BACK_ZONE = { ANO_X - 45, ANO_X + 40 }                -- local x range, in the cross corridor band (after the roll)
local function myVote(pos)
    local path = Bot.pathAt(pos)
    if not path then return "none" end
    local x, y = Bot.toLocal(path, pos)
    if y > FORWARD_Y0 and y < FORWARD_Y1 and x >= FORWARD_ZONE[1] and x <= FORWARD_ZONE[2] then return "forward" end
    if S.anoDone and y > BACK_Y0 and y < BACK_Y1 and x >= BACK_ZONE[1] and x <= BACK_ZONE[2] then return "back" end
    return "none"
end

-- Vote signs: a floating label at each line while someone stands there ("FORWARD 1/2"). Drawn on every PC from the
-- votes it knows (the host relays each client's V to the others).
local Signs, SignText = {}, {}   -- dir -> TextRenderActor, dir -> text shown
local SIGN_AT = { forward = { FORWARD_X - 120, 4245, 235, 180 }, back = { BACK_X + 120, 735, 235, 0 } }   -- local x, y, z, yaw
local function updateSigns(pos)
    local path = pos and Bot.pathAt(pos)
    local counts, total = { forward = 0, back = 0 }, 1
    if S.myVote == "forward" or S.myVote == "back" then counts[S.myVote] = counts[S.myVote] + 1 end
    for _, p in pairs(S.peers) do
        total = total + 1
        local v = p.vote
        if v and v.seq == S.seq and counts[v.vote] then counts[v.vote] = counts[v.vote] + 1 end
    end
    for dir, at in pairs(SIGN_AT) do
        local a = Signs[dir]
        local show = cfg.choice == "vote" and path and counts[dir] > 0
        if show and not valid(a) then
            local pc = FindFirstOf("GamePC_C")
            local cls = StaticFindObject("/Script/Engine.TextRenderActor")
            if valid(pc) and valid(cls) then
                a = pc:GetWorld():SpawnActor(cls, { X = 0, Y = 0, Z = 0 }, { Pitch = 0, Yaw = 0, Roll = 0 })
                if valid(a) then
                    local tr = a.TextRender
                    pcall(function()
                        tr:SetWorldSize(22)
                        tr:SetHorizontalAlignment(1)   -- centre
                        tr:SetTextRenderColor({ R = 255, G = 236, B = 120, A = 255 })
                    end)
                    Signs[dir] = a
                end
            end
        end
        if valid(a) then
            a:SetActorHiddenInGame(not show)
            if show then
                local w = Bot.toWorld(path, at[1], at[2])
                a:K2_SetActorLocation({ X = w.X, Y = w.Y, Z = at[3] }, false, {}, true)
                a:K2_SetActorRotation({ Pitch = 0, Yaw = path:K2_GetActorRotation().Yaw + at[4], Roll = 0 }, true)
                local text = string.format("%s %d/%d", dir == "forward" and "FORWARD" or "TURN BACK", counts[dir], total)
                if SignText[dir] ~= text then
                    local ok, err = pcall(function() a.TextRender:K2_SetText(FText(text)) end)
                    if not ok then log("sign text failed: %s", tostring(err)) end
                    SignText[dir] = text
                end
            end
        end
    end
end

-- Host: everyone connected (host included) must stand at the same line, on the same corridor.
local function votesAgree()
    local mine = S.myVote or "none"
    if mine == "none" then return nil end
    if mutant("vote1") then return mine end   -- lab mutant: commit on the host's vote alone
    for id, p in pairs(S.peers) do
        local v = p.vote
        if not v or v.vote ~= mine or v.seq ~= S.seq then return nil end
    end
    return mine
end
local function voteSummary()
    local parts = { string.format("%d:%s", Net.myId, S.myVote or "none") }
    local ids = {}
    for id in pairs(S.peers) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local v = S.peers[id].vote
        parts[#parts + 1] = string.format("%d:%s", id, v and v.seq == S.seq and v.vote or "none")
    end
    return table.concat(parts, ",")
end

local function clientApply(pawn, pos)
    if S.applying then
        local a = S.applying
        a.i = a.i + 1
        local pt = CROSS[a.dir][a.i]
        if pt then
            local w = Bot.toWorld(a.frame, pt[1], pt[2])
            pawn:K2_SetActorLocation({ X = w.X, Y = w.Y, Z = pos.Z }, false, {}, true)
        elseif a.i > #CROSS[a.dir] + 8 then   -- let the game finish its transition first
            if a.dir == "ano" then
                clearForcedRoll()
                S.anoDone = true
                local now = anomaly()
                log("applied host anomaly %s/%s (mine now %s/%s)", tostring(a.change), tostring(a.tag), tostring(now and now.change), now and now.tag or "?")
            else
                S.seq = a.seq
                S.anoDone = false
                S.lastAppliedDir = a.dir
                log("applied host choice %s (seq %d)", a.dir, a.seq)
            end
            S.applying = nil
            S.lastLocal = nil
        end
        return
    end
    local d = table.remove(S.pendingDecisions, 1)
    if not d then return end
    -- The host's corridor: the one around the host's position (same coordinates here), else the one we stand in.
    local hp
    for _, p in pairs(S.peers) do if p.pose and not hp then hp = p.pose end end
    local frame = (hp and Bot.pathAt({ X = hp.x, Y = hp.y })) or Bot.pathAt(pos)
    if not frame then log("cannot apply %s: no corridor found", d.dir) return end
    Bot.stop()
    if d.dir == "ano" then forceNextRoll(d.change, d.tag) end
    S.applying = { dir = d.dir, seq = d.seq, frame = frame, i = 0, change = d.change, tag = d.tag }
end

local function clientCorrect(now)
    local h = S.host
    if not h or S.applying or #S.pendingDecisions > 0 or h.seq ~= S.seq then S.mismatchSince = nil; S.floorMismatchSince = nil return end
    local ps = gamePS()
    if ps and ps.FloorNumber ~= h.floor and not mutant("nofloorsync") then
        S.floorMismatchSince = S.floorMismatchSince or now
        if now - S.floorMismatchSince > 1.5 then
            log("exit count %d -> host's %d", ps.FloorNumber, h.floor)
            ps.FloorNumber = h.floor
            S.floorMismatchSince = nil
        end
    else
        S.floorMismatchSince = nil
    end
    local a = anomaly()
    if a and S.anoDone and (a.change ~= h.change or (h.change and a.tag ~= h.tag)) then
        S.mismatchSince = S.mismatchSince or now
        if now - S.mismatchSince > 1.0 then
            -- Not patched after the fact: the game judges the next choice by its own roll, so the roll itself is
            -- forced (forceNextRoll). A mismatch here is a bug to report.
            log("anomaly differs from host: mine %s/%s, host %s/%s", tostring(a.change), a.tag, tostring(h.change), h.tag)
            S.mismatchSince = now + 5
        end
    else
        S.mismatchSince = nil
    end
end

------------------------------------------------------------------------------ lab tours (E8T_LAB=1 only)
local Tour = { leg = 0, idle = 0, plan = {} }
for c in (os.getenv("E8T_PLAN") or "smart,smart,smart,smart,smart"):gmatch("[^,]+") do Tour.plan[#Tour.plan + 1] = c end
Bot.setLog(function(m) log("%s", m) end)

local ZONE_WALK = {
    forward = { { 1120, 4245 }, { 1640, 4245 } },   -- from the long corridor to just before the forward line
    back = { { 1120, 735 }, { 560, 735 } },         -- from the long corridor to just before the turn-back line
}

-- Vote-mode tour: the host walks to the right line and waits for everyone; the client follows the host's vote, except
-- once (second corridor) where it first stands at the opposite line for 8 s: a split vote that must not commit.
local function voteTourTick(dt)
    local pos = myPos()
    if not pos then return end
    local path = Bot.pathAt(pos)
    local lx = path and Bot.toLocal(path, pos) or 0
    if S.role == "host" then
        if next(S.peers) == nil or S.t < 20 or S.hostApplying then return end
        if Tour.waitSeq then
            if S.seq > Tour.waitSeq then
                Bot.continueAfter(Tour.dir, 1500)
                Tour.waitSeq = nil
            end
            return
        end
        if Bot.busy() then Tour.idle = 0 return end
        Tour.idle = Tour.idle + dt
        if Tour.idle > 6 and Tour.leg < #Tour.plan then
            Tour.idle = 0
            Tour.leg = Tour.leg + 1
            local a = anomaly()
            Tour.dir = (a and a.change) and "back" or "forward"
            Tour.waitSeq = S.seq
            log("tour leg %d: going to the %s line", Tour.leg, Tour.dir)
            Bot.walkLocalPath(ZONE_WALK[Tour.dir])
        elseif Tour.idle > 8 and Tour.leg >= #Tour.plan and not Tour.done then
            Tour.done = true
            evidence("CHECK", "tour-done legs=%d", Tour.leg)
        end
        return
    end
    -- client
    if S.applying or S.t < 20 then return end
    if S.lastAppliedDir and Tour.continuedSeq ~= S.seq then
        Tour.continuedSeq = S.seq
        Bot.continueAfter(S.lastAppliedDir, 1300)
        return
    end
    if Bot.busy() then return end
    local hv = S.peers[1] and S.peers[1].vote
    local inCorridor = lx > 1000 and lx < 1250
    if S.anoDone and hv and hv.seq == S.seq and (hv.vote == "forward" or hv.vote == "back") then
        local want = hv.vote
        if S.seq == 1 and not Tour.splitDone then
            if not Tour.splitAt and inCorridor then
                want = want == "forward" and "back" or "forward"
                Tour.splitAt = S.t
                evidence("CHECK", "split-start host=%s client=%s seq=%d", hv.vote, want, S.seq)
                log("tour: client votes the other way on purpose")
                Bot.walkLocalPath(ZONE_WALK[want])
                return
            elseif Tour.splitAt and S.t - Tour.splitAt > 12 then
                Tour.splitDone = true
                evidence("CHECK", "split-end seq=%d", S.seq)
                -- walk back into the long corridor, then on to the host's line
                if S.myVote == "back" then
                    Bot.walkLocalPath({ { 1120, 735 }, { 1120, 4245 }, { 1640, 4245 } })
                else
                    Bot.walkLocalPath({ { 1120, 4245 }, { 1120, 735 }, { 560, 735 } })
                end
                return
            elseif Tour.splitAt then
                return
            end
        end
        if S.myVote ~= want and inCorridor then
            log("tour: client joins the host at the %s line", want)
            Bot.walkLocalPath(ZONE_WALK[want])
        end
        return
    end
    -- just synced in the cross corridor: walk into the long corridor
    if path then
        local _, ly = Bot.toLocal(path, pos)
        if lx > 560 and lx < 1000 and ly > 500 and ly < 1000 then Bot.walkLocalPath({ { 1120, 735 }, { 1120, 1300 } }) end
    end
end

local function tourTick(dt)
    if not LAB or TOUR ~= "loop" then return end
    if cfg.choice == "vote" then return voteTourTick(dt) end
    if S.role == "host" then
        local connected = next(S.peers) ~= nil
        -- (the bot walks in frame())
        if not connected or S.t < 20 then return end
        if Bot.busy() then Tour.idle = 0 return end
        Tour.idle = Tour.idle + dt
        if Tour.idle > 6 and Tour.leg < #Tour.plan then
            Tour.idle = 0
            Tour.leg = Tour.leg + 1
            local choice = Tour.plan[Tour.leg]
            if choice == "smart" then   -- play it right: turn back on an anomaly (wrong turn-backs move the next corridor elsewhere; the bot cannot route that)
                local a = anomaly()
                choice = (a and a.change) and "back" or "forward"
            end
            log("tour leg %d: %s", Tour.leg, choice)
            Bot.go(choice, 1500)
        elseif Tour.idle > 8 and Tour.leg >= #Tour.plan and not Tour.done then
            Tour.done = true
            evidence("CHECK", "tour-done legs=%d", Tour.leg)
        end
    elseif S.role == "client" and not S.applying and not Bot.busy() and S.t > 20 then
        -- Stand a little behind the host in the same corridor so each sees the other.
        local hp
        for _, p in pairs(S.peers) do if p.pose then hp = p.pose end end
        local pos = myPos()
        -- Once per corridor, try to leave through the forward exit alone: the guard must hold the client back.
        if pos and S.seq >= 1 and S.anoDone and Tour.escapedSeq ~= S.seq then
            local p = Bot.pathAt(pos)
            if p then
                local lx = Bot.toLocal(p, pos)
                local _, ly = Bot.toLocal(p, pos)
                if lx > 560 and lx < 1000 and ly > 500 and ly < 1000 then   -- just synced in the cross corridor: walk in
                    Bot.walkLocalPath({ { 1120, 735 }, { 1120, 1300 } })
                    return
                end
                if lx > 1000 and lx < 1250 then
                    Tour.escapedSeq = S.seq
                    log("tour: client tries the forward exit alone (seq %d)", S.seq)
                    Bot.walkLocalPath({ { 1120, 4245 }, { 1900, 4245 } })
                    return
                end
            end
        end
        if hp and pos and hp.seq == S.seq then
            local path = Bot.pathAt({ X = hp.x, Y = hp.y })
            local mine = Bot.pathAt(pos)
            if path and mine and path:GetAddress() == mine:GetAddress() then
                local hx, hy = Bot.toLocal(path, { X = hp.x, Y = hp.y })
                local mx, my = Bot.toLocal(path, pos)
                -- only inside the long corridor (x 1000..1250), where a straight walk stays on the floor
                if hx > 1000 and hx < 1250 and mx > 1000 and mx < 1250 and math.abs(hy - 250 - my) > 150 then
                    Bot.walkLocal(1120, math.max(800, hy - 250))
                end
            end
        end
    end
    -- (the bot walks in frame())
end

------------------------------------------------------------------------------ main tick
local lastTick = os.clock()
local function tick()
    S.t = S.t + 0.1
    local dt = 0.1
    Net.poll(onLine)
    local pos, pawn = myPos()
    local gs = gameGS()
    if gs and gs:GetAddress() ~= S.gsAddr then
        if S.gsAddr then
            S.run = S.run + 1; S.seq = 0; S.pendingDecisions = {}; S.applying = nil; S.host = nil
            S.lastRestartAt = S.t
            Bot.stop()
            log("level restarted (run %d)", S.run)
            if S.expectRestart then S.expectRestart = false
            elseif S.role ~= "off" then Net.send(string.format("R|%d|%d", Net.myId, S.run)) end
            clearForcedRoll()
        end
        S.gsAddr = gs:GetAddress()
        S.anoDone = true
    end
    if pos and S.role ~= "off" then
        -- votes (both roles): send on change and once a second
        local vote = (cfg.choice == "vote") and myVote(pos) or "none"
        if vote ~= S.myVote or S.t - (S.lastVoteSent or 0) >= 1 then
            if vote ~= S.myVote then log("my vote: %s", vote) end
            S.myVote = vote
            S.lastVoteSent = S.t
            Net.send(string.format("V|%d|%d|%s", Net.myId, S.seq, vote))
        end
        if S.role == "host" then
            -- vote mode: walls for the host too; when everyone stands at the same line, walk the host across it
            if cfg.choice == "vote" and not S.hostApplying then
                guard(pawn, pos)
                local agreed = votesAgree()
                if agreed then
                    local frame = Bot.pathAt(pos)
                    if frame then
                        evidence("CHECK", "commit dir=%s seq=%d votes=%s", agreed, S.seq, voteSummary())
                        log("everyone chose %s", agreed)
                        Bot.stop()
                        S.hostApplying = { dir = agreed, frame = frame, i = 0 }
                    end
                end
            end
            if S.hostApplying then
                local a = S.hostApplying
                a.i = a.i + 1
                local pt = CROSS[a.dir][a.i]
                if pt then
                    local w = Bot.toWorld(a.frame, pt[1], pt[2])
                    pawn:K2_SetActorLocation({ X = w.X, Y = w.Y, Z = pos.Z }, false, {}, true)
                elseif a.i > #CROSS[a.dir] + 8 then
                    S.hostApplying = nil
                end
            end
            local dir = detectCrossing(pos)
            if dir == "ano" then
                S.anoAt = S.t   -- the roll happens in the trigger's handler; read it a moment later
                S.anoDone = true
            elseif dir then
                S.seq = S.seq + 1
                S.anoDone = false   -- the next corridor's roll is still ahead (no back votes before it)
                Net.send(string.format("D|%d|%d|%s", Net.myId, S.seq, dir))
                log("host choice %s (seq %d)", dir, S.seq)
            end
            if S.anoAt and S.t - S.anoAt >= 0.5 then
                S.anoAt = nil
                local a = anomaly()
                if a then
                    Net.send(string.format("A|%d|%d|%d|%s", Net.myId, S.seq, a.change and 1 or 0, a.tag))
                    log("host anomaly %s/%s (seq %d)", tostring(a.change), a.tag, S.seq)
                end
            end
        elseif S.role == "client" then
            if not S.applying then
                clientGuard(pawn, pos)
                -- Evidence: a client must never cross a host-owned line by itself (lab check "choices").
                local own = detectCrossing((myPos()))
                if own and own ~= "ano" then evidence("CHECK", "client-own-choice %s seq=%d", own, S.seq) end
            end
            clientApply(pawn, pos)
            clientCorrect(S.t)
        end
        if S.role == "host" and S.t - S.lastState >= 0.5 then
            S.lastState = S.t
            local ps, a = gamePS(), anomaly()
            if ps and a then Net.send(string.format("S|%d|%d|%d|%d|%s|%d", Net.myId, S.seq, ps.FloorNumber, a.change and 1 or 0, a.tag, S.run)) end
        end
        finishPuppet()
        updateSigns(pos)
        tourTick(dt)
    end
    if LAB and math.floor(S.t * 10 + 0.5) % 10 == 0 then
        local ps, a = gamePS(), anomaly()
        local pp, peerPose, anim = "-", "-", "-"
        for _, p in pairs(S.peers) do
            if valid(p.puppet) then
                local l = p.puppet:K2_GetActorLocation(); pp = string.format("%.0f,%.0f,%.0f", l.X, l.Y, l.Z)
                if valid(p.smc) then
                    -- clip, its play position and the left foot's height above the puppet's feet: proof the bones move
                    local okp, apos = pcall(function() return p.smc:GetPosition() end)
                    local foot = p.smc:GetSocketLocation(FName("foot_l"))
                    -- smoothness of the last second: frames walking, coefficient of variation of the per-frame speed
                    -- (stop-go movement gives a high value), share of frames that moved
                    local m, sm = p.smooth, "-"
                    if m and m.n >= 5 then
                        local mean = m.s / m.n
                        local var = math.max(0, m.s2 / m.n - mean * mean)
                        sm = string.format("%d:%.2f:%.2f", m.n, mean > 0 and math.sqrt(var) / mean or 9, m.moved / m.n)
                    end
                    p.smooth = nil
                    anim = string.format("%s/%.2f/%.1f/%.0f/%s/%.0f", p.anim or "none", okp and apos or -1, foot.Z - l.Z, p.speed or 0, sm,
                        (p.delay or 0) * 1000)
                end
            end
            if p.pose then peerPose = string.format("%.0f,%.0f,%.0f", p.pose.x, p.pose.y, p.pose.z) end
        end
        evidence("STATE", "wall=%d t=%.0f role=%s id=%d seq=%d run=%d floor=%s change=%s tag=%s me=%s peer=%s puppet=%s applying=%s anim=%s votes=%s signs=%s",
            os.time(), S.t, S.role, Net.myId, S.seq, S.run, ps and tostring(ps.FloorNumber) or "-", a and tostring(a.change) or "-", a and a.tag or "-",
            pos and string.format("%.0f,%.0f,%.0f", pos.X, pos.Y, pos.Z) or "-", peerPose, pp,
            (S.applying and S.applying.dir) or (S.hostApplying and S.hostApplying.dir) or "-", anim, voteSummary(),
            ((valid(Signs.forward) and not Signs.forward.bHidden) and (SignText.forward or "?"):gsub(" ", "_") or "-") .. "|" ..
            ((valid(Signs.back) and not Signs.back.bHidden) and (SignText.back or "?"):gsub(" ", "_") or "-"))
    end
    Net.flush()
end

-- Per-frame work: network in/out and puppets. Poses go out at 20 Hz with the sender's clock.
local lastFrame, lastPoseSent = os.clock(), 0
local function frame()
    local now = os.clock()
    local dt = math.min(0.1, now - lastFrame)
    lastFrame = now
    Net.poll(onLine)
    if S.role ~= "off" then
        local pos = myPos()
        if pos and now - lastPoseSent >= 0.05 then
            lastPoseSent = now
            local yaw = 0
            local pc = FindFirstOf("GamePC_C")
            if valid(pc) then yaw = pc:GetControlRotation().Yaw end
            Net.send(string.format("P|%d|%d|%.1f|%.1f|%.1f|%.0f|%.3f", Net.myId, S.seq, pos.X, pos.Y, pos.Z, yaw, now))
        end
        updatePuppets(now, dt)
        if LAB and not S.applying then Bot.step(dt) end
    end
    Net.flush()
end

start()
Net.flush()
-- One loop on the game thread runs everything: per-frame work every frame, the game logic (tick) every 100 ms.
-- Never also run Lua from LoopAsync: its callback executes on UE4SS's async thread in the same Lua state, and running
-- Lua on two threads at once corrupted values (measured 2026-11-14: "write got FILE*", "call a string value").
local tickAcc = 0
local function runFrame()
    local before = lastFrame
    local ok, err = pcall(frame)
    if not ok then evidence("MODERROR", "frame: %s", tostring(err)) end
    tickAcc = tickAcc + math.min(0.25, lastFrame - before)
    if tickAcc >= 0.1 then
        tickAcc = tickAcc - 0.1
        if tickAcc > 0.1 then tickAcc = 0 end   -- slow frames: don't run several ticks back to back
        local ok2, err2 = pcall(tick)
        if not ok2 then evidence("MODERROR", "%s", tostring(err2)) end
    end
end
if type(LoopInGameThreadAfterFrames) == "function" then
    LoopInGameThreadAfterFrames(1, function() runFrame(); return false end)   -- UE4SS v4: once per game frame
    log("running every frame on the game thread")
else
    LoopAsync(16, function() ExecuteInGameThread(runFrame); return false end)
    log("running at about 60 Hz (LoopAsync fallback; older UE4SS)")
end
log("loaded from %s", modDir)
