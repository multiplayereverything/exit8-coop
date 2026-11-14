# AGENTS.md: Exit 8 Together

Co-op mod for The Exit 8 (UE 5.2.1) as a UE4SS Lua mod plus a native networking DLL. Read `handoff.md` first; it is
the current truth. Shared method: `..\HOW_WE_BUILD_COOP_MODS.md` (read-only for this repo's sessions).

## Rules
- Karpathy guidelines, adapted: state assumptions in the handoff/MODLOG instead of asking; simplest change; surgical
  edits; every fix gets a check that can fail (a verifier check plus a mutant in `scripts/mutants.ps1`).
- Don't stop to ask the user; make the defensible call and log it (MODLOG "Decision").
- GitHub HOLD: commit locally only. No push, release, PR, issue or new repo until the user says so in this session.
  Repo (named by the user 2026-11-14, not created yet): `multiplayereverything/exit8-coop`. Commit as `multiplayereverything <347356261+multiplayereverything@users.noreply.github.com>`.
- Never commit or ship game files, extracted assets, bytecode dumps, object dumps (`private/`), loaders (`deps/`),
  build outputs, tokens or personal paths.
- Labs: hidden/minimized 640x360, 30 fps, BelowNormal, one lab at a time across all sessions (check for other games'
  copies first), never beside the user's own Exit 8. `scripts/stop-lab.ps1` only kills PIDs under `private\`.
- Report batches with the results-table skill. Rerun a failure alone before believing it.
- After essential progress, send the Website stuff session version,
  status, connect, players, repo.
- Run `graphify update .` after code changes; `graphify query` before grepping.

## Layout
- `src/Scripts/main.lua`: the mod (config, transport files, host choice detection, client guard/apply, anomaly
  forcing, restarts, puppets, lab tour).
- `src/Scripts/e8bot.lua`: lab bot (corridor-local waypoints).
- `native/e8net.cpp`: TCP + Steam transport DLL.
- `scripts/`: build, setup-lab, launch-lab, stop-lab, run-tour, run-probe, mutants.
- `tests/`: transport_test.py (no game), verify-lab.py (judges lab logs).
- `tools/`: recon mods (lab only), dump_classes.py.

## Hook table
Loader: UE4SS v4.0.0 (v3.0.1's SpawnActor gave actors that never animate). No `RegisterHook` (crashed UE4SS v3.0.1 during corridor transitions; not retried on v4). Polled state and plane crossings only. All mod Lua runs from one `LoopInGameThreadAfterFrames(1)` loop on the game
thread; never add `LoopAsync` Lua work (its callback runs on another thread in the same Lua state and corrupted values). See
handoff "Hooks". Keep it that way unless a hook is proven stable in the lab one at a time.

## Mutants (E8T_MUTANT, lab only)
| Mutant | Switches off | Check that must fail |
|---|---|---|
| noanomalysync | client roll forcing (DEBUG fields) | loopstate |
| noguard | client walls before the host-owned planes | choices (client-own-choice evidence) |
| nofloorsync | exit-count fallback correction | loopstate (only if a roll mismatch happens) |
| norestartsync | group restart on R | loopstate (needs a death in the run) |
| noanim | puppet walk/idle switching (always idle) | animation |
| nosmooth | per-frame snapshot interpolation (back to 10 Hz chasing) | smooth |
| vote1 | vote agreement (host commits on its own vote) | voting |
