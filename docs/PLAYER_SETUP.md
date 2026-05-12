# HP2PC_AP — Player Setup

End-to-end install + first-run guide for the Harry Potter and the Chamber of Secrets PC Archipelago randomizer.

If you're a developer wanting to *modify* the mod or apworld, skip this and read [`DEV_SETUP.md`](DEV_SETUP.md) instead.

---

## What you're getting

- An Archipelago multiworld randomizer for HP2 (PC, KnowWonder 2002 release).
- 105 checks (101 wizard cards + 4 spell-tutorial classrooms), 108 items in the pool.
- Goal: defeat the Basilisk.
- Plays solo or as a slot in a larger AP multiworld.

## Prerequisites

| Thing | Where to get it |
| --- | --- |
| **Harry Potter and the Chamber of Secrets (PC)** | Retail disc / your existing legitimate copy. KnowWonder 2002 build. The randomizer **does not include the game**. |
| **HP2Engine 3.4 by Metallicafan212** ("M212") | Free 64-bit engine patch. Restores UT99 networking that the randomizer relies on. Get it from the HP2 modding Discord. |
| **Python 3.12 (64-bit)** | <https://www.python.org/downloads/> — install with "Add to PATH" ticked. |
| **Archipelago framework** | <https://github.com/ArchipelagoMW/Archipelago/releases> — pick the latest stable Windows installer. |
| **HP2PC_AP release zip** | The `harry_potter_2_pc_v*.zip` you downloaded with this doc. |

OS: Windows 10 or Windows 11 (64-bit). The M212 engine doesn't support older Windows.

## Install

### 1. Install HP2 retail

Install the game from your disc / installer. Default location is fine (e.g. `C:\Program Files (x86)\Harry Potter 2\`).

### 2. Apply the M212 engine patch

Run M212's installer. Point it at your HP2 install. It will create a `Modded\` subfolder next to the original install (`Modded\system\Game.exe`, `Modded\system\UCC.exe`, etc.).

> Keep the original (vanilla) install untouched in case you ever need to verify a vanilla behaviour.

### 3. Drop the mod files

Unzip the release. Inside you'll find:

```
HP2PC_AP_v1.0.0/
├── HPArchipelago.u           ← compiled mod
├── harry_potter_2_pc.apworld ← AP world
├── client/                   ← Python sidecar
│   └── hp2_ap_client.py
└── PLAYER_SETUP.md           ← this file
```

Copy `HPArchipelago.u` into your M212 install:

```
<HP2 install>\Modded\system\HPArchipelago.u
```

### 4. Register the mod with the engine

Two INI files need editing. Both are in `<HP2 install>\Modded\system\`. **Use a text editor that preserves ANSI / Windows-1252 encoding** (Notepad is fine; VS Code defaults to UTF-8 — switch the encoding before saving).

**`Default.ini`** — add `IpDrv` and `HPArchipelago` to the `EditPackages=` list. Find the existing block and insert these two lines **immediately after** `EditPackages=M212Share`:

```ini
EditPackages=IpDrv
EditPackages=HPArchipelago
```

> Don't append at end-of-file — the file extends past the EditPackages list with graphics-adapter sections, and an EditPackages entry there is silently ignored.

**`Game.ini`** — under `[Engine.Engine]` add:

```ini
DefaultGame=HPArchipelago.APGameInfo
```

(If `[Engine.Engine]` doesn't exist, create the section.)

### 5. First launch creates `HP.ini`

Launch the game once via `<HP2 install>\Modded\system\Game.exe`. It'll generate a `HP.ini` in `Documents\Harry - Coding Evolved\`. Quit out of the game.

Now apply the **same** `EditPackages=IpDrv` + `EditPackages=HPArchipelago` lines from step 4 to `Documents\Harry - Coding Evolved\HP.ini` — once HP.ini exists, the engine reads from it instead of `Default.ini`.

> If you ever wipe the user-data folder, repeat step 5.

### 6. Install Archipelago and the apworld

Install Archipelago using its Windows installer. Default location works (`C:\ProgramData\Archipelago\` on most systems).

Drop `harry_potter_2_pc.apworld` into Archipelago's custom worlds folder:

```
<Archipelago install>\custom_worlds\harry_potter_2_pc.apworld
```

That's it — Archipelago discovers it automatically next time you launch.

### 7. Sidecar Python deps

The sidecar reuses the Archipelago framework's `CommonClient`, so it has no extra Python dependencies on top of what AP already bundles. Just make sure Python 3.12 is on `PATH` (test with `py -3.12 --version` in PowerShell).

## Generate a seed (solo play)

If you're playing solo (just you, no other AP slots):

1. Write your slot YAML — copy the template from `tests/HP2_Test.yaml` in the release zip and edit `name:` to whatever you want your in-game player name to be. Save it next to your other Archipelago YAMLs (typically `<Archipelago install>\Players\`).
2. Open ArchipelagoLauncher (in your AP install) → **Generate**. Pick your YAML when prompted. The generator drops a seed zip in `<Archipelago install>\output\`.

Skip this section if you're joining someone else's multiworld — they'll send you a server address, port, and your slot name.

## Play

You'll need three things running:

1. **The Archipelago server** — hosts the seed. Either:
   - Solo: ArchipelagoLauncher → **Host**, pick your output zip. Note the port it prints.
   - Multiworld: someone else hosts; you get a server address.
2. **The sidecar** — bridges the AP server to the game.
3. **HP2** — reads from the sidecar, sends checks back.

### Start the sidecar

From a terminal:

```powershell
cd "<Archipelago install>"
py -3.12 "<HP2PC_AP unzip path>\client\hp2_ap_client.py" --name <YourSlotName> --connect <server>:<port>
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

Within a few seconds you should see in the sidecar terminal:

```
Game connected from ('127.0.0.1', <port>)
[game→sidecar] HELLO
```

…and the game window should pop a toast top-right when your starting items arrive ("Received Alohomora from <YourSlotName>" etc).

You're playing.

## Verify it's working

Quick checklist after first launch:

- **Toasts appear top-right** when items arrive. If not, the mod isn't loaded — check step 4 INI patches.
- **Bookcases block the spell classrooms** you haven't been granted yet. If you can walk straight into Lockhart's DADA classroom and the spell-tutorial cutscene fires immediately, the mod isn't running.
- **Picking up a wizard card** should fire a `CHECK <id>` line in the sidecar terminal and (if you have any items waiting) hand you something back.
- **Goal:** the seed completes when you defeat the Basilisk and the post-Basilisk Great Hall walk-in fires the credits.

## Troubleshooting

**Mod doesn't load** (no toasts, classrooms aren't blocked):

- Check `<HP2 install>\Modded\system\HPArchipelago.u` exists.
- Check both `Default.ini` AND `HP.ini` (in `Documents\Harry - Coding Evolved\`) have `EditPackages=IpDrv` and `EditPackages=HPArchipelago` inserted right after the `EditPackages=M212Share` line.
- Check `Game.ini` has `[Engine.Engine] DefaultGame=HPArchipelago.APGameInfo`.
- Read `Documents\Harry - Coding Evolved\Game.log` — search for `[Archipelago]` lines. Encoding is UTF-16LE (`Get-Content -Encoding Unicode` in PowerShell).

**Sidecar can't import `worlds.harry_potter_2_pc`**:

- The `.apworld` file isn't in `<Archipelago install>\custom_worlds\`. Drop it there, restart the sidecar.
- The sidecar must be **launched from inside the Archipelago install directory** so it can find `CommonClient.py`. The example command above does this with `cd "<Archipelago install>"` first.

**Sidecar disconnects mid-session**:

- The mod auto-reconnects with exponential backoff (1s → 16s). Just restart the sidecar; the game will reconnect on the next try.
- Items the AP server delivered while the sidecar was down get replayed on reconnect (durable items: cards, spells; bean filler is non-durable in v1 and can be lost across a sidecar crash).

**Game crashes at level transition**:

- Probably an unrelated M212 issue — check the M212 Discord. The randomizer mod doesn't touch level loading.

**A specific card doesn't fire its check when picked up**:

- Open `Game.log` and search for the card's id. If the line `APCardMarker.Touch: firing CHECK <n>` is there but no AP item arrives, the AP server side is the issue.
- If `APCardMarker.Touch` doesn't fire, the marker wasn't placed (check `ReplaceCardChests:` log lines for that level).

## Logs

For bug reports, attach these:

| What | Where |
| --- | --- |
| Game-side log | `Documents\Harry - Coding Evolved\Game.log` (UTF-16LE) |
| Sidecar terminal | the PowerShell window you ran the sidecar in |
| AP server log | `<Archipelago install>\logs\` |

## Where to ask for help

- HP2 modding Discord (engine + game-specific issues)
- Archipelago Discord, `#future-game-design` or the dedicated HP2 channel if it exists by then
- GitHub issues at this project's repo
