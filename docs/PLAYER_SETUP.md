# HP2PC_AP - Player Setup

End-to-end install and first-run guide for the Harry Potter and the Chamber of Secrets PC Archipelago randomizer.

If you're a developer wanting to _modify_ the mod or apworld, skip this and read [`DEV_SETUP.md`](DEV_SETUP.md) instead.

---

## What you're getting

- An Archipelago multiworld randomizer for HP2 (PC, KnowWonder 2002 release).
- 105 checks (101 wizard cards plus 4 spell-tutorial classrooms), 108 items in the pool.
- Goal: defeat the Basilisk.
- Plays solo or as a slot in a larger AP multiworld.

## Prerequisites

| Thing                                            | Where to get it                                                                                                                                                 |
| ------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Harry Potter and the Chamber of Secrets (PC)** | Retail disc or your existing legitimate copy. KnowWonder 2002 build. The randomizer **does not include the game**.                                              |
| **HP2Engine 3.4 by Metallicafan212** ("M212")    | Free 64-bit engine patch. Restores UT99 networking that the randomizer relies on. Get it from the HP2 modding Discord.                                          |
| **Archipelago framework**                        | <https://github.com/ArchipelagoMW/Archipelago/releases>, pick the latest stable Windows installer. Used for seed generation and hosting.                        |
| **HP2PC_AP release files**                       | Downloaded individually from the GitHub release: `HPArchipelago.u`, `Default.ini`, `harry_potter_2_pc.apworld`, and this `PLAYER_SETUP.md`. The Python client is bundled inside the apworld — no separate exe. |

OS: Windows 10 or Windows 11 (64-bit). The M212 engine doesn't support older Windows.

## Install

### 1. Install HP2 retail

Install the game from your disc or installer. Default location is fine (e.g. `C:\Program Files (x86)\Harry Potter 2\`).
Follow only steps 1, 2, 3 and 5, no need for windowed steps etc.

### 2. Apply the M212 engine patch

Run M212's installer. Point it at your HP2 install.

### 3. Drop the mod files

You should have downloaded these four files from the GitHub release:

- `HPArchipelago.u` (the compiled mod)
- `Default.ini` (pre-patched engine config — replaces the one shipped with M212)
- `harry_potter_2_pc.apworld` (the AP world + bundled client)
- `PLAYER_SETUP.md` (this file)

Copy `HPArchipelago.u` and `Default.ini` into your M212 install, overwriting the existing `Default.ini`:

```
<HP2 install>\Modded\system\HPArchipelago.u
<HP2 install>\Modded\system\Default.ini
```

If Windows blocks saving in Program Files, copy the files via Windows Explorer and approve the admin prompt, or move your HP2 install out of Program Files entirely (e.g. to `C:\Games\HP2\`).

**Only if you've launched HP2 before** (i.e. `C:\Users\<you>\Documents\Harry - Coding Evolved\` already exists with `HP.ini` and/or `Game.ini` in it), do this cleanup:

- Delete your `HP.ini`.
- For `Game.ini` (if it exists), either delete it OR open it and under the `[Engine.Engine]` section add:

  ```
  DefaultGame=HPArchipelago.APGameInfo
  ```

  (replacing any existing `DefaultGame=` line). The edit path preserves your per-user settings like resolution and audio volume; the delete path is simpler if you don't care.

Your `Save\` folder is fine to keep. If `Harry - Coding Evolved\` doesn't exist yet (fresh M212 install, never launched), skip this — `Default.ini` is all you need; the engine will generate any per-user files on first launch.

> Why this matters: `HP.ini` and `Game.ini` are user-data overrides. If they exist from a prior launch, they take precedence over `Default.ini` and will silently override the mod's settings back to vanilla.

> The shipped `Default.ini` is already patched with `EditPackages=IpDrv`, `EditPackages=HPArchipelago`, and `DefaultGame=HPArchipelago.APGameInfo`. No hand-editing required.

### 4. Install Archipelago and the apworld

Install Archipelago using its Windows installer. Default location works (`C:\ProgramData\Archipelago\` on most systems).

Drop `harry_potter_2_pc.apworld` into Archipelago's custom worlds folder:

```
<Archipelago install>\custom_worlds\harry_potter_2_pc.apworld
```

That's it. Archipelago discovers it automatically next time you launch — `HP2 PC Client` will appear as a button in the Archipelago Launcher.

## Generate a seed (solo play)

If you're playing solo (just you, no other AP slots):

1. **Generate the YAML template.** Open ArchipelagoLauncher, click **Generate Template Options**. Once `harry_potter_2_pc.apworld` is in `custom_worlds\`, the launcher writes a fresh `Harry Potter 2 PC.yaml` template into `<Archipelago install>\Players\Templates\`. (If you don't see the yaml, make sure you have the apworld installed and close and re-open the launcher.)
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

Open `ArchipelagoLauncher.exe` and click **HP2 PC Client**. A Kivy window opens with the usual Archipelago client UI (server tab, items tab, command box at the bottom).

In the command box, type:

```
/connect <server>:<port>
```

It will then prompt for your slot name; enter it and press Enter. For solo on the same machine, the server is typically `localhost:38281`.

You should see in the log tab:

```
Connected to AP server as slot <N> (<YourSlotName>)
Game-side TCP listener up on ('127.0.0.1', 38281)
```

Leave the client window open.

### Launch the game

Run `<HP2 install>\system\Game.exe` (or use the M212 Start Menu shortcut), and start a new game.

Within a few seconds you should see in the client log:

```
Game connected from ('127.0.0.1', <port>)
[game→client] HELLO
```

The game window should pop a toast top-right when your starting items arrive ("Received Alohomora from <YourSlotName>" etc).

You're playing.

## Verify it's working

Quick checklist after first launch:

- **Toasts appear top-right** when items arrive. If not, the mod isn't loaded — see Troubleshooting below.
- **Bookcases block the spell classrooms** you haven't been granted yet. If you can walk straight into Lockhart's DADA classroom and the spell-tutorial cutscene fires immediately, the mod isn't running.
- **Picking up a wizard card** should fire a `CHECK <id>` line in the client log and (if you have any items waiting) hand you something back.
- **Goal:** the seed completes when you defeat the Basilisk and the post-Basilisk Great Hall walk-in fires the credits.

## Troubleshooting

**Mod doesn't load** (no toasts, classrooms aren't blocked):

- Check `<HP2 install>\Modded\system\HPArchipelago.u` exists.
- Check `<HP2 install>\Modded\system\Default.ini` is the shipped one — open it and confirm `EditPackages=HPArchipelago` is present (search for it).
- If `C:\Users\<you>\Documents\Harry - Coding Evolved\HP.ini` exists, it overrides `Default.ini`, delete it.
- If `C:\Users\<you>\Documents\Harry - Coding Evolved\Game.ini` exists, it overrides both. Either delete it, or open it and make sure `[Engine.Engine]` has `DefaultGame=HPArchipelago.APGameInfo` (not `DefaultGame=Engine.GameInfo`).
- Read `C:\Users\<you>\Documents\Harry - Coding Evolved\Game.log`, search for `[Archipelago]` lines. Encoding is UTF-16LE (`Get-Content -Encoding Unicode` in PowerShell).

**"HP2 PC Client" button missing from Archipelago Launcher**:

- The apworld isn't installed where the launcher can see it. Confirm `harry_potter_2_pc.apworld` exists in `<Archipelago install>\custom_worlds\`.
- Close and reopen ArchipelagoLauncher fully — launcher components are discovered on startup, not refreshed live.

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

| What            | Where                                                                 |
| --------------- | --------------------------------------------------------------------- |
| Game-side log   | `C:\Users\<you>\Documents\Harry - Coding Evolved\Game.log` (UTF-16LE) |
| Client log      | Scroll the **Archipelago** tab of the HP2 PC Client window, or check `<Archipelago install>\logs\HP2PC_AP.txt` |
| AP server log   | `<Archipelago install>\logs\`                                         |

## Where to ask for help

- HP2 modding Discord (engine and game-specific issues).
- Archipelago Discord, `#future-game-design`. Feel free to contact Kryen there.
- GitHub issues at this project's repo.
