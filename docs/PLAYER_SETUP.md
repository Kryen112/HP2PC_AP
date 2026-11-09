# HP2PC_AP - Player Setup

Install and first-run guide for the Harry Potter and the Chamber of Secrets PC Archipelago randomizer. It covers only what is specific to this game; for Archipelago itself (installing it, generating and hosting a seed, connecting a client) see the [Archipelago setup guide](https://archipelago.gg/tutorial/Archipelago/setup/en).

If you're a developer wanting to _modify_ the mod or apworld, read [`DEV_SETUP.md`](DEV_SETUP.md) instead.

---

## What you're getting

- An Archipelago randomizer for HP2 (PC, KnowWonder 2002 release).
- Up to 560 checks in vanilla and 601 in open castle: 101 wizard cards, 109 secret areas (118 in open castle), 44 challenge stars (54), 12 level completions (13), 4 spell-tutorial classrooms (vanilla only), 10 ranked duels, 6 Quidditch matches, 4 spell-challenge par times, 2 Fred & George purchases, 255 containers (280), and 13 Tradersanity vendors. Most categories have a yaml toggle so you can dial the size of the seed (see [Options](#options)).
- Goal: in vanilla, defeat the Basilisk; in open castle, meet your configured goal clauses to unlock the Great Hall.

## Mod-only features

### Hold Shift to run

Hold Shift while moving and Harry runs a little over 1.5x speed. It costs 4 Bertie Bott's beans every second. No running once you're at 0 beans.

The `allow_running_logic` yaml option makes running **free**. Set it to `on` for the straightforward runs, or `difficult` to also expect the ones with tight timing or precise positioning. With it off (the default) running still works exactly the same, it just costs beans and is never logically required.

### Return to the Entry Hall (pause menu)

The pause menu has a **Return to Entry Hall** button in the middle of the bottom row. It's your escape from a softlock, or a handy tool to get around the castle quicker.

### Check status without alt-tabbing (pause menu)

In both game modes, an **Unlocked** panel lists the spells and level keys you've received, newest at the bottom.
In open castle, the pause menu also draws a live goal-progress panel (cards / spells / levels / duels / Quidditch, have vs need) on the left.

### Client commands worth knowing

`/progress` prints your goal status. `/play` (re)launches the game. `/autoplay` turns auto-launch on or off for this client session. `/installmod` installs or updates the mod in your install (the client also does this on connect). The audio randomizers each have a reshuffle/restore pair: `/reroll_sounds` `/restore_sounds`, `/reroll_music` `/restore_music`, `/reroll_dialogue` `/restore_dialogue`.

`/ringlink`, `/traplink`, `/deathlink` and `/ghosts` turn the matching link on or off mid-run, so you do not have to reroll a seed to change your mind.

## Prerequisites

| Thing                                            | Where to get it                                                                                                                                                         |
| ------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Harry Potter and the Chamber of Secrets (PC)** | The KnowWonder 2002 PC release, installed on your computer. The randomizer **does not include the game** and ships no game files.                                       |
| **SafeDiscShim**                                 | <https://github.com/RibShark/SafeDiscShim/releases>, latest release. The disc release uses SafeDisc copy protection, which Windows 10 and 11 can no longer run on their own. |
| **Archipelago**                                  | <https://github.com/ArchipelagoMW/Archipelago/releases>, the latest stable release.                                                                                     |
| **HP2PC_AP release files**                       | From the GitHub release: `harry_potter_2_pc.apworld` and this `PLAYER_SETUP.md`.                                                                                        |

### Linux (experimental)

The client supports Linux, but whether the game's SafeDisc disc check passes under Wine or Proton is **not confirmed yet**. If you try it, please report back either way.

- Install the game into a **Wine or Proton prefix**. Run Archipelago and the HP2 PC Client natively on Linux.
- SafeDiscShim stands in for a driver that modern Windows dropped. Wine is reported to handle SafeDisc by itself ([unconfirmed](https://github.com/RibShark/SafeDiscShim/issues/5)), so the disc check may work without it. Try the game without it first; if the disc check fails, install SafeDiscShim into the same prefix.
- Point the client at the install's real location inside the prefix (under `drive_c/`). After you connect to a seed, the client finds the prefix from that path and uses its `drive_c/users/<user>/Documents/Harry Potter II/` folder for `Game.ini`, the saves and the game link folder. If the prefix has several users, launch the game once first so it creates that folder.
- **Auto-launch** runs `wine` from your `PATH` with that prefix as `WINEPREFIX`. For a Proton prefix the client does not launch the game (the system `wine` would convert Steam's prefix): set `auto_launch_game: false` in host.yaml and start the game through Steam once the client is connected.
- The client picks the game link folder once per session. After changing the install folder, restart the client.
- No administrator step: a prefix under your home folder is writable.
- Paths this guide writes as `Documents\Harry Potter II\` are inside the prefix, for example `drive_c/users/steamuser/Documents/Harry Potter II/` under Proton.

## Install

### 1. Install the game

Install HP2. A folder you can write to without administrator rights is easiest (for example `C:\Games\HP2\`), because the client writes the mod into the install; under `Program Files` you have to run the Archipelago Launcher as administrator instead. The installer may pick the game's language from your Windows region; that is fine.

### 2. Install SafeDiscShim and check the game starts

1. Download the latest release from <https://github.com/RibShark/SafeDiscShim/releases> and run the installer.
2. With the disc in the drive, start `<HP2 install>\system\Game.exe`. After a short disc check (about half a minute) the game's main menu appears (New Game / Load Game / Options).
3. Start a new game and play until Privet Drive has loaded, then quit.

If the game does not start, see [Troubleshooting](#troubleshooting). Get this working before going further: nothing later in this guide can fix a game that does not start.

### 3. Install the apworld

Drop `harry_potter_2_pc.apworld` into Archipelago's custom worlds folder:

```
<Archipelago install>\custom_worlds\harry_potter_2_pc.apworld
```

Now `HP2 PC Client` appears as a button in the Archipelago Launcher.

### 4. The mod: the client installs it for you

The first time you connect the client to a seed, it pops a folder picker asking for your HP2 install (the folder containing `system\Game.exe`; saved to `host.yaml`, so you are asked only once) and then sets that install up:

- copies the compiled mod into `<HP2 install>\system\`
- patches `<HP2 install>\system\Default.ini` in place: `DefaultGame=HPArchipelago.APGameInfo` and `Console=HPArchipelago.APConsole` under `[Engine.Engine]`, plus the folder the game and the client share (`ChannelDir=`, under `[HPArchipelago.APIPCActor]`)
- turns off the renderer's texture precache (`UsePrecache=False` under `[D3DDrv.D3DRenderDevice]`): with it on, see-through textures such as torch cages, fences and Harry's glasses draw solid, especially after you minimize or Alt+Tab
- applies the same settings to your per-user `Documents\Harry Potter II\Game.ini`, since that file would otherwise shadow `Default.ini` back to the original game; your own settings (resolution, volume) survive, nothing is deleted
- creates the shared folder `Documents\Harry Potter II\AP\`
- keeps one-time backups of every file it touches, under `<HP2 install>\_archipelago_backup\` and `Documents\Harry Potter II\_archipelago_backup\`

Every later connect re-checks the installed mod against the apworld's copy byte for byte, and the ini settings too, so **updating the randomizer is just replacing the `.apworld` file**: the client updates the game install on the next connect. If the game is running at that moment (the launcher window with New Game / Load Game counts too), the client says so; close it and type `/installmod`. If the install folder refuses the write, the client raises a popup with the fix and does not auto-launch. While an older mod build is still installed, the game repeats an `AP: mod update ...` reminder every ten seconds until the update lands.

> **Permissions:** the client writes inside your install, so if HP2 lives under `Program Files`, run ArchipelagoLauncher as administrator (right-click, "Run as administrator"), or move the install somewhere writable (e.g. `C:\Games\HP2\`). The audio randomizers need the same.

### Open castle

The `open_castle` game mode plays on the same install as `vanilla`; there is nothing extra to install. After the flying car, Harry lands in the Entry Hall with every level reachable, gated by the bookcase keys. The client patches your own `Maps\Grounds_hub.unr` when you connect to an open castle seed, to make it playable. It keeps a `Grounds_hub.unr.orig` backup and puts the original back when you connect to a `vanilla` seed.

## Options

Your player yaml comes from the Archipelago Launcher's **Generate Template Options**, like any other game.

### Game mode

```yaml
Harry Potter 2 PC:
  game_mode: vanilla # default, the original game
  # game_mode: open_castle   # every level open after the initial cutscenes
```

Both modes play on the same install. The client tells the mod which mode the seed uses when it connects.

### What becomes a check

| Toggle                         | Default | What it enables                                                                                            |
| ------------------------------ | ------- | ---------------------------------------------------------------------------------------------------------- |
| `enable_wizard_cards`          | on      | Card shuffle. The 101 wizard cards are always checks; **on** shuffles the card items into the multiworld pool (`Bronze/Silver/Gold Card - X`), **off** keeps each card in its own spot. |
| `enable_secrets`               | on      | 109 secret-area pickups across all levels (open castle adds 9 in the Gryffindor challenge, 118 total).     |
| `enable_challenge_stars`       | on      | 44 challenge stars across the 4 spell-challenge levels (open castle adds 10 in the Gryffindor challenge, 54 total). |
| `enable_duelling`              | off     | 10 Duelling Club ranked-duel wins.                                                                         |
| `enable_quidditch_matches`     | off     | 6 Quidditch matches (3 regular + 3 final-tournament).                                                      |
| `enable_spell_challenge_times` | off     | Beating the replay par time ("Mastered") on each of the 4 spell challenges.                                 |
| `enable_quidditch_upgrades`    | off     | Buying Nimbus 2001 and Quidditch Armour from Fred & George becomes 2 checks and the gear enters the pool.  |
| `containersanity`              | off     | 255 in-world containers (280 in open castle): chests without cards, cauldrons, boxes, vases, plant pots, knights, statues and more. Opening one with its spell (Alohomora or Flipendo) ejects an AP token; walk over it to send the check. |

The wizard cards and the level completions (12 in vanilla, 13 in open castle with the Gold Card Room) are always checks, and so are the 4 spell-tutorial classrooms in vanilla. `allow_missable_progression` (default off) controls whether progression items may be placed at missable locations in levels you cannot replay (missable secrets, plus containers in those levels).

### Open castle goal

In `open_castle` the slot completes by opening the Great Hall, not by the Basilisk fight. Five options set the requirement; they're AND'd together, and any clause left at `0`/off drops out. If all five are `0`/off it falls back to "all 7 spells". All five are ignored in vanilla.

| Option                       | Range  | Default | Great Hall opens once you have…                                          |
| ---------------------------- | ------ | ------- | ------------------------------------------------------------------------ |
| `open_castle_goal_cards`     | 0-101  | 50      | that many wizard cards (named anchors: `none`/`few`/`half`/`most`/`all`) |
| `open_castle_goal_spells`    | 0-7    | 7       | that many spells                                                         |
| `open_castle_goal_levels`    | 0-13   | 13      | that many of the 13 level objectives finished (incl. the Gold Card Room, which needs 20 silver cards) |
| `open_castle_goal_duels`     | off/on | off     | won all 10 Duelling Club duels                                           |
| `open_castle_goal_quidditch` | off/on | off     | won all 6 Quidditch matches                                              |

### Other options

Sensible defaults; leave them unless you want the behavior. Both game modes unless noted.

| Option                | Default                    | What it does |
| --------------------- | -------------------------- | ------------ |
| `starting_spells`     | Flipendo, Lumos, Alohomora | Spells Harry starts with; any spell left off this list becomes an AP item. Vanilla always adds Lumos and Flipendo, since the Whomping Willow needs both. In open castle, a start with too few spells and secrets off is rejected at generation. Valid: Alohomora, Flipendo, Lumos, Rictusempra, Skurge, Diffindo, Spongify. |
| `vanilla_gate_levels` | on                         | **Vanilla only.** On: the story levels sit behind a bookcase until their key arrives. The 5 story levels follow the game's order, so they share 5 copies of one `Progressive Level Key`; Duelling and Quidditch keep their own keys. Off: every region open from the start. |
| `always_goyle_in_slytherin_common_room` | on | **Open castle only.** Harry wears the Goyle disguise for the whole Slytherin Common Room, so the Slytherins there never chase him. A Polyjuice Potion Trap has no effect inside the room, and the disguise comes off when you leave. |
| `allow_running_logic` | off                        | Expects running in logic, so checks reachable by running no longer need the spell they'd otherwise need, and running becomes free. `on`: the comfortable runs. `difficult`: also the runs needing tight timing or precise positioning. |
| `tradersanity`        | off                        | Each non-Weasley card or ingredient vendor's first sale becomes an AP check, after which it sells normally. `price_vanilla`: a normal in-game price. `price_random`: a random price per vendor (10-250 beans). `price_low`: a flat 10 beans. With `enable_quidditch_upgrades` on, Fred & George join in. |
| `tradersanity_hint_on_open` | on                   | The first time you talk to an unchecked Tradersanity vendor, its item is hinted to the room. |
| `skip_vendor_voices`  | off                        | Silences the vendors' trade voice lines so the trade screen advances instantly. Handy for Tradersanity runs. |
| `traps`               | all on                     | Trap types allowed in your pool (empty means none). `Bean Thief Trap` (steals beans), `Polyjuice Potion Trap` (Harry becomes Goyle for the level), `Obliviate Trap` (spellbook withheld ~30s), `Drowsiness Draught Trap` (slow ~20s), `Engorgio Trap` (giant Harry ~30s), `Reducio Trap` (tiny Harry ~30s), `Confundus Trap` (inverted camera ~20s), `Overcompensation Trap` (giant wand for the level), `Levicorpus Trap` (upside down ~30s), `Jelly-Legs Jinx Trap` (random jumping ~20s). `trap_fill_percent` (5-50, default 5) sets how much filler becomes traps. |
| `ring_link`           | off                        | Mirrors bean pickups and vendor spending to and from other RingLink slots. AP bean items and the Bean Thief trap are not mirrored. |
| `trap_link`           | off                        | Traps you receive go to every other TrapLink slot, and theirs come to you. A linked trap you turned off becomes one you kept. |
| `death_link`          | off                        | Dying sends a death to every other DeathLink slot, and their deaths kill you. |
| `ghost_players`       | on                         | Other HP2 players on the same map appear in your game as translucent ghosts with their slot name overhead, and you appear in theirs. Cosmetic only. `/ghosts` toggles it mid-run; off also stops sharing your own position. |
| `sound_randomizer`, `music_randomizer`, `dialogue_randomizer` | off | See [Audio randomizers](#audio-randomizers). |

## Play

Open the Archipelago Launcher, click **HP2 PC Client** and connect to your server as usual. Leave the client window open.

### Launch the game

With **auto-launch on** (the default), the client starts `Game.exe` a moment after you connect, after any audio randomizer has finished writing. The disc check takes about half a minute before the main menu appears, so give it time (typing `/play` meanwhile does not start a second copy). Then pick New Game or Load Game. Every connect you make yourself launches it again if the game is not running, so closing the game and reconnecting brings it back.

**First connect only:** the client asks for your install folder (the one that contains `system\Game.exe`) and saves it to `host.yaml`.

A few seconds after you pick New Game or Load Game the client log says:

```
The Harry Potter 2 game connected to this client. It can now send and receive items.
```

The game pops a toast top-right when items arrive ("Received Alohomora from <YourSlotName>"). Items are handed over while Harry is walking around, not during cutscenes or the opening of a level, so the first ones may take a moment.

**Prefer to launch it yourself?** Set `auto_launch_game: false` in host.yaml and start `<HP2 install>\system\Game.exe` once the client is connected. `/play` launches it too, and `/autoplay off` turns auto-launch off for just this client session.

### Client settings (host.yaml)

These belong to your client, not the seed, so change them whenever you like. They apply the next time the game starts (`widescreen_view` on the next connect).

```yaml
harry_potter_2_pc_options:
  install_folder: "<path to your install>"
  auto_launch_game: true   # set false to launch the game yourself
  auto_install_mod: true   # set false to manage the mod files yourself (/installmod still works)
  borderless_window: true  # set false to keep the game's normal window
  frame_rate_cap: true     # holds the game at 60 fps so it runs at the right speed
  widescreen_view: true    # set false for the game's original 4:3 view
```

- `borderless_window`: the game fills your screen without a window frame. The game cannot open a window wider than 2048 pixels, so on a wider monitor it shows centered at the largest size of the same shape.
- `frame_rate_cap`: uncapped, the game runs too fast and its speed changes as you look around. The client edits one instruction in `<install>\system\Engine.dll` and keeps `Engine.dll.orig`; turning the setting off puts the original back.
- `widescreen_view`: on a wide screen you see more of the world at the sides, and the menus stay 4:3 in the middle with black bars.

### Audio randomizers

Three yaml options shuffle the game's audio, deterministically per seed. All three work the same way:

- The client rewrites files in your install when you connect, keeping a one-time `.orig` backup of each. With auto-launch on, it finishes before it starts the game. If you launch the game yourself, wait for the client to say the randomizer was applied, and restart the game if it was already running.
- It needs write access to the install, so under `Program Files` run the Archipelago Launcher as administrator.
- `/reroll_...` reshuffles with a fresh random set, remembered for that seed. `/restore_...` puts the originals back, and so does connecting to a seed with the option off. Restart the game once to hear the change.

| Option                | Settings | What it shuffles |
| --------------------- | -------- | ---------------- |
| `sound_randomizer`    | `off`, `on`, `no_footsteps` | Sound effects (a short sound only ever becomes another short sound), in `system\HPSounds.u`. `no_footsteps` leaves Harry's footsteps alone. Commands: `/reroll_sounds`, `/restore_sounds`. |
| `music_randomizer`    | `false`, `true` | Every music track, including cutscene, menu and spell-lesson music, by swapping the `Music\*.ogg` files (background tracks with background tracks, jingles with jingles). Commands: `/reroll_music`, `/restore_music`. |
| `dialogue_randomizer` | `off`, `within_actor`, `all_actors` | Spoken lines and their subtitles together, so the caption matches the line you hear. `within_actor` keeps each character's voice but shuffles what they say; `all_actors` lets anyone speak anyone's line. Works on non-English installs too. Commands: `/reroll_dialogue`, `/restore_dialogue`. |

### PopTracker map tracker (optional)

A [PopTracker](https://github.com/black-sliver/PopTracker/) pack autotracks your run: items, checks and goal progress update live, every check shows as a pin on per-floor maps, and the tracker follows Harry to whatever map he's in. It reads your settings from the seed.

1. Install **PopTracker v0.31.0 or newer**.
2. Download the [HP2 tracker pack](https://github.com/Kryen112/HP2PC_AP_Poptracker/releases/latest) and drop it into PopTracker's `packs/` folder.
3. In PopTracker, click **Load Pack**, pick the Harry Potter 2 PC pack, and choose the variant for your game mode.
4. Click the AP connection button and enter the same server address, slot name and password you used in the client.

## Verify it's working

- **The client says the game connected** a few seconds after you pick New Game or Load Game.
- **Toasts appear top-right** when items arrive. If not, the mod isn't loaded; see Troubleshooting.
- **Bookcases block the spell classrooms** you haven't been granted yet (vanilla). If you can walk straight into Lockhart's classroom and the spell-tutorial cutscene fires, the mod isn't running.
- **Goal (vanilla):** defeat the Basilisk and walk into the Great Hall.
- **Goal (open castle):** the Great Hall stays locked until you meet your goal clauses; then walking into it completes the slot. `/progress` and the pause menu show where you stand.

## Troubleshooting

**The game does not start**:

- Make sure SafeDiscShim is installed ([step 2](#2-install-safediscshim-and-check-the-game-starts)) and the disc is in the drive.
- Windows 11 **Smart App Control** can block SafeDiscShim. Check Windows Security, App & browser control, Smart App Control.
- SafeDiscShim writes a log next to `<HP2 install>\system\Game.exe` (`Game.exe_SafeDiscShim.log`); attach it if you ask for help.

**The game crashes or goes black when a level starts** (only when you start the game yourself, outside the client):

- Run it windowed: in `Documents\Harry Potter II\Game.ini`, under `[WinDrv.WindowsClient]`, set `StartupFullscreen=False`. The client does this for you when it launches the game, and still fills the screen.

**Mod doesn't load** (no toasts, classrooms aren't blocked):

- Make sure you launch the install the client set up: the one saved as `install_folder` in `host.yaml`.
- Close the game, including its main menu window, and type `/installmod` in the connected client (or reconnect). It re-deploys the mod and re-wires both inis, then says `Mod: updated to this version.` or `Mod: already up to date.`. If it reports a permissions error, run the Archipelago Launcher as administrator.
- Search `Documents\Harry Potter II\Game.log` for `[Archipelago]` lines.

**Client says `Default.ini not found; is this a Harry Potter 2 install?`**:

- The folder you pointed the client at is not the game install. It wants the folder that contains `system\Game.exe`. Fix `install_folder` in `host.yaml`.

**Silent NPCs / no dialog plays in cutscenes**:

- Leave `Language=` under `[Engine.Engine]` in `Default.ini` and `Game.ini` as the installer set it. It names the language files the game loads, so a different value points at files your install does not have.
- If the dialogue randomizer is on, type `/restore_dialogue`, restart the game, and check whether the voices come back. If they do, report it with your `Game.log`.

**Client disconnects mid-session**:

- Restart the client and reconnect while the game keeps running; the game picks the new client up within a few seconds, and anything sent in between is delivered then.
- Items received while the client was down arrive on reconnect, and an item already applied is never granted twice. The one way to lose an item: receive it, quit **without saving**, and reload the older save. Save after receiving items.

**Still stuck?** Contact Kryen in the Archipelago Discord.

## Logs

For bug reports, attach these:

| What          | Where                                                                                              |
| ------------- | -------------------------------------------------------------------------------------------------- |
| Game log      | `C:\Users\<you>\Documents\Harry Potter II\Game.log`                                                |
| SafeDiscShim  | `<HP2 install>\system\Game.exe_SafeDiscShim.log` (only when the game will not start)               |
| Client log    | The **Archipelago** tab of the HP2 PC Client window, or `<Archipelago install>\logs\`              |

## Where to ask for help

- Archipelago Discord, `#future-game-design`. Feel free to contact Kryen there.
- GitHub issues at this project's repo.
