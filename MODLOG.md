# MODLOG: Exit 8 Together

Anything not written here is lost at the next context reset.

## 2026-11-13: first pass (0.1.0, protocol 1)

Environment: The Exit 8 build 22450204, UE 5.2.1, UE4SS v3.0.1, Windows 11, VS 2022 Build Tools, Python 3.14.

Research: Co-op Anything directory/DIRECTORY.md, GitHub, web: no Exit 8 co-op work (only a Mokobake Exit 8 mod
without source, and fan clones). Hub UE notes: Poppy Playtime (UE4SS Lua + Python relay), Genesis Alpha One (engine
netcode via `open ?listen`). Decision: build from zero with UE4SS Lua + own native transport; engine netcode not used
because the loop/anomaly logic is single-player Blueprint and would need the same syncing anyway.

Recon:
- `package.loadlib` is available in UE4SS Lua; UE4SS exports no `lua_*` symbols → native DLL loaded with "*" + file IPC.
- ReversePort reads the `.pak` (1,999 entries, Oodle) but not IoStore `.utoc`; retoc 0.1.5 `to-legacy` +
  kismet-analyzer to-json (minimal usmap) gave readable bytecode (private/bytecode).
- Crashes: probe `RegisterHook`s on BP functions → crash in the transition (bisected, hooks off = fine);
  `K2_SetActorLocation` sweep crashed; stale object read without IsValid crashed.
- SpawnActor works but returns nil; `summon` is a no-op in Shipping; `SetSkeletalMeshAsset` on 5.2.

Decisions:
- Host leads choices; client guard walls + walked across the same trigger (handoff "Design").
- Anomaly: force the client's own roll with BP_ChangeManager DEBUG fields (no after-the-fact patching).
- Group restart on any player caught; `R` carries the restart count (an earlier time-based echo guard dropped
  restarts: client ended on run 3 vs host run 5).
- Port 27080 (LAN default), 27180 lab, 27089 transport test.

Evidence:
- `tests/transport_test.py`: 7/7 PASS.
- Lab run 1: connected, no puppet (summon no-op), host bot never stepped (tour bug).
- Lab run 2: choices 3/3 and anomalies identical; verifier aligned logs by each copy's uptime (bug) → wall clock.
- Lab run 3: PASS but runs diverged after repeated host deaths (bot falling after a wrong turn-back) → restart count
  in R, bot stops on restart, verifier checks final runs, tour plays "smart".
- Lab run 4 (`loop`, 300 s): **PASS** connected; puppets 350/350 and 329/329 within 150 cm, client pose seen by host
  p90 0 cm over 327 s; choices 5/5; loopstate 291 agreeing / 0 disagreeing, restarts 0/0; 0 mod errors.

## 2026-11-14: guard and mutants

- Client tour now walks into the long corridor after each anomaly sync and tries the forward exit alone once per
  corridor; the client also logs `E8T-CHECK client-own-choice` if it ever crosses a host-owned line itself, and the
  verifier's `choices` check fails on any.
- Decision: the `noguard` mutant first SURVIVED (only 1 bad second) because the exit-count correction fixed the
  client's floor within 1.5 s; the failure is now measured directly (own choices) instead of through loop state.
- stop-lab waits for the copies to exit (a log copy hit a lock); run-tour log copies retry.
- Lab-made `%LOCALAPPDATA%\Exit8` (saves, config, crash folders from killed copies) moved to
  `private\lab-saved-20261114`: the user had never launched the game, so the first real launch is fresh.

Evidence:
- `loop-151837` PASS (client walking in; guard "waiting for the host at local 1760,4245"; puppet p90 80 cm).
- `loop-noanomalysync-152604`: loopstate FAIL 52/242 (host Mimick, client none) → killed.
- `loop-noguard-154102`: choices FAIL, 2 client-own choices; both copies restarted once together → killed.
- `loop-154812` clean: **PASS** connected; puppets 350/350, 334/334, client pose seen by host p90 160 cm over 325 s;
  choices 5/5, 0 own; loopstate 292/0, restarts 0/0; 0 mod errors.

## 2026-11-14: puppet animation, UE4SS v4.0.0

- Probes (`tools/recon/Exit8Anim`): on UE4SS v3.0.1 a SpawnActor-made SkeletalMeshActor never animates (clip
  position stays 0, bones fixed) even with tick forced on; AddComponentByClass components never register; the
  deferred spawn call failed. Control: the game's walking man animates in the minimized lab window (foot Z 16-30), so
  minimized copies do evaluate animation.
- UE4SS v4.0.0 (2026-11-12 release): SpawnActor returns the actor and it animates; Lua errors are readable.
- Clips on the scanned-person mesh: CitySample `MTN_N_Walk_F_noroot` plays (position 0.26 -> 2.02, foot Z 9.5..24.6);
  `FTN_N_Walk_F` is rejected; the scanned-person `Idle` is a single still pose; `MTN_N_Idle` plays (used for idle).
- Decision: move the mod and labs to v4.0.0 rather than work around v3. Puppet walks above 40 cm/s at play rate
  speed/150 (0.6..2.2) and idles below. Not the walking man's outfit: he is what players watch for anomalies.
- New verifier check `animation` and mutant `noanim`.

Evidence (UE4SS v4.0.0):
- `loop-080958` **PASS**: connected; puppets 352/352, 338/338, p90 90 cm; choices 5/5, 0 own; loopstate 296/0;
  animation: walking 62/65 and 79/80 s while the peer moved, idle 269/269 and 250/250 s still, foot range
  18.1/17.3 cm; 0 mod errors.
- `loop-noanim-081708`: animation FAIL (walking 0/67, 0/85) -> killed. noanomalysync/noguard were run on v3.0.1 and
  not rerun on v4.

## 2026-11-14: polish 1 (0.2.0, protocol 2): smooth puppets, voting, vote signs

Owner feedback after watching two windows: unpolished; stiff, laggy players; choice should need everyone.

- Smooth puppets: drawn every frame between two received poses about 60-250 ms in the past (snapshot interpolation,
  delay = gap + 4 x jitter), short extrapolation, snap on >3 m jumps; poses at 20 Hz with the sender's clock
  (`os.clock`, wall time on Windows); body faces the walking direction, view yaw when still; walk/idle hysteresis.
  The lab bot now walks every frame at 300 cm/s (it moved in 40 cm jumps, which would look stop-go even when smooth).
- Bug found and fixed: running Lua from both `LoopInGameThreadAfterFrames` (game thread) and `LoopAsync` (UE4SS's
  async thread) corrupted values ("write got FILE*", "call a string value", "index a number"); everything now runs
  from one game-thread loop, the 10 Hz logic every 100 ms of frames.
- Voting (default `choice = vote`): walls before both lines for everyone; zone before a line = vote; `V` messages;
  host commits when all votes agree on its `seq` and walks itself across (existing host-choice path then moves the
  clients). Signs: TextRenderActor per line, "FORWARD n/N" / "TURN BACK n/N", shown only while someone votes.
- Decision: the anomaly roll stays host-led (it isn't a choice).
- New checks `smooth`, `voting`; mutants `nosmooth`, `vote1`.

Evidence (UE4SS v4.0.0):
- `loop-120125` **PASS**: connected; puppets 382/383 and 372/372 within 150 cm; choices 5/5, 0 own; loopstate 339/0;
  voting 5 commits / 5 choices, all agreed, split held; smooth CV 0.11 / 0.10, moved on 100% of frames; animation
  walking 114/122 and 103/108 s, idle 253/253 and 263/263 s; 0 mod errors.
- Run with the thread race (before the fix): 4 mod errors, FAIL; its nosmooth run never connected (not counted).
- `loop-vote1-*`: voting FAIL, 5 commits without full agreement (e.g. `votes=1:forward,2:none`) -> killed.
- `loop-nosmooth-*` (after making the mutant draw a still puppet between its 10 Hz steps instead of skipping frames):
  smooth FAIL, CV 5.15, moved on 4% of frames -> killed. The first nosmooth run "failed" only for lack of samples; not
  counted. The mutant change touched only the mutant path, so `loop-120125` still stands for the normal build.

## 2026-11-14: puppet look

- Owner, after a visible session: the scanned woman looked scary (dead eyes close up) and her idle was an A-pose (the
  CitySample idle on her skeleton). Lineup probe (`tools/recon/Exit8Look`, shown in a visible window): A woman + her
  own still Idle, B grey mannequin `SKM_Manny` + CitySample idle, C mannequin walking, tinted. Measured: the mannequin
  plays the CitySample walk (feet move) and idle (hands drift); MI_Manny `Tint` takes a colour. Owner picked C.
- Puppet = SKM_Manny, `Tint` on both material slots per player id (1 blue, 2 orange, 3 green, 4 purple). New check `look`.

Evidence: `loop-*` after the change **PASS** all checks (look: host sees id 2 orange, client sees id 1 blue, 2 slots;
smooth CV 0.07 / 0.02; voting 5/5; loopstate 335/0; 0 errors).
