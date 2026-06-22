# HP2PC_AP - Player Setup

End-to-end install and first-run guide for the Harry Potter and the Chamber of Secrets PC Archipelago randomizer.

If you're a developer wanting to _modify_ the mod or apworld, skip this and read [`DEV_SETUP.md`](DEV_SETUP.md) instead.

---

## What you're getting

- An Archipelago multiworld randomizer for HP2 (PC, KnowWonder 2002 release).
- Up to 280 checks across 8 categories: 4 spell-tutorial classrooms, 101 wizard cards, 109 secret areas, 44 challenge stars, 10 ranked duels, 6 Quidditch matches, 4 spell-challenge par times, and 2 Fred & George vendor purchases. Each category is gated by a yaml toggle so you can dial difficulty (see "Configure your slot" below).
- Goal: in vanilla, defeat the Basilisk; in open castle, satisfy your configured goal clauses to unlock the Great Hall (see "Game mode" below).
- Plays solo or as a slot in a larger AP multiworld.

## Prerequisites

| Thing                                            | Where to get it                                                                                                                                                                                               |
| ------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Harry Potter and the Chamber of Secrets (PC)** | Retail disc or your existing legitimate copy. KnowWonder 2002 build. The randomizer **does not include the game**.                                                                                            |
| **HP2Engine 3.4 by Metallicafan212** ("M212")    | Free 64-bit engine patch. Restores UT99 networking that the randomizer relies on. Get it from the HP2 modding Discord.                                                                                        |
| **Archipelago framework**                        | <https://github.com/ArchipelagoMW/Archipelago/releases>, pick the latest stable Windows installer. Used for seed generation and hosting.                                                                      |
| **HP2PC_AP release files**                       | Downloaded individually from the GitHub release: `HPArchipelago.u`, `Default.ini`, `harry_potter_2_pc.apworld`, and this `PLAYER_SETUP.md`. The Python client is bundled inside the apworld; no separate exe. |

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
- `Default.ini` (pre-patched engine config, replaces the one shipped with M212)
- `harry_potter_2_pc.apworld` (the AP world + bundled client)
- `PLAYER_SETUP.md` (this file)

Copy `HPArchipelago.u` and `Default.ini` into your M212 install, overwriting the existing `Default.ini`:

```
<HP2 install>\system\HPArchipelago.u
<HP2 install>\system\Default.ini
```

If Windows blocks saving in Program Files, copy the files via Windows Explorer and approve the admin prompt, or move your HP2 install out of Program Files entirely (e.g. to `C:\Games\HP2\`).

**Only if you've launched HP2 before** (i.e. `C:\Users\<you>\Documents\Harry - Coding Evolved\` already exists with `HP.ini` and/or `Game.ini` in it), do this cleanup:

- Delete your `HP.ini`.
- For `Game.ini` (if it exists), either delete it OR open it and under the `[Engine.Engine]` section add:

  ```
  DefaultGame=HPArchipelago.APGameInfo
  ```

  (replacing any existing `DefaultGame=` line). The edit path preserves your per-user settings like resolution and audio volume; the delete path is simpler if you don't care.

Your `Save\` folder is fine to keep. If `Harry - Coding Evolved\` doesn't exist yet (fresh M212 install, never launched), skip this; `Default.ini` is all you need; the engine will generate any per-user files on first launch.

> Why this matters: `HP.ini` and `Game.ini` are user-data overrides. If they exist from a prior launch, they take precedence over `Default.ini` and will silently override the mod's settings back to vanilla.

> The shipped `Default.ini` is already patched with `EditPackages=IpDrv`, `EditPackages=HPArchipelago`, and `DefaultGame=HPArchipelago.APGameInfo`. No hand-editing required.

### Optional: install the HP2 Bingo distribution too

The randomizer also supports the **HP2 Bingo** community pack (open castle from spawn). You can keep your vanilla install AND a separate HP2 Bingo install side by side; the same `HPArchipelago.u` works for both, and the mod auto-detects which one you launched.

If you only want vanilla story play, skip to step 4. If you want open castle:

1. **Install HP2 retail to a separate folder** (e.g. `C:\Program Files (x86)\EA Games\Bingo`) so it doesn't collide with the vanilla install.
2. **Get the Bingo Client** from the HP2 speedrunning community (https://www.speedrun.com/hpcc/resources) (the **[2PC] Bingo Client V4.5** download). Copy its `Harry Potter and the Chamber of Secrets\` contents over the install from the previous step.
3. **Run the M212 installer again**, pointing at your HP2 Bingo folder. M212 layers cleanly over the HP2 Bingo map edits.
4. **Copy `HPArchipelago.u` and `Default.ini`** into `<HP2 Bingo install>\system\`, same as step 3 above. Per-user `Game.ini` / `HP.ini` in `Documents\Harry - Coding Evolved\` are shared between both installs (one Windows user = one set of user files), so no separate INI cleanup is needed.

That's the install side. The yaml side is one line; see "Configure your slot" below for the `game_mode: open_castle` option.

### 4. Install Archipelago and the apworld

Install Archipelago using its Windows installer. Default location works (`C:\ProgramData\Archipelago\` on most systems).

Drop `harry_potter_2_pc.apworld` into Archipelago's custom worlds folder:

```
<Archipelago install>\custom_worlds\harry_potter_2_pc.apworld
```

That's it. Archipelago discovers it automatically next time you launch, and `HP2 PC Client` will appear as a button in the Archipelago Launcher.

## Generate a seed (solo play)

If you're playing solo (just you, no other AP slots):

1. **Generate the YAML template.** Open ArchipelagoLauncher, click **Generate Template Options**. Once `harry_potter_2_pc.apworld` is in `custom_worlds\`, the launcher writes a fresh `Harry Potter 2 PC.yaml` template into `<Archipelago install>\Players\Templates\`. (If you don't see the yaml, make sure you have the apworld installed and close and re-open the launcher.)
2. **Configure your slot.** Copy that template into `<Archipelago install>\Players\` and edit `name:` to your desired in-game player name. The 7 category toggles control what becomes an AP check:

   | Toggle                         | Default | What it enables                                                                                            |
   | ------------------------------ | ------- | ---------------------------------------------------------------------------------------------------------- |
   | `enable_wizard_cards`          | on      | Card shuffle. The 101 wizard cards are always checks; **on** shuffles the card items into the multiworld pool (tier-prefixed: `Bronze/Silver/Gold Card - X`), **off** locks each card to its own spot (keeps the Gold Card Room's silver gate honest). |
   | `enable_secrets`               | on      | 109 secret-area pickups across all levels (open castle adds 9 in the Gryffindor challenge, 118 total).                                                                 |
   | `enable_challenge_stars`       | on      | 44 challenge stars across the 4 spell-challenge levels (open castle adds 10 in the Gryffindor challenge, 54 total). |
   | `enable_duelling`              | off     | 10 Duelling Club ranked-duel wins.                                                                         |
   | `enable_quidditch_matches`     | off     | 6 Quidditch matches (3 regular + 3 final-tournament).                                                      |
   | `enable_spell_challenge_times` | off     | Beating the replay par time ("Mastered") on each of the 4 spell challenges becomes a check.                |
   | `enable_quidditch_upgrades`    | off     | Buying Nimbus 2001 and Quidditch Armour from Fred & George becomes 2 checks AND the gear enters the pool.  |

   The 4 spell-tutorial classrooms are always on, since randomized spells are the core experience. `allow_missable_progression` (default off) controls whether progression items may be placed at missable locations in un-replayable levels (missable secrets, plus `containersanity` containers in those levels); safe default keeps those filler-only.

   **Game mode**: one extra setting selects the install layout your seed targets:

   ```yaml
   Harry Potter 2 PC:
     game_mode: vanilla # default, retail + M212; Lumos / Flipendo / Alohomora precollected, other 4 spells in pool
     # game_mode: open_castle   # HP2 Bingo install, NO spells precollected, all 7 land as AP items
   ```

   The mod side handles the runtime difference itself (auto-detects the HP2 Bingo install via the `MGBingoLearnAllSpells` actor and reverts the HP2 Bingo client's PostBeginPlay spell grants). You can confirm it kicked in by checking `Game.log` for `DetectOpenCastleMode - found MGBingoLearnAllSpells - entering open castle mode (sticky)` shortly after launching. Match this setting to the install you launch; if they disagree the game pops a "WRONG INSTALL" warning toast every level (see Troubleshooting), because a mismatched seed can't be completed.

   **Open castle goal**: in `open_castle` mode the slot completes by opening the Great Hall, not by the Basilisk fight. Five options set the unlock requirement; they're AND'd together, and any clause left at `0`/off drops out. If all five resolve to `0`/off it falls back to "all 7 spells" so there's always a gate. All five are ignored in vanilla.

   | Option                       | Range  | Default | Great Hall opens once you have…                                          |
   | ---------------------------- | ------ | ------- | ------------------------------------------------------------------------ |
   | `open_castle_goal_cards`     | 0-101  | 50      | that many wizard cards (named anchors: `none`/`few`/`half`/`most`/`all`) |
   | `open_castle_goal_spells`    | 0-7    | 7       | that many spells                                                         |
   | `open_castle_goal_levels`    | 0-13   | 13      | that many of the 13 level objectives finished (incl. the Gold Card Room, which needs 20 silver cards) |
   | `open_castle_goal_duels`     | off/on | off     | won all 10 Duelling Club duels                                           |
   | `open_castle_goal_quidditch` | off/on | off     | won all 6 Quidditch matches                                              |

   **Other options (optional)**: sensible defaults; leave them unless you specifically want the behavior. Both game modes unless noted.

   | Option                | Default                    | What it does                                                                                                                                                                                                                                                                         |
   | --------------------- | -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
   | `starting_spells`     | Flipendo, Lumos, Alohomora | Spells Harry starts with; any spell left off this list becomes an AP item. Vanilla physically needs Lumos + Flipendo to clear the Whomping Willow, so keep both unless they're placed very early. Valid: Alohomora, Flipendo, Lumos, Rictusempra, Skurge, Diffindo, Spongify. |
   | `vanilla_gate_levels` | on                         | **Vanilla only.** On: the 7 story-region keys are AP items and a bookcase blocks each region until its key arrives (linear story order). Off: all keys precollected, every region open from the start. No effect in open castle (keys are always AP items there).                    |
   | `tradersanity`        | off                        | Turns each non-Weasley card/ingredient vendor's first sale into an AP check, after which it reverts to selling normally. The price mode only changes what that check costs: `price_vanilla` a normal in-game price (ingredient vendors keep their real price, card vendors charge a card-like price), `price_random` a random price per vendor fixed for the seed (10-250 beans), `price_low` a flat 10 beans. With `enable_quidditch_upgrades` on, Fred & George also become Tradersanity vendors.                                  |
   | `tradersanity_hint_on_open` | on                   | First time you open dialogue with an unchecked Tradersanity vendor, the AP check at that vendor is broadcast-hinted so the room can see what item it's holding. No effect when `tradersanity` is off.                                                                                |
   | `skip_vendor_voices`  | off                        | Silences every vendor's in-trade voice cues (sell / transaction-done / decline / narrator / Harry-inquiry) so the trade UI advances instantly. The not-enough-beans, out-of-stock, and proximity lure lines are left alone. Mainly useful for Tradersanity runs where the same dialogue repeats.    |
   | `traps`               | all on                     | Set of trap types allowed in your pool (like `starting_spells` — choose any subset; default is all on, empty means none). Traps replace some filler. Options: `Bean Thief Trap` (steals beans), `Polyjuice Potion Trap` (turns Harry into Goyle for the level), `Obliviate Trap` (spellbook withheld ~30s), `Drowsiness Draught Trap` (sleepy slow ~6s), `Engorgio Trap` (giant Harry), `Reducio Trap` (tiny Harry), `Confundus Trap` (inverted camera look ~20s), `Overcompensation Trap` (giant wand for the rest of the level), `Levicorpus Trap` (Harry hangs upside down for the rest of the level). The Confundus/Drowsiness traps self-revert on a timer or the next level; the Engorgio, Reducio, Overcompensation, Levicorpus, and Polyjuice traps last the whole level and revert on the next one. `trap_fill_percent` (5-50, default 5) sets how much filler is replaced. |
   | `ring_link`           | off                        | Mirrors organic Bertie Bott's bean changes (in-game pickups + vendor spending) to and from other RingLink slots in the room. AP-granted bean filler and the Bean Thief trap are not mirrored. Compatible with Sonic-style RingLink games.                                            |
   | `trap_link`           | off                        | Standard Archipelago TrapLink: every trap you receive is also sent to all other TrapLink slots, and traps they receive are applied to you. Inbound traps respect your `traps` selection — a trap you turned off is remapped to one you kept. Independent of `traps` — you still receive linked traps with no traps of your own. |
   | `death_link`          | off                        | Standard Archipelago DeathLink: dying sends a death to every other DeathLink slot, and their deaths kill you.                                                                                                                                                                        |

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

For solo on the same machine, the server is typically `localhost:38281`.

You should see in the log tab:

```
Game-side TCP listener up on ('127.0.0.1', 42779)
```

The client connects to the AP server as soon as you `/connect` and reads your seed's config. If the server asks for your slot name, type it and press Enter. Leave the client window open; with auto-launch on (the default), the game starts itself next (see below).

### Launch the game

With **auto-launch on** (the default), the client starts the right `Game.exe` for the seed's mode by itself, a moment after you connect (and right after any randomizers finish writing, so the game never boots mid-patch). You don't have to launch anything; just start a new game once the window opens.

**First connect only:** the client needs to know where your install is, so it pops a folder picker asking for the install that matches the seed's mode (the folder that contains the `system` folder with `Game.exe`). Your choice is saved to `host.yaml`, so you're asked only once per mode. You can also set it ahead of time by editing host.yaml (see the install-path block under Sound randomizer below).

Within a few seconds of the game booting you should see in the client log:

```
Game connected from ('127.0.0.1', <port>)
[game→client] HELLO
```

The game window pops a toast top-right when your starting items arrive ("Received Alohomora from <YourSlotName>" etc). You're playing.

**Prefer to launch it yourself?** Set `auto_launch_game: false` under `harry_potter_2_pc_options` in host.yaml, then run `<HP2 install>\system\Game.exe` (or the M212 Start Menu shortcut) once the client is connected. The `/play` command in the client launches it too, handy if you closed the game and want it back, or if an auto-launch was skipped.

### Sound randomizer (optional)

Set `sound_randomizer` in your player yaml to shuffle the sound effects, deterministically per seed (a short sound only ever becomes another short sound). It has three settings:

- `off` (default): sound effects are left alone.
- `on`: every sound effect is shuffled.
- `no_footsteps`: the same, but Harry's footstep sounds are left alone, since randomizing them can get overwhelming.

It needs no mod changes: the client binary-patches `<install>\system\HPSounds.u` when you connect, keeping a one-time `HPSounds.u.orig` backup.

- **Install path (one per mode, you pick it).** There is no default. The first time you connect to a sound-randomizer seed, the client pops a folder picker and asks for the install that matches the seed's game mode (the folder that contains `system\HPSounds.u`). Your choice is saved to `host.yaml`, so you are asked only once per mode. You can also set it ahead of time (or change it later) by editing host.yaml directly; if you run a single install for both modes, point both fields at it:

  ```yaml
  harry_potter_2_pc_options:
    vanilla_install_folder: "<path to your vanilla-mode install>"
    open_castle_install_folder: "<path to your open-castle-mode install>"
    auto_launch_game: true   # default; set false to launch the game yourself
  ```

- **When it applies.** Patching runs a moment after you connect (it rewrites a large file in the background). With auto-launch on (the default), the client finishes patching before it starts the game, so the first launch already has the shuffled sounds and you don't have to time anything. If you launch the game yourself, wait for the client window to show `Sound randomizer applied ...` first (and if the game was already running, restart it once, since the package is read at launch). If you instead see a "could not write / run as administrator" line, see Permissions below.
- **Permissions.** The client patches a file inside your install, so it must be able to write there. If your install is under `Program Files` (the default location for the Harry Potter installation), Windows blocks writes unless the program is elevated, so you **must run ArchipelagoLauncher as administrator** (right-click it, "Run as administrator"). Otherwise the patch fails and the client log says so. Alternatively, use an install in a folder you can write to without elevation.
- **Don't like a swapped sound?** Type `/reroll_sounds` in the client to reshuffle everything with a fresh random set. The new shuffle is remembered for that seed, so it sticks across restarts (restart once to hear it). Run it again if the new set is no better.
- **Revert to the original sounds.** Connect to a seed with the option off (it auto-restores), or type `/restore_sounds` in the client, or manually copy `HPSounds.u.orig` over `HPSounds.u`. Either way, restart the game once to hear the original sounds again.

### Music randomizer (optional)

Set `music_randomizer: true` in your player yaml to shuffle every music track, deterministically per seed (background tracks swap with background tracks, short jingles with jingles). It works the same way as the sound randomizer: the client swaps the `Music\*.ogg` files in your install on connect, keeping a one-time backup. Because it swaps files rather than rewriting triggers, it covers cutscene, menu, and spell-lesson music too.

- **Same install path, permissions, and timing** as the sound randomizer above (it uses the same per-mode `install_folder`, picks it once, needs write access / admin under `Program Files`, and takes effect on the next launch).
- **Reshuffle**: `/reroll_music`. **Revert**: `/restore_music`, or connect to a seed with the option off. Restart once to hear the change.

### Dialogue randomizer (optional)

Set `dialogue_randomizer` in your player yaml to shuffle the spoken voice lines, deterministically per seed. It has three settings:

- `off` (default): dialogue is left alone.
- `within_actor`: each character's lines are shuffled among their own, so every character keeps their own voice but says the wrong things.
- `all_actors`: lines are shuffled across every character, so anyone can speak anyone's line.

It works the same way as the sound randomizer: the client binary-patches `<install>\Sounds\AllDialog.uax` (the voices) and the subtitle files `<install>\system\hpdialog.int` and `<install>\system\BumpDialog.int` (the latter holds the student bump lines) on connect, keeping one-time `.orig` backups of each. All are shuffled with the same permutation, so the caption you read matches the line you hear. A few clips have no subtitle in the game to begin with (Quidditch/duel commentary, ambient mutters, alternate takes); when one of those plays it shows no caption, exactly as in the unmodified game.

- **Same install path, permissions, and timing** as the sound randomizer above (same per-mode `install_folder`, picks it once, needs write access / admin under `Program Files`, takes effect on the next launch).
- **Reshuffle**: `/reroll_dialogue` (keeps the seed's mode). **Revert**: `/restore_dialogue`, or connect to a seed with the option off, or manually copy `AllDialog.uax.orig`, `hpdialog.int.orig`, and `BumpDialog.int.orig` back over their files. Restart once to hear the change.

## Verify it's working

Quick checklist after first launch:

- **Toasts appear top-right** when items arrive. If not, the mod isn't loaded; see Troubleshooting below.
- **Bookcases block the spell classrooms** you haven't been granted yet. If you can walk straight into Lockhart's DADA classroom and the spell-tutorial cutscene fires immediately, the mod isn't running.
- **Picking up a wizard card** should fire a `CHECK <id>` line in the client log and (if you have any items waiting) hand you something back.
- **Goal (vanilla):** the seed completes when you defeat the Basilisk and the post-Basilisk Great Hall walk-in fires the credits.
- **Goal (open castle):** the Great Hall stays locked until you meet your configured goal clauses (`open_castle_goal_*`); once you do, walking into the Great Hall completes the slot. Type `/progress` in the client at any time to print a per-clause `[x]/[ ] have / need` summary; the in-game pause menu shows the same panel.

## Troubleshooting

**Mod doesn't load** (no toasts, classrooms aren't blocked):

- Check `<HP2 install>\system\HPArchipelago.u` exists.
- Check `<HP2 install>\system\Default.ini` is the shipped one; open it and confirm `EditPackages=HPArchipelago` is present (search for it).
- If `C:\Users\<you>\Documents\Harry - Coding Evolved\HP.ini` exists, it overrides `Default.ini`, delete it.
- If `C:\Users\<you>\Documents\Harry - Coding Evolved\Game.ini` exists, it overrides both. Either delete it, or open it and make sure `[Engine.Engine]` has `DefaultGame=HPArchipelago.APGameInfo` (not `DefaultGame=Engine.GameInfo`).
- Read `C:\Users\<you>\Documents\Harry - Coding Evolved\Game.log`, search for `[Archipelago]` lines. Encoding is UTF-16LE (`Get-Content -Encoding Unicode` in PowerShell).

**Silent NPCs / no dialog plays in cutscenes**:

- Vanilla install issue, not the mod. The game ships with `Language=int` in `[Engine.Engine]`, which looks for UK English voice files some installs don't have (common on non-US installs).
- Open `<HP2 install>\system\Default.ini`, find `[Engine.Engine]`, change `Language=int` to `Language=usa`, save, and relaunch.

**Toast says "AP: WRONG INSTALL …"**:

- This means your seed's `game_mode` doesn't match the maps you launched: a `vanilla` seed on the HP2 Bingo install, or an `open_castle` seed on the vanilla install. A mismatched seed can't be completed (some checks become unreachable and the goal never unlocks), so the warning re-shows on every level until you fix it.
- Fix it by launching the matching install: `game_mode: vanilla` → your retail/M212 install; `game_mode: open_castle` → your HP2 Bingo install (see "Optional: install the HP2 Bingo distribution too"). The seed itself is fine; you don't need to regenerate, just connect from the right `Game.exe`.
- The warning is informational; the game won't stop you from continuing into a broken seed, so don't ignore it.

**"HP2 PC Client" button missing from Archipelago Launcher**:

- The apworld isn't installed where the launcher can see it. Confirm `harry_potter_2_pc.apworld` exists in `<Archipelago install>\custom_worlds\`.
- Close and reopen ArchipelagoLauncher fully; launcher components are discovered on startup, not refreshed live.

**Seed generation can't find the apworld**:

- The `.apworld` file isn't in `<Archipelago install>\custom_worlds\`. Drop it there, restart ArchipelagoLauncher.

**Client disconnects mid-session**:

- The mod auto-reconnects with exponential backoff (1s up to a 16s cap). Just restart the client; the game will reconnect on the next try.
- Items the AP server delivered while the client was down get replayed on reconnect. Every item type (cards, spells, equipment, all bean tiers, every other filler, and traps) is durable across a client crash, reconnect, or game save-load: the client keeps a per-slot consumed-item ledger in Archipelago server storage, so an item already applied is never re-granted (no double beans) and one you haven't received yet still arrives. The only way to lose an item: receive it in-game, then quit **without saving** and reload that older save, where the ledger correctly considers it already delivered, so it won't be handed out again. Save after receiving items, or start a new game on the slot (which re-grants everything).

**Game crashes at level transition**:

- Probably an unrelated M212 issue, check the M212 Discord. The randomizer mod doesn't touch level loading.

**A specific card doesn't fire its check when picked up**:

- Open `Game.log` and search for the card's id. If the line `APCardMarker.Touch: firing CHECK <n>` is there but no AP item arrives, the AP server side is the issue.
- If `APCardMarker.Touch` doesn't fire, the marker wasn't placed (check `ReplaceCardChests:` log lines for that level).

**Still stuck?** Feel free to contact Kryen in the Archipelago Discord.

## Logs

For bug reports, attach these:

| What          | Where                                                                                                          |
| ------------- | -------------------------------------------------------------------------------------------------------------- |
| Game-side log | `C:\Users\<you>\Documents\Harry - Coding Evolved\Game.log` (UTF-16LE)                                          |
| Client log    | Scroll the **Archipelago** tab of the HP2 PC Client window, or check `<Archipelago install>\logs\HP2PC_AP.txt` |
| AP server log | `<Archipelago install>\logs\`                                                                                  |

## Where to ask for help

- HP2 modding Discord (engine and game-specific issues).
- Archipelago Discord, `#future-game-design`. Feel free to contact Kryen there.
- GitHub issues at this project's repo.
