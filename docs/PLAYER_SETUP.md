# HP2PC_AP - Player Setup

End-to-end install and first-run guide for the Harry Potter and the Chamber of Secrets PC Archipelago randomizer.

If you're a developer wanting to *modify* the mod or apworld, skip this and read [`DEV_SETUP.md`](DEV_SETUP.md) instead.

---

## What you're getting

- An Archipelago multiworld randomizer for HP2 (PC, KnowWonder 2002 release).
- 105 checks (101 wizard cards plus 4 spell-tutorial classrooms), 108 items in the pool.
- Goal: defeat the Basilisk.
- Plays solo or as a slot in a larger AP multiworld.

## Prerequisites

| Thing | Where to get it |
| --- | --- |
| **Harry Potter and the Chamber of Secrets (PC)** | Retail disc or your existing legitimate copy. KnowWonder 2002 build. The randomizer **does not include the game**. |
| **HP2Engine 3.4 by Metallicafan212** ("M212") | Free 64-bit engine patch. Restores UT99 networking that the randomizer relies on. Get it from the HP2 modding Discord. |
| **Archipelago framework** | <https://github.com/ArchipelagoMW/Archipelago/releases>, pick the latest stable Windows installer. Used for seed generation and hosting. |
| **HP2PC_AP release zip** | The `harry_potter_2_pc_v*.zip` you downloaded with this doc. |

OS: Windows 10 or Windows 11 (64-bit). The M212 engine doesn't support older Windows.

## Install

### 1. Install HP2 retail

Install the game from your disc or installer. Default location is fine (e.g. `C:\Program Files (x86)\Harry Potter 2\`).

### 2. Apply the M212 engine patch

Run M212's installer. Point it at your HP2 install. It will create a `Modded\` subfolder next to the original install (`Modded\system\Game.exe`, `Modded\system\UCC.exe`, etc.).

> Keep the original (vanilla) install untouched in case you ever need to verify a vanilla behaviour.

### 3. Drop the mod files

Unzip the release. Inside you'll find:

```
HP2PC_AP_v1.0.0/
├── HPArchipelago.u           (compiled mod)
├── harry_potter_2_pc.apworld (AP world)
├── hp2_ap_client.exe         (self-contained client, ~85 MB)
└── PLAYER_SETUP.md           (this file)
```

Copy `HPArchipelago.u` into your M212 install:

```
<HP2 install>\Modded\system\HPArchipelago.u
```

### 4. Patch `Default.ini`

Open `<HP2 install>\Modded\system\Default.ini` in a text editor that preserves ANSI / Windows-1252 encoding (Notepad is fine; VS Code defaults to UTF-8, switch the encoding before saving).

Add `IpDrv` and `HPArchipelago` to the `EditPackages=` list. Find the existing block and insert these two lines **immediately after** `EditPackages=M212Share`:

```ini
EditPackages=IpDrv
EditPackages=HPArchipelago
```

> Don't append at end-of-file. The file extends past the EditPackages list with graphics-adapter sections, and an EditPackages entry there is silently ignored.

### 5. First launch creates the user-data files

Launch the game once via `<HP2 install>\Modded\system\Game.exe`. It generates `HP.ini` and `Game.ini` in `C:\Users\<you>\Documents\Harry - Coding Evolved\`. Quit out of the game.

> If you ever wipe the user-data folder, repeat this step before redoing 6 and 7.

### 6. Patch `HP.ini`

Open `C:\Users\<you>\Documents\Harry - Coding Evolved\HP.ini` (same ANSI encoding rule as `Default.ini`).

Apply the **same** `EditPackages=IpDrv` and `EditPackages=HPArchipelago` lines from step 4 immediately after `EditPackages=M212Share`. Once `HP.ini` exists, the engine reads from it instead of `Default.ini`, so both files need the entries.

### 7. Patch `Game.ini`

Open `C:\Users\<you>\Documents\Harry - Coding Evolved\Game.ini`. Find the `[Engine.Engine]` section and add:

```ini
DefaultGame=HPArchipelago.APGameInfo
```

This tells HP2 to load our `APGameInfo` subclass at level start, which is what wires the rest of the mod into the game.

### 8. Install Archipelago and the apworld

Install Archipelago using its Windows installer. Default location works (`C:\ProgramData\Archipelago\` on most systems).

Drop `harry_potter_2_pc.apworld` into Archipelago's custom worlds folder:

```
<Archipelago install>\custom_worlds\harry_potter_2_pc.apworld
```

That's it. Archipelago discovers it automatically next time you launch.

### 9. Keep `hp2_ap_client.exe` somewhere handy

It's a single self-contained file. Put it anywhere you'll remember, e.g. next to the unzipped release files. You'll launch it later when you start playing.

## Generate a seed (solo play)

If you're playing solo (just you, no other AP slots):

1. **Generate the YAML template.** Open ArchipelagoLauncher, click **Generate Template Options**. Once `harry_potter_2_pc.apworld` is in `custom_worlds\`, the launcher writes a fresh `Harry Potter 2 PC.yaml` template into `<Archipelago install>\Players\Templates\`.
2. **Configure your slot.** Copy that template into `<Archipelago install>\Players\` and edit `name:` to whatever you want your in-game player name to be. Anything else in the template can stay at defaults for v1.
3. **Generate.** ArchipelagoLauncher → **Generate**, pick your YAML when prompted. The generator drops a seed zip in `<Archipelago install>\output\`.

Skip this section if you're joining someone else's multiworld. They'll send you a server address, port, and your slot name.

## Play

You'll need three things running:

1. **The Archipelago server** hosts the seed. Either:
   - Solo: ArchipelagoLauncher → **Host**, pick your output zip. Note the port it prints.
   - Multiworld: someone else hosts; you get a server address.
2. **The HP2PC_AP client** bridges the AP server to the game.
3. **HP2** reads from the client, sends checks back.

### Start the client

Double-click `hp2_ap_client.exe`, OR run from a terminal:

```powershell
"<HP2PC_AP unzip path>\hp2_ap_client.exe" --name <YourSlotName> --connect <server>:<port>
```

Replace `<YourSlotName>` with your AP slot's name and `<server>:<port>` with the AP server. For solo on the same machine, that's typically `localhost:38281`.

You should see:

```
Connected to AP server as slot <N> (<YourSlotName>)
Game-side TCP listener up on ('127.0.0.1', 38281)
```

Leave the terminal open.

### Launch the game

Run `<HP2 install>\Modded\system\Game.exe` (or use the M212 Start Menu shortcut).

Within a few seconds you should see in the client terminal:

```
Game connected from ('127.0.0.1', <port>)
[game→sidecar] HELLO
```

The game window should pop a toast top-right when your starting items arrive ("Received Alohomora from <YourSlotName>" etc).

You're playing.

## Verify it's working

Quick checklist after first launch:

- **Toasts appear top-right** when items arrive. If not, the mod isn't loaded, check the INI patches in steps 4, 6, and 7.
- **Bookcases block the spell classrooms** you haven't been granted yet. If you can walk straight into Lockhart's DADA classroom and the spell-tutorial cutscene fires immediately, the mod isn't running.
- **Picking up a wizard card** should fire a `CHECK <id>` line in the client terminal and (if you have any items waiting) hand you something back.
- **Goal:** the seed completes when you defeat the Basilisk and the post-Basilisk Great Hall walk-in fires the credits.

## Troubleshooting

**Mod doesn't load** (no toasts, classrooms aren't blocked):

- Check `<HP2 install>\Modded\system\HPArchipelago.u` exists.
- Check both `Default.ini` (in `<HP2 install>\Modded\system\`) AND `HP.ini` (in `C:\Users\<you>\Documents\Harry - Coding Evolved\`) have `EditPackages=IpDrv` and `EditPackages=HPArchipelago` inserted right after the `EditPackages=M212Share` line.
- Check `Game.ini` (also in `C:\Users\<you>\Documents\Harry - Coding Evolved\`) has `DefaultGame=HPArchipelago.APGameInfo` under `[Engine.Engine]`.
- Read `C:\Users\<you>\Documents\Harry - Coding Evolved\Game.log`, search for `[Archipelago]` lines. Encoding is UTF-16LE (`Get-Content -Encoding Unicode` in PowerShell).

**Client exe won't start / antivirus quarantines it**:

- Some antivirus engines flag self-contained tools like this heuristically. If your AV blocks it, whitelist `hp2_ap_client.exe` and re-extract.
- The exe runs on its own. The Archipelago install is only needed to generate or host seeds, not to run the client.

**Seed generation can't find the apworld**:

- The `.apworld` file isn't in `<Archipelago install>\custom_worlds\`. Drop it there, restart ArchipelagoLauncher.

**Client disconnects mid-session**:

- The mod auto-reconnects with exponential backoff (1s up to a 16s cap). Just restart the client; the game will reconnect on the next try.
- Items the AP server delivered while the client was down get replayed on reconnect (durable items: cards, spells; bean filler is non-durable in v1 and can be lost across a client crash).

**Game crashes at level transition**:

- Probably an unrelated M212 issue, check the M212 Discord. The randomizer mod doesn't touch level loading.

**A specific card doesn't fire its check when picked up**:

- Open `Game.log` and search for the card's id. If the line `APCardMarker.Touch: firing CHECK <n>` is there but no AP item arrives, the AP server side is the issue.
- If `APCardMarker.Touch` doesn't fire, the marker wasn't placed (check `ReplaceCardChests:` log lines for that level).

**Still stuck?** Feel free to contact Kryen in the Archipelago Discord.

## Logs

For bug reports, attach these:

| What | Where |
| --- | --- |
| Game-side log | `C:\Users\<you>\Documents\Harry - Coding Evolved\Game.log` (UTF-16LE) |
| Client terminal | the PowerShell window you ran the client in |
| AP server log | `<Archipelago install>\logs\` |

## Where to ask for help

- HP2 modding Discord (engine and game-specific issues).
- Archipelago Discord, `#future-game-design`. Feel free to contact Kryen there.
- GitHub issues at this project's repo.
