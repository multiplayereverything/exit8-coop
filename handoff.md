# Exit 8 Together: handoff

Co-op mod for **The Exit 8** (Steam 2653790). First pass 2026-11-13; polish pass 2026-11-14. Version 0.2.0, wire
protocol 2. Local git
only (GitHub hold: no push, release, PR or repo until the user says so in this session). Repo name chosen by the user:
`multiplayereverything/exit8-coop` (not created yet).

## Where things stand

| Item | State | Evidence |
|---|---|---|
| Mod loads in the game | ✅ proven | UE4SS **v4.0.0** loads `Exit8Together` (first pass ran on v3.0.1; moved to v4 on 2026-11-14 for puppet animation, full tour re-passed); `[E8T] loaded from ...` in every lab log |
| Networking DLL loads inside the game | ✅ proven | `package.loadlib(dll, "*")` works in UE4SS Lua; `e8net.log` "net thread up" |
| Offline transport test | ✅ 7/7 | `python -I tests/transport_test.py artifacts/build/e8net.dll` (LAN host/join, payload both ways, version refusal naming both versions, peer_left) |
| Two copies connect over LAN | ✅ proven | lab: `connected id=2` on the client, `peer_join id=2` on the host |
| Each sees the other (puppet at the other's real position) | ✅ proven in data | `puppets` check: puppet within 150 cm of the received pose on both copies, and the client's real position as seen by the host p90 0 cm over 327 s |
| Same loop state (exit count, anomaly on/off, anomaly tag) | ✅ proven | `loopstate`: 291 agreeing seconds, 0 disagreeing; anomalies Human.Face and Ceiling.Center.Smile rolled identically on the client |
| Voting: the group moves only when everyone stands at the same line | ✅ proven | run `loop-120125`: 5 commits for 5 choices, every one with all votes equal; the client's deliberate opposite vote (8+ s) held without a commit; signs read FORWARD 1/2, TURN BACK 1/2, FORWARD 2/2 |
| Smooth puppets (per frame, snapshot interpolation, 20 Hz poses) | ✅ proven | `smooth`: puppet moves on 100% of frames while walking, per-frame speed CV 0.10/0.11 (stop-go 10 Hz puppet: CV 9) |
| Host's choices drive the client (choice = host) | ✅ proven | `choices`: host made 5 (forward/back by anomaly), client applied 5, client made 0 choices of its own although it tried the forward exit alone 5 times (guard held it at local x 1760) |
| Group restart when someone is caught | ✅ seen in the lab | `noguard` mutant run: the unguarded client wandered off and fell, both copies restarted once (`restarts host 1 client 1`); earlier runs showed the client following host deaths. No dedicated tour/mutant yet |
| Puppets animate (walk while moving, idle while still) | ✅ proven | `animation` check, run `loop-080958` (v4): walking 62/65 and 79/80 s while the peer moved, idle 269/269 and 250/250 s while still; walk clip at 60/70 distinct positions, foot height range 18.1/17.3 cm; idle clip runs (244 positions) |
| Mutants | ✅ 5/5 killed (vote1, nosmooth added 2026-11-14) | `noanomalysync` → loopstate 242 disagreeing s (host Mimick, client none); `noguard` → 2 client-own choices, choices FAIL (both on v3.0.1); `noanim` → walking 0/67 and 0/85 s, animation FAIL (v4) |
| Puppet actually rendered on screen | ⚠️ not proven | lab windows are minimized, no screenshots; bones are measured moving, but nobody has looked at it |
| Steam lobby + Steam P2P | ⚠️ not proven | code written against the game's steam_api64 (SDK 1.53) exports; one Steam account can't P2P to itself; lobby creation not yet run |
| Two PCs, real keyboard/mouse, internet | ⚠️ not proven | lab only |
| Wrong turn-back, floor 8 exit ending, chasing anomalies killing only one player | ⚠️ not tested | the bot can't route a wrong turn-back (next corridor goes to `StartSpawnLoc`) |

Latest passing run: `private/runs/loop-154812` (2026-11-14; logs `host.log`, `client.log`, `*-net.log`), verifier
output in the MODLOG. Results came from a quiet PC (no other labs running).

## Design (why it works this way)

The Exit 8 is one looping corridor: walk the long corridor, decide if something is off, go forward (no anomaly) or
turn back (anomaly). A right choice adds one to the exit count, a wrong one resets it to 0, exit 8 opens the way out.

Co-op chosen: **one shared loop, the group votes** (owner's call, 2026-11-14; first pass was host-decides).
- Everyone walks the same corridor and sees the same anomaly, so spotting it is shared and players can talk it over.
- **Voting:** each player's forward exit and turn-back line are walled just before the line (the "guard"). Standing in
  the zone before a line is a vote for that way; walking away takes it back. When every connected player votes the
  same way on the same corridor (`seq`), the host's game walks the host across its own line and every client is
  walked across theirs, so the game's own transition code runs everywhere and the exit counts agree. Split votes do
  nothing. A sign at each line shows the count (TextRenderActor, "FORWARD 1/2").
- `choice = host` keeps the first-pass behaviour (the host's feet decide, clients are pulled).
- **Anomaly:** the host's game rolls it (unseeded RNG). The client's game must roll the same, because the game
  judges the next choice by its own `Change` flag. The developers left switches in `BP_ChangeManager`
  (`DEBUG_MODE`, `DEBUG_ANOMALY_ENABLE` 1/2, `DEBUG_ANOMALY_TYPE` index); the client sets them to the host's result and
  is walked across its own `Tri_Ano_Spawn`, so its own `RandomChange` produces the host's anomaly. No after-the-fact
  patching.
- **Caught by an anomaly:** everyone restarts together (`GameState.GameOver(1, 0.5, true)` = fade and reopen level).
- **Puppets:** each player streams position and view yaw at 20 Hz with its own clock, in world coordinates (the corridor layout is the
  same on every PC for the same choice sequence). The puppet is a `SkeletalMeshActor` with the game's own UE5 template mannequin
  (`SKM_Manny`), tinted per player (1 blue, 2 orange, 3 green, 4 purple; owner's pick over the scanned woman, whose
  face looked dead and whose idle was an A-pose), drawn every frame about 60-250 ms in the past between two received
  poses (snapshot interpolation; delay = gap + 4 x jitter), facing where it walks; it plays the game's CitySample walk `MTN_N_Walk_F_noroot` (in place, play
  rate = player speed / 150 cm/s, clamped 0.6..2.2) above 40 cm/s and `MTN_N_Idle` below; hidden while the two are in
  different loops. Not the walking man's own outfit on purpose: players watch him for anomalies.

Authority table:

| State | Owner |
|---|---|
| Forward/back choice, exit count, anomaly roll, level restart | host |
| Own body position and camera | each player |
| Saves | each PC's own game still saves (see "Not done") |

## Game facts (from recon; details in `private/bytecode/FINDINGS.md`, `private/recon/`)

- UE **5.2.1** (`++UE5+Release-5.2-CL-26001984`), build id 22450204, Shipping exe
  `Exit8\Binaries\Win64\Exit8-Win64-Shipping.exe` SHA-256 `f6aa68f1...cf52d`, launcher `Exit8.exe` `ff3f2d82...9190`.
  IoStore paks (Oodle), not encrypted. Steamworks SDK 1.53 (`Engine\Binaries\ThirdParty\Steamworks\Steamv153`),
  OnlineSubsystemSteam enabled. No anti-cheat. Boots straight into the corridor (no title menu).
- Saves: `%LOCALAPPDATA%\Exit8\Saved\SaveGames` (Save.sav, Setting.sav, Setting_Audio.sav). Logs aren't written by
  the Shipping build.
- Blueprints: `GM_Exit8_C`, `GameState_Exit8_C` (`GameOver`), `PlayerState_Exit8_C` (`FloorNumber` = exit count,
  `SetFloor`), `GamePC_C`, pawn `BP_FPHorrorCharacter_C`, `BP_ChangeManager_C` (`Change`, `CurrentChangeTag`,
  `RandomChange`, DEBUG fields), two `BP_PathBP1_C` corridors that leapfrog (`SpawnNextPath`, `ResetPath`), triggers
  are `Comp_TriggerBase_C` (StaticMeshComponent subclass).
- Corridor local frame (both corridors identical; second may be rotated 180°): entry (-195,0) → cross corridor y≈735
  → long corridor x≈1120 (y 735..4245) → exit corridor y≈4245 → next entry (2385,4980). Choice planes: `Tri_Susumu`
  x=1780 (y 3590..4590, forward), `Tri_Turn` x=459 (y 280..1280, back), `Tri_Ano_Spawn` x=556 (anomaly roll when
  left towards +X).

## Hooks

None. `RegisterHook` on several of these BP functions crashed UE4SS v3.0.1 during the corridor transition (not retried on v4)
(bisected: hooks off = no crash). Everything is polled at 10 Hz on the game thread and choices are detected by the
player crossing the trigger planes. Calls made into the game: `K2_GetActorLocation/SetActorLocation`,
`GetControlRotation`, `PlayerState.FloorNumber` (read, and written as a fallback correction), `BP_ChangeManager`
DEBUG fields, `GameState.GameOver`, `World:SpawnActor(SkeletalMeshActor)` + `SetSkeletalMeshAsset` +
`SetAnimationMode(1)` + `PlayAnimation`.

UE4SS traps found here: `SpawnActor` spawns but returns nil (diff `FindAllOf`); `summon` does nothing in Shipping;
`SetSkeletalMesh` isn't a UFunction on 5.x (`SetSkeletalMeshAsset`); `K2_SetActorLocation` with sweep crashed;
reading a stale object without `IsValid` crashed (access violation at 0x18).

## Networking

- `native/e8net.dll` (C++, built with VS 2022 Build Tools, static CRT) loaded by Lua with `package.loadlib(path, "*")`
  (UE4SS doesn't export the Lua C API, so it can't be a Lua C module). It runs its own thread; Lua and the DLL
  exchange numbered files in `Mods\Exit8Together\ipc` (`out.N` / `in.N`, written as .tmp then renamed).
- LAN/direct: TCP **27080** (no other mod uses it; lab uses 27180, transport test 27089). Length-prefixed frames,
  HELLO/WELCOME/REJECT handshake refusing a different version or protocol with both named, 1 s keepalive, 30 s
  timeout, 4 MB send queue limit, up to 4 players, host relays.
- Steam: friends-only lobby (`CreateLobby`), clients `JoinLobby`; data over `ISteamNetworkingMessages` channel 8 through
  the game's own `steam_api64.dll` (needs the game to have initialised SteamAPI); only lobby members are accepted.
  **Untested.** Join is by lobby id in `config.txt` for now (no invite / overlay join yet).
- Wire (protocol 2): `P|id|seq|x|y|z|yaw|senderClock`, `V|id|seq|vote`, `D|1|seq|forward/back`, `A|1|seq|change|tag`,
  `S|1|seq|floor|change|tag|run`, `R|id|restartCount`.

## How to run

```
scripts\build.ps1                       # native DLL + artifacts\mod\Exit8Together
python -I tests\transport_test.py artifacts\build\e8net.dll
scripts\setup-lab.ps1                   # private\lab-host, private\lab-client (hardlinks + junctions + UE4SS v4.0.0)
scripts\run-tour.ps1 [-Seconds 300]     # two copies, minimized 640x360 30 fps BelowNormal, verifier at the end
scripts\mutants.ps1                     # noanomalysync, noguard must each fail
scripts\run-probe.ps1 -Mod Exit8Probe   # one-copy recon mods in tools\recon
```
Deps (not committed): `deps\ue4ss-v4.0.0` (official `UE4SS_v4.0.0.zip`, SHA-256 251ad0d1...d81e45; mods, settings and
log live under `Win64\ue4ss\`), `deps\ue4ss-v3.0.1` (4b47d4bc...c57ec, first pass). Tools outside the repo (a sibling `tools-ext` folder) (ReversePort,
retoc 0.1.5, kismet-analyzer e8982e9).

Player install (manual for now): extract UE4SS v4.0.0 into `Exit8\Binaries\Win64` (gives `dwmapi.dll` + `ue4ss\`),
copy `Exit8Together` into `Win64\ue4ss\Mods`, add `Exit8Together : 1` to `ue4ss\Mods\mods.txt`, edit
`Exit8Together\config.txt` (`mode = host` or `join`).

## Lab notes

- Lab copies run the Shipping exe directly with `steam_appid.txt` and `SteamAppId` env; Steam must be running.
- The lab writes the game's saves in `%LOCALAPPDATA%\Exit8\Saved` (shared by both copies; `run-tour.ps1` backs them up
  and restores them). The user had never run the game before this session; the lab-made `Saved` folder was moved to
  `private\lab-saved-<date>` at the end so the first real launch is fresh.
- A wrong turn-back makes the bot fall (it can't route the `StartSpawnLoc` corridor), the game kills a falling
  player, and both restart. That's why the tour plays "smart" (back on anomaly).

## Not done / next steps

1. In-game UI (host/join menu, lobby list, invites); now config.txt only. No on-screen status.
2. Steam lobby + P2P test with a second account; Steam overlay join (`+connect_lobby`).
3. Clients must not write saves (the client's `ChangeFound` updates its own save lists and clear state).
4. The exit ending (floor 9 → `BP_Exit`): untested in co-op; host reaching the goal should take everyone.
5. A client killed alone by a chasing anomaly (Mimick, Human.Stalker) restarts everyone; check it feels right.
6. Puppet: name tag, colour, turning to face the movement direction; a screenshot proof that it renders.
7. Late join: a client joining mid-run starts at the corridor start while the host is elsewhere (puppet hidden until
   seq matches). Needs the host to send its run state or restart both on join.
8. rules-test.py, lag/chaos run, Co-op Anything entry (`game/the-exit-8`), README release notes, packaging.

## Checklist (from HOW_WE_BUILD_COOP_MODS.md §8)

- [x] Repo folder outside Steam, repo-local git identity, .gitignore
- [x] AGENTS.md, handoff.md, MODLOG.md, README.md, CLAUDE.md
- [x] Recon: app id, build id, exe SHA-256, engine version, Steamworks, saves, anti-cheat
- [x] coop-triage / coop-research (nothing exists; build from zero)
- [x] Decompile: UE4SS object dump + retoc/kismet-analyzer bytecode (private/)
- [x] Loader picked (UE4SS v4.0.0; v3.0.1 for the first pass) and probed
- [x] Design written (above)
- [x] Vertical slice: two copies see each other and share one action (the choice)
- [x] Lab copies, launch defaults, PIDs, tour lock, refuse beside the user's game
- [x] Tours in the mod behind E8T_LAB, E8T-* evidence, verify-lab.py
- [x] run-tour.ps1, mutants.ps1 (2/2 mutants killed)
- [ ] rules-test.py, lag/chaos, Steam path test
- [ ] Release items (on the user's word only)

## Launcher (2026-11-14)

- Sent to the "Multiplayer Mods Launcher" session: package `artifacts/release/Exit8Together-UE4SS-<ver>.zip`
  (entries `ue4ss/Mods/Exit8Together/...` relative to `Exit8\Binaries\Win64`), loader UE4SS v4.0.0.
- The launcher lists PC mods only from mods-info records with a downloadable, SHA-256-pinned release, so the entry
  waits for the first GitHub pre-release; the loader is to be mirrored as a `ue4ss-4.0.0` release in exit8-coop.
- Measured: UE4SS v4.0.0 starts the mod from its `enabled.txt` alone (stock mods.txt, no Exit8Together line):
  "Mod 'Exit8Together' has enabled.txt, starting mod." No mods.txt edit is needed.
