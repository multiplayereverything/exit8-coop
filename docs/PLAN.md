# Exit 8 Together: polish plan (2026-11-14)

Owner feedback after the first visible two-window test: "looks unpolished", players move stiffly and laggy, and the
choice should need everyone (all go forward → forward, all turn back → back).

## Why it looks the way it does now (from the code)
- Puppets are moved inside the mod's 100 ms timer, so on screen they step 10 times a second whatever the frame
  rate; each step lerps 100% of the way at 10 Hz (`updatePuppets`, `k = dt * 10`).
- Poses are sent at 10 Hz and the puppet chases the newest one: no playback buffer, so it lags and stutters with
  any jitter.
- Facing snaps to the view yaw each step; walk/idle switch with a hard cut.
- The host's choice teleports clients who are elsewhere (the "pull"), which feels like a glitch.

## Phase 1: the choice (voting)
Rule: **the group goes the way everyone chose.**
- Each player's choice lines (forward exit, turn-back line) act as a ballot box: walking into one marks your vote
  and the invisible wall (already built for clients) holds you just before the line. The host gets the same wall.
- When every connected player stands at the same line, the host's game crosses it and everyone else is walked
  across theirs in the same moment (the existing apply path; the pull is now a few cm, not a teleport).
- Split votes (one forward, one back): nothing happens; each player sees "Waiting: Host is at the exit, Client is
  going back". Walking away from a line takes your vote back.
- Optional host setting `choice = vote | host` (vote is the default).
- On-screen status in the corridor: a 3D text near each line ("1/2 ready") using a TextRender actor, so it fits the
  game's signage and needs no UI framework.
- Lab: the bot walks both players to the same line (pass) and to different lines (must not commit; a mutant that
  commits on the first vote must fail).

## Phase 2: smooth, natural players
1. Move puppets every frame: a separate fast game-thread loop (about 60 Hz) that only interpolates puppets.
2. Snapshot interpolation: render the remote player about 100 ms in the past between two received poses (Baldi
   0.9.4 style: delay = average gap + 4 x jitter, clamped 0.06-0.25 s), with short extrapolation if a packet is late.
3. Send poses at 20 Hz with a timestamp, plus velocity.
4. Smooth turning (yaw slerp), body faces the movement direction while walking and the view direction while still;
   head/look pitch if the skeleton allows it.
5. Animation: play rate from real speed (already), short walk-start/stop delay so it doesn't flicker; check the
   real player walk speed in the game and set the clip speed to match (no foot sliding).
6. Footstep sounds at the puppet using the game's own footstep cues (ProFirstPersonHorror Footsteps), on foot plants.
7. Lab: measure puppet frame-to-frame step size and the error against the true path (smoothness check with a
   mutant that turns interpolation off).

## Phase 3: make it a real co-op game
- **In-game menu** (Host / Join / Steam friends) instead of config.txt; join through Steam invites and "Join Game"
  on the profile; on-screen connection status and "X joined / left".
- **Steam lobby + P2P test** with a second account (code exists, never run).
- **Ping/point**: a key that marks a spot for everyone ("look here"), the core co-op action in a spot-the-difference
  game. Small glowing marker that fades after a few seconds.
- **Proximity voice** through Steam Voice (ISteamUser voice capture), quieter with distance; optional.
- **Name tags and colours** per player (TextRender above the head, a tint on the puppet's material).
- **Caught together**: show who got caught ("Client was caught") during the restart fade.
- **Exit 8 ending together**: when the group reaches exit 8, everyone walks out and sees the ending.
- **Late join / reconnect**: a joiner gets the host's run state (exit count and corridor layout) or both restart.
- **Saves**: clients don't write clear progress or anomaly lists; the host's save is the truth.

## Phase 4: optional modes (ideas)
- **Split roles**: one player sees anomalies, the other has to guess from their description (asymmetric, voice-based).
- **Versus**: same corridor, each votes alone; first to exit 8 wins.
- **Hard mode**: more than two corridors in a row with anomalies, or a vote timer.

## Order proposed
1. Phase 2 items 1-3 (smoothness): biggest visible win, small change.
2. Phase 1 voting + corridor status text.
3. Phase 2 items 4-6.
4. Phase 3 menu and Steam test, then the rest.
Each step ends with a lab check that can fail and a short visible two-window session for the owner to look at.
