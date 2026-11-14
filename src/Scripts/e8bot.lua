-- Lab bot for The Exit 8 (no keyboard): walks the pawn along the corridor in 40 cm swept steps so the game's own
-- triggers fire exactly as they do for a walking player. Waypoints are in a corridor's local frame (BP_PathBP1_C):
--   entry (-195,0) -> cross corridor (-195,735) -> (1120,735) -> long corridor (1120, y) -> (1120,4245)
--   -> exit corridor (2385,4245) -> next corridor's entry (2385,4980).
-- Turning back leaves through the entry; the game then places the other corridor there, rotated.
local Bot = {}
local queue = {}
local log = function() end

local function toWorld(path, x, y)
    local o = path:K2_GetActorLocation()
    local yaw = math.rad(path:K2_GetActorRotation().Yaw)
    local c, s = math.cos(yaw), math.sin(yaw)
    return { X = o.X + x * c - y * s, Y = o.Y + x * s + y * c }
end

local function toLocal(path, w)
    local o = path:K2_GetActorLocation()
    local yaw = math.rad(path:K2_GetActorRotation().Yaw)
    local c, s = math.cos(yaw), math.sin(yaw)
    local dx, dy = w.X - o.X, w.Y - o.Y
    return dx * c + dy * s, -dx * s + dy * c
end
Bot.toWorld, Bot.toLocal = toWorld, toLocal

-- The corridor whose footprint contains the point (ties: nearest to the long corridor).
function Bot.pathAt(w)
    local best, bd
    for _, p in ipairs(FindAllOf("BP_PathBP1_C") or {}) do
        if p:IsValid() then
            local lx, ly = toLocal(p, w)
            if lx > -450 and lx < 2650 and ly > -60 and ly < 4990 then
                local d = (lx - 1120) ^ 2 + (ly - 2400) ^ 2
                if not bd or d < bd then best, bd = p, d end
            end
        end
    end
    return best
end

local function otherPath(p)
    for _, q in ipairs(FindAllOf("BP_PathBP1_C") or {}) do
        if q:IsValid() and q:GetAddress() ~= p:GetAddress() then return q end
    end
end

function Bot.pawn()
    local pc = FindFirstOf("GamePC_C")
    if not (pc and pc:IsValid()) then return nil end
    local pawn = pc:K2_GetPawn()
    if pawn and pawn:IsValid() then return pawn end
end

-- Queue entries are {path=<frame resolver>, x, y}; the frame is resolved when the step is reached, because the
-- game moves the other corridor only once the player crosses the decision trigger.
function Bot.go(choice, stopY)
    local pawn = Bot.pawn()
    if not pawn then return false end
    local p = Bot.pathAt(pawn:K2_GetActorLocation())
    if not p then log("bot: not in a corridor") return false end
    queue = {}
    local function add(frame, x, y) queue[#queue + 1] = { frame = frame, x = x, y = y } end
    local here = function() return p end
    local nextp = function() return otherPath(p) end
    if choice == "forward" then
        add(here, 1120, 4245); add(here, 2385, 4245); add(here, 2385, 4990)
    elseif choice == "back" then
        add(here, 1120, 735); add(here, -195, 735); add(here, -195, -10)
    else
        return false
    end
    add(nextp, -195, 60); add(nextp, -195, 735); add(nextp, 1120, 735); add(nextp, 1120, stopY or 1700)
    log("bot: " .. choice)
    return true
end

-- After the group crossed a choice line (vote mode): finish leaving this corridor and walk into the next one.
function Bot.continueAfter(choice, stopY)
    local pawn = Bot.pawn()
    if not pawn then return false end
    local p = Bot.pathAt(pawn:K2_GetActorLocation())
    if not p then log("bot: not in a corridor") return false end
    queue = {}
    local function add(frame, x, y) queue[#queue + 1] = { frame = frame, x = x, y = y } end
    local here = function() return p end
    local nextp = function() return otherPath(p) end
    if choice == "forward" then add(here, 2385, 4245); add(here, 2385, 4990)
    else add(here, -195, 735); add(here, -195, -10) end
    add(nextp, -195, 60); add(nextp, -195, 735); add(nextp, 1120, 735); add(nextp, 1120, stopY or 1700)
    log("bot: continue after " .. choice)
    return true
end

-- Walk to a point in the current corridor's frame (used by tours to stand somewhere specific).
function Bot.walkLocal(x, y)
    local pawn = Bot.pawn()
    if not pawn then return false end
    local p = Bot.pathAt(pawn:K2_GetActorLocation())
    if not p then return false end
    queue = { { frame = function() return p end, x = x, y = y } }
    return true
end

-- Walk a list of {x, y} points in the current corridor's frame.
function Bot.walkLocalPath(points)
    local pawn = Bot.pawn()
    if not pawn then return false end
    local p = Bot.pathAt(pawn:K2_GetActorLocation())
    if not p then return false end
    queue = {}
    for _, q in ipairs(points) do queue[#queue + 1] = { frame = function() return p end, x = q[1], y = q[2] } end
    return true
end

function Bot.busy() return queue[1] ~= nil end
function Bot.stop() queue = {} end
function Bot.setLog(f) log = f end

Bot.SPEED = 300   -- cm/s, a steady walk

-- Call every frame with the frame time, so the bot walks smoothly like a player (other copies judge puppet
-- smoothness from this movement). Steps are capped at 40 cm so overlaps still fire.
function Bot.step(dt)
    local q = queue[1]
    if not q then return end
    local pawn = Bot.pawn()
    if not pawn then return end
    local frame = q.frame()
    if not (frame and frame:IsValid()) then return end
    local t = toWorld(frame, q.x, q.y)
    local l = pawn:K2_GetActorLocation()
    local dx, dy = t.X - l.X, t.Y - l.Y
    local d = math.sqrt(dx * dx + dy * dy)
    if d < 20 then table.remove(queue, 1); return end
    local s = math.min(40, Bot.SPEED * (dt or 0.1), d)
    pawn:K2_SetActorLocation({ X = l.X + dx / d * s, Y = l.Y + dy / d * s, Z = l.Z }, false, {}, false)  -- no sweep: UE4SS v3 crashed filling the FHitResult
    local l2 = pawn:K2_GetActorLocation()
    if math.abs(l2.X - l.X) + math.abs(l2.Y - l.Y) < 1 then
        q.stuck = (q.stuck or 0) + 1
        if q.stuck > 20 then log(string.format("bot: stuck at %.0f,%.0f, skipping waypoint", l.X, l.Y)); table.remove(queue, 1) end
    end
end

return Bot
