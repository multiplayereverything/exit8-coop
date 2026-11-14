# Exit 8 Together

Co-op for **The Exit 8**: walk the same looping corridor with friends, see each other, spot the same anomaly, and
reach Exit 8 together. Early test build (0.2.0), not released yet.

## What is shared
- One corridor loop for everyone: the same exit count and the same anomaly in every corridor.
- The group decides together: walk up to the forward exit or the turn-back line to vote. When everyone stands at
  the same line, you all go that way; a sign at the line shows the count ("FORWARD 1/2"). Nobody can take a line
  alone. (The host can set `choice = host` to make the host's choice move everyone instead.)
- If anyone gets caught, everyone starts over together.
- You see the other players as mannequins in their own colour (blue, orange, green, purple) who walk smoothly when
  they move and stand idle when they stop (2-4 players).

## How to play (manual install for now)
1. Install [UE4SS v4.0.0](https://github.com/UE4SS-RE/RE-UE4SS/releases/tag/v4.0.0) into
   `steamapps\common\Exit8\Exit8\Binaries\Win64` (you get `dwmapi.dll` and a `ue4ss` folder).
2. Copy the `Exit8Together` folder into `Win64\ue4ss\Mods` and add `Exit8Together : 1` to `ue4ss\Mods\mods.txt`.
3. Edit `ue4ss\Mods\Exit8Together\config.txt`: the host sets `mode = host`; friends set `mode = join` and the host's
   `address`. Play over LAN, a VPN (Tailscale, ZeroTier), or with TCP port 27080 forwarded on the host.
   **Or over Steam (no port forwarding):** everyone sets `transport = steam`; the host `mode = host`, friends
   `mode = join` with `lobby` left empty: they join the Steam friend who is hosting. Not yet tested between two
   Steam accounts.
4. Everyone needs the same mod version; a different version is refused with both versions named.

## Known limits
- No in-game menu yet (config file only).
- Steam lobby play not tested; tested only with two copies on one PC.
- Joining mid-run isn't handled; start together.
- Each PC still writes its own save.

## Credits
Built with UE4SS (RE-UE4SS), Co-op Anything, REA, ReversePort, retoc and kismet-analyzer (trumank), graphify.
The Exit 8 is by KOTAKE CREATE; this mod uses only the game's own assets at runtime and ships none of them.
