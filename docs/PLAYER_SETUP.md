# HP2PC_AP - Player Setup

End-to-end install and first-run guide for the Harry Potter and the Chamber of Secrets PC Archipelago randomizer.

If you're a developer wanting to _modify_ the mod or apworld, skip this and read [`DEV_SETUP.md`](DEV_SETUP.md) instead.

---

## What you're getting

- An Archipelago multiworld randomizer for HP2 (PC, KnowWonder 2002 release).
- Up to ~579 checks across 10 categories: 4 spell-tutorial classrooms, 101 wizard cards, 109 secret areas, 44 challenge stars, 10 ranked duels, 6 Quidditch matches, 4 spell-challenge par times, 2 Fred & George vendor purchases, ~283 containersanity containers, and up to 13 Tradersanity vendor checks. Each category is gated by a yaml toggle so you can dial difficulty (see "Configure your slot" below).
- Goal: in vanilla, defeat the Basilisk; in open castle, satisfy your configured goal clauses to unlock the Great Hall (see "Game mode" below).
- Plays solo or as a slot in a larger AP multiworld.

## Mod-only features (not in the base game)

The randomizer adds gameplay the original game never prompts you about, and none of it shows up in the in-game controls menu. The full list:

### Hold Shift to run

Hold Shift while moving and Harry runs a little over 1.5x speed. It costs 1 Bertie Bott's bean every quarter-second you're actually moving, drawn from your bean stash, and stops on its own when you hit 0. The run carries through jumps and spell casts, and idling on Shift costs nothing. It's disabled while a slowdown is active (Drowsiness trap, Skurge ectoplasm, spider web) and during cutscenes.

The `allow_running_logic` yaml option makes running **free** (no bean cost, usable even at 0 beans) and lets the generator place items in spots you're expected to reach by running. Set it to `on` for the straightforward runs, or `difficult` to also expect the ones with tight timing or precise positioning. With it off (the default) running still works exactly the same, it just costs beans and is never logically required.

### Return to the Entry Hall (pause menu)

The pause menu has a **Return to Entry Hall** button in the middle of the bottom row. It's your escape from a softlock: you entered a level, partially cleared it, and a one-way door trapped you. It teleports you to the hub and commits your progress first (found secrets, picked-up beans, dropped loot), so nothing is lost. It's hidden during cutscenes and the level intro, so wait until you have control.

### Check status without alt-tabbing (pause menu)

In open castle, the pause menu draws a live goal-progress panel (cards / spells / levels / duels / Quidditch, have vs need), the same figures as the client's `/progress`. In every AP mode, an **Unlocked** panel lists the spells and level keys you've received, newest at the bottom.

### What the wizard card tiers do

- **Bronze** cards give Harry an extra health bar for every 10 you hold.
- **Silver** cards open the Gold Card Room (20 needed in open castle, 40 in vanilla).
- **Gold** cards are collectibles only. They don't unlock anything.

### Containers and vendors (only if you enabled them)

- `containersanity`: in-world containers (chests, cauldrons, boxes, vases, and more) each give an AP token when you open them with Alohomora or Flipendo. Walk over the token to send the check.
- `tradersanity`: a vendor's first sale becomes an AP check, after which it sells normally.

### Client commands worth knowing

`/progress` prints your goal status. `/play` (re)launches the game. `/autoplay` turns auto-launch on or off for this client session (`on`, `off`, or bare to flip). `/installmod` installs or updates the mod in the seed's install (the client also does this on connect). The randomizers each have a reshuffle/restore pair: `/reroll_sounds` `/restore_sounds`, `/reroll_music` `/restore_music`, `/reroll_dialogue` `/restore_dialogue` (see the randomizer sections above).

`/ringlink`, `/traplink`, `/deathlink` and `/ghosts` turn the matching link on or off mid-run, so you do not have to reroll a seed to change your mind. Each takes `on`, `off`, or `seed` (back to whatever you rolled); typing the bare command flips it. Your choice sticks across a reconnect and resets when you restart the client. None of the four affects what is reachable, so toggling one can never make your seed unbeatable. Two notes: turning RingLink on links bean changes from that moment, with no back-fill of the deltas you missed, and TrapLink sends you only the traps you enabled, or any trap if your own seed enabled none.

## Prerequisites

> [!IMPORTANT]
> **You need the original disc.** The randomizer runs on the game installed from your own disc, and the disc has to be in the drive every time you play. On Windows 10 and 11 the disc's SafeDisc copy protection also needs **SafeDiscShim** (free, open source) before the game will start. The randomizer never patches the game executable and ships no game files.

| Thing                                            | Where to get it                                                                                                                                                                                               |
| ------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Harry Potter and the Chamber of Secrets (PC)** | Your own disc, KnowWonder 2002 build. The randomizer **does not include the game**.                                                                                                                         |
| **SafeDiscShim**                                 | <https://github.com/RibShark/SafeDiscShim/releases>, latest release, run its installer. Windows 10 and 11 no longer ship the driver SafeDisc talks to; SafeDiscShim answers in its place. It does not remove the protection, so the disc is still required. |
| **Archipelago framework**                        | <https://github.com/ArchipelagoMW/Archipelago/releases>, pick the latest stable Windows installer. Used for seed generation and hosting.                                                                      |
| **HP2PC_AP release files**                       | Downloaded from the GitHub release: `harry_potter_2_pc.apworld` and this `PLAYER_SETUP.md`. The compiled mod, its config wiring, and the Python client are all bundled inside the apworld; no separate files. |

OS: Windows 10 or Windows 11.

### Linux (experimental)

The client supports Linux, but whether the game's SafeDisc disc check passes under Wine or Proton is **not confirmed yet**. If you try it, please report back either way.

- Install the game from the disc into a **Wine or Proton prefix**. Run Archipelago and the HP2 PC Client natively on Linux.
- SafeDiscShim stands in for a driver that modern Windows dropped. Wine is reported to handle SafeDisc by itself ([unconfirmed](https://github.com/RibShark/SafeDiscShim/issues/5)), so the disc check may work without it. Try the game without it first; if the disc check fails, install SafeDiscShim into the same prefix.
- Point the client at the install's real location inside the prefix (under `drive_c/`). After you connect to a seed, the client finds the prefix from that path and uses its `drive_c/users/<user>/Documents/Harry Potter II/` folder for `Game.ini`, the saves and the game link folder. If the prefix has several users, launch the game once first so it creates that folder.
- **Auto-launch** runs `wine` from your `PATH` with that prefix as `WINEPREFIX`. For a Proton prefix the client does not launch the game (the system `wine` would convert Steam's prefix): set `auto_launch_game: false` under `harry_potter_2_pc_options` in host.yaml and start the game through Steam once the client is connected.
- The client picks the game link folder once per session. After changing the install folder, restart the client.
- No administrator step: a prefix under your home folder is writable.
- Paths this guide writes as `Documents\Harry Potter II\` are inside the prefix, for example `drive_c/users/steamuser/Documents/Harry Potter II/` under Proton.

## Install

### 1. Install HP2 from your disc

Install the game from the disc. A folder you can write to without administrator rights is easiest (for example `C:\Games\HP2\`), because the client writes the mod into the install; under `Program Files` you have to run the Archipelago Launcher as administrator instead. The installer may pick the game's language from your Windows region; that is fine.

### 2. Install SafeDiscShim and check the game starts

1. Download the latest release from <https://github.com/RibShark/SafeDiscShim/releases> and run the installer.
2. Put the game disc in the drive and start `<HP2 install>\system\Game.exe`. After a short disc check (about half a minute) the game's main menu appears (New Game / Load Game / Options).
3. Start a new game and play until Privet Drive has loaded, then quit.

If the game does not start, or SafeDisc complains about the disc, see [Troubleshooting](#troubleshooting). Get this working before going further: nothing later in this guide can fix a game that does not start.

**Fullscreen problems?** On some systems the game crashes or shows a black screen when a level starts in fullscreen. Run it in a window instead: open `Documents\Harry Potter II\Game.ini` (created by the first launch), find `[WinDrv.WindowsClient]`, and set `StartupFullscreen=False`. Once the Archipelago client launches the game, it does this for you and still gives you a full screen: it opens the game windowed at your monitor's size, then takes the border off the window and centers it (see `borderless_window` below). The game cannot open a window wider than 2048 pixels, so on a wider monitor it shows centered at the largest size of the same shape.

### 3. Install Archipelago and the apworld

Install Archipelago using its Windows installer. Default location works (`C:\ProgramData\Archipelago\` on most systems).

Drop `harry_potter_2_pc.apworld` into Archipelago's custom worlds folder:

```
<Archipelago install>\custom_worlds\harry_potter_2_pc.apworld
```

That's it. Archipelago discovers it automatically next time you launch, and `HP2 PC Client` will appear as a button in the Archipelago Launcher.

### 4. The mod: the client installs it for you

There are no mod files to copy by hand. The first time you connect the client to a seed, it pops a folder picker asking for your HP2 install (the folder containing `system\Game.exe`; saved to `host.yaml`, so you are asked only once) and then sets that install up:

- copies the compiled `HPArchipelago.u` (carried inside the apworld) into `<HP2 install>\system\`
- patches `<HP2 install>\system\Default.ini` in place: `DefaultGame=HPArchipelago.APGameInfo` and `Console=HPArchipelago.APConsole` under `[Engine.Engine]`, plus the folder the game and the client share (`ChannelDir=`, under `[HPArchipelago.APIPCActor]`)
- applies the same settings to your per-user `Documents\Harry Potter II\Game.ini` if you launched HP2 before, since that file would otherwise shadow `Default.ini` back to the original game; your own settings (resolution, windowed mode, volume) survive, nothing is deleted
- creates the shared folder `Documents\Harry Potter II\AP\`
- keeps one-time backups of every file it touches, under `<HP2 install>\_archipelago_backup\` and `Documents\Harry Potter II\_archipelago_backup\`

Every later connect re-checks the installed mod against the apworld's copy byte for byte, and the ini settings too, so **updating the randomizer is just replacing the `.apworld` file**: the client updates the game install on the next connect. If the game is running at that moment (the launcher window with New Game / Load Game counts too), the client says so; close it and type `/installmod`. If the install folder refuses the write (almost always a `Program Files` install with the launcher not running as administrator), the client raises a popup with the fix and does not auto-launch. Either way, while an older mod build is still installed, the game repeats an `AP: mod update ...` reminder every ten seconds until the update lands.

> **Permissions:** the client writes inside your install, so if HP2 lives under `Program Files`, run ArchipelagoLauncher as administrator (right-click, "Run as administrator"), or move the install somewhere writable (e.g. `C:\Games\HP2\`). This is the same requirement the audio randomizers have.

> Prefer to manage the files yourself? Set `auto_install_mod: false` under `harry_potter_2_pc_options` in host.yaml; `/installmod` still deploys on demand.

> **Coming from an earlier release?** Earlier releases needed a different setup, which is no longer supported. Install the game fresh from your disc into its own folder (step 1), point the client at that folder, and leave the old install alone or remove it. Saves from that setup do not carry over.

### Open castle

The `open_castle` game mode plays on the same disc install as `vanilla`; there is nothing extra to install. After the flying car, Harry lands in the Entry Hall with every level reachable, gated by the bookcase keys. The mod opens doors and links while the game runs. One change, hiding the vine over the Forbidden Forest gate, lives in the level geometry, so the client patches your own `Maps\Grounds_hub.unr` when you connect to an open castle seed. It keeps a `Grounds_hub.unr.orig` backup and puts the original back when you connect to a `vanilla` seed.

## Generate a seed (solo play)

If you're playing solo (just you, no other AP slots):

1. **Generate the YAML template.** Open ArchipelagoLauncher, click **Generate Template Options**. Once `harry_potter_2_pc.apworld` is in `custom_worlds\`, the launcher writes a fresh `Harry Potter 2 PC.yaml` template into `<Archipelago install>\Players\Templates\`. (If you don't see the yaml, make sure you have the apworld installed and close and re-open the launcher.)
2. **Configure your slot.** Copy that template into `<Archipelago install>\Players\` and edit `name:` to your desired in-game player name. The 8 category toggles control what becomes an AP check:

   | Toggle                         | Default | What it enables                                                                                            |
   | ------------------------------ | ------- | ---------------------------------------------------------------------------------------------------------- |
   | `enable_wizard_cards`          | on      | Card shuffle. The 101 wizard cards are always checks; **on** shuffles the card items into the multiworld pool (tier-prefixed: `Bronze/Silver/Gold Card - X`), **off** locks each card to its own spot (keeps the Gold Card Room's silver gate honest). |
   | `enable_secrets`               | on      | 109 secret-area pickups across all levels (open castle adds 9 in the Gryffindor challenge, 118 total).                                                                 |
   | `enable_challenge_stars`       | on      | 44 challenge stars across the 4 spell-challenge levels (open castle adds 10 in the Gryffindor challenge, 54 total). |
   | `enable_duelling`              | off     | 10 Duelling Club ranked-duel wins.                                                                         |
   | `enable_quidditch_matches`     | off     | 6 Quidditch matches (3 regular + 3 final-tournament).                                                      |
   | `enable_spell_challenge_times` | off     | Beating the replay par time ("Mastered") on each of the 4 spell challenges becomes a check.                |
   | `enable_quidditch_upgrades`    | off     | Buying Nimbus 2001 and Quidditch Armour from Fred & George becomes 2 checks AND the gear enters the pool.  |
   | `containersanity`              | off     | ~283 in-world containers (chests without cards, cauldrons, cigar / jewel / music boxes, decanters, oil cans, plant pots, knights, ingredient jars, statues) each become a check. Opening one with its spell (Alohomora or Flipendo) ejects an AP token; walk over it to send the check. A big check-count increase, so off by default. |

   The 4 spell-tutorial classrooms are always on, since randomized spells are the core experience. `allow_missable_progression` (default off) controls whether progression items may be placed at missable locations in un-replayable levels (missable secrets, plus `containersanity` containers in those levels); safe default keeps those filler-only.

   **Game mode**: one extra setting selects the way through the game:

   ```yaml
   Harry Potter 2 PC:
     game_mode: vanilla # default, the original game; Lumos / Flipendo / Alohomora precollected, other 4 spells in pool
     # game_mode: open_castle   # every level open after the flying car, NO spells precollected, all 7 land as AP items
   ```

   Both modes play on the same install. The client tells the mod which mode the seed uses when it connects; you can confirm open castle kicked in by checking `Game.log` for `entering open castle mode (sticky)`.

   **Open castle goal**: in `open_castle` mode the slot completes by opening the Great Hall, not by the Basilisk fight. Five options set the unlock requirement; they're AND'd together, and any clause left at `0`/off drops out. If all five resolve to `0`/off it falls back to "all 7 spells" so there's always a gate. All five are ignored in vanilla.

   | Option                       | Range  | Default | Great Hall opens once you have…                                          |
   | ---------------------------- | ------ | ------- | ------------------------------------------------------------------------ |
   | `open_castle_goal_cards`     | 0-101  | 50      | that many wizard cards (named anchors: `none`/`few`/`half`/`most`/`all`) |
   | `open_castle_goal_spells`    | 0-7    | 7       | that many spells                                                         |
   | `open_castle_goal_levels`    | 0-13   | 13      | that many of the 13 level objectives finished (incl. the Gold Card Room, which needs 20 silver cards) |
   | `open_castle_goal_duels`     | off/on | off     | won all 10 Duelling Club duels                                           |
   | `open_castle_goal_quidditch` | off/on | off     | won all 6 Quidditch matches                                              |

   **Always Goyle in Slytherin Common Room** (`always_goyle_in_slytherin_common_room`, default on, open castle only): Harry wears the Goyle disguise for the whole Slytherin Common Room, so the Slytherins there never chase him. A Polyjuice Potion Trap has no effect inside the room, and the disguise comes off when you leave the level. Ignored in vanilla.

   **Other options (optional)**: sensible defaults; leave them unless you specifically want the behavior. Both game modes unless noted.

   | Option                | Default                    | What it does                                                                                                                                                                                                                                                                         |
   | --------------------- | -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
   | `starting_spells`     | Flipendo, Lumos, Alohomora | Spells Harry starts with; any spell left off this list becomes an AP item. Vanilla physically needs Lumos + Flipendo to clear the Whomping Willow, so keep both unless they're placed very early. Valid: Alohomora, Flipendo, Lumos, Rictusempra, Skurge, Diffindo, Spongify. |
   | `vanilla_gate_levels` | on                         | **Vanilla only.** On: the 7 story regions are gated by a bookcase until their key arrives. The 5 story levels follow vanilla's linear order, so they are gated by 5 copies of one `Progressive Level Key` item (each copy unlocks the next level in story order); Duelling and Quidditch keep their own named keys. Off: all keys precollected, every region open from the start. No effect in open castle (the 14 named keys are always AP items there).                    |
   | `allow_running_logic` | off                        | Expects Harry's run speed in logic, so checks reachable by running no longer require the spell they'd otherwise need, and the shift-to-run sprint becomes free (no bean cost, usable at 0 beans). `on` adds the `Running` flag: the comfortable runs. `difficult` adds `Difficult Running` on top: the runs needing tight timing or precise positioning, which is the only tier that expects you to run past the Bicorn-gated Castle Exterior checks, into the Forbidden Forest, or onto the Quidditch pitch. Each tier is additive, so raising it never makes a solvable seed unsolvable. Both modes. |
   | `tradersanity`        | off                        | Turns each non-Weasley card/ingredient vendor's first sale into an AP check, after which it reverts to selling normally. The price mode only changes what that check costs: `price_vanilla` a normal in-game price (ingredient vendors keep their real price, card vendors charge a card-like price), `price_random` a random price per vendor fixed for the seed (10-250 beans), `price_low` a flat 10 beans. With `enable_quidditch_upgrades` on, Fred & George also become Tradersanity vendors.                                  |
   | `tradersanity_hint_on_open` | on                   | First time you open dialogue with an unchecked Tradersanity vendor, the AP check at that vendor is broadcast-hinted so the room can see what item it's holding. No effect when `tradersanity` is off.                                                                                |
   | `skip_vendor_voices`  | off                        | Silences every vendor's in-trade voice cues (sell / transaction-done / decline / narrator / Harry-inquiry) so the trade UI advances instantly. The not-enough-beans, out-of-stock, and proximity lure lines are left alone. Mainly useful for Tradersanity runs where the same dialogue repeats.    |
   | `traps`               | all on                     | Set of trap types allowed in your pool (like `starting_spells`, choose any subset; default is all on, empty means none). Traps replace some filler. Options: `Bean Thief Trap` (steals beans), `Polyjuice Potion Trap` (turns Harry into Goyle for the level), `Obliviate Trap` (spellbook withheld ~30s), `Drowsiness Draught Trap` (sleepy slow ~20s), `Engorgio Trap` (giant Harry ~30s), `Reducio Trap` (tiny Harry ~30s), `Confundus Trap` (inverted camera look ~20s), `Overcompensation Trap` (giant wand for the rest of the level), `Levicorpus Trap` (Harry hangs upside down ~30s), `Jelly-Legs Jinx Trap` (jumping hijacked ~20s while Harry jumps at random). The timed traps self-revert on their timer or the next level, whichever comes first; the Overcompensation and Polyjuice traps last the whole level and revert on the next one. `trap_fill_percent` (5-50, default 5) sets how much filler is replaced. |
   | `ring_link`           | off                        | Mirrors organic Bertie Bott's bean changes (in-game pickups + vendor spending) to and from other RingLink slots in the room. AP-granted bean filler and the Bean Thief trap are not mirrored. Compatible with Sonic-style RingLink games.                                            |
   | `trap_link`           | off                        | Standard Archipelago TrapLink: every trap you receive is also sent to all other TrapLink slots, and traps they receive are applied to you. Inbound traps respect your `traps` selection: a trap you turned off is remapped to one you kept. Independent of `traps`, you still receive linked traps with no traps of your own. |
   | `death_link`          | off                        | Standard Archipelago DeathLink: dying sends a death to every other DeathLink slot, and their deaths kill you.                                                                                                                                                                        |
   | `ghost_players`       | on                         | Other Harry Potter 2 players in the room who are on the same map appear in your game as translucent ghosts, moving and animating as they play, and your Harry appears in theirs. Each ghost carries its slot name over its head in a colour of its own, and mirrors the peer's disguise, size, wand and upside-down state. Cosmetic only: a ghost has no collision and cannot be targeted. `/ghosts` toggles it mid-run; off also stops sharing your own position. |

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

The client connects to the AP server as soon as you `/connect` and reads your seed's config. If the server asks for your slot name, type it and press Enter. Leave the client window open; with auto-launch on (the default), the game starts itself next (see below).

### Launch the game

With **auto-launch on** (the default), the client starts `Game.exe` by itself, a moment after you connect (and right after any randomizers finish writing, so the game never boots mid-patch). You don't have to launch anything. Keep the disc in the drive: the disc check takes about half a minute before the main menu appears, so give it time (typing `/play` meanwhile does not start a second copy; the client tells you the game is still starting). Then pick New Game or Load Game. Every connect you make yourself (the Connect button or `/connect`) launches it again if the game is not running (a launcher window left open counts as running) and the mod is current, so closing the game and reconnecting brings it back. A dropped connection that the client repairs by itself never launches the game.

**First connect only:** the client needs to know where your install is, so it pops a folder picker asking for your install (the folder that contains the `system` folder with `Game.exe`). Your choice is saved to `host.yaml`, so you're asked only once. You can also set it ahead of time by editing host.yaml (see the install-path block under Sound randomizer below).

A few seconds after you pick New Game or Load Game you should see in the client log:

```
The Harry Potter 2 game connected to this client. It can now send and receive items.
```

The game window pops a toast top-right when your items arrive ("Received Alohomora from <YourSlotName>" etc). Items are handed over while Harry is walking around, not during cutscenes or the opening of a level, so the first ones may take a moment. You're playing.

**Prefer to launch it yourself?** Set `auto_launch_game: false` under `harry_potter_2_pc_options` in host.yaml, then run `<HP2 install>\system\Game.exe` (or the game's Start Menu shortcut) once the client is connected. The `/play` command in the client launches it too, handy if you closed the game and want it back, or if an auto-launch was skipped. To turn auto-launch off for just this client session, type `/autoplay off` (bare `/autoplay` flips it, `/autoplay on` turns it back on).

### Sound randomizer (optional)

Set `sound_randomizer` in your player yaml to shuffle the sound effects, deterministically per seed (a short sound only ever becomes another short sound). It has three settings:

- `off` (default): sound effects are left alone.
- `on`: every sound effect is shuffled.
- `no_footsteps`: the same, but Harry's footstep sounds are left alone, since randomizing them can get overwhelming.

It needs no mod changes: the client binary-patches `<install>\system\HPSounds.u` when you connect, keeping a one-time `HPSounds.u.orig` backup.

- **Install path (you pick it once).** There is no default. The first time you connect, the client pops a folder picker and asks for your install (the folder that contains `system\HPSounds.u`). Your choice is saved to `host.yaml`, so you are asked only once; both game modes use it. You can also set it ahead of time (or change it later) by editing host.yaml directly:

  ```yaml
  harry_potter_2_pc_options:
    install_folder: "<path to your install>"
    auto_launch_game: true   # default; set false to launch the game yourself
    auto_install_mod: true   # default; set false to manage the mod files yourself
    borderless_window: true  # default; set false to keep the game's normal window
    frame_rate_cap: true     # default; holds the game at 60 fps so it runs at the right speed
    widescreen_view: true    # default; set false for the game's original 4:3 view
  ```

  These are client settings, not seed options: change them any time and they apply the next time the game starts (`widescreen_view` on the next connect).

- **When it applies.** Patching runs a moment after you connect (it rewrites a large file in the background). With auto-launch on (the default), the client finishes patching before it starts the game, so the first launch already has the shuffled sounds and you don't have to time anything. If you launch the game yourself, wait for the client window to show `Sound randomizer applied ...` first (and if the game was already running, restart it once, since the package is read at launch). If you instead see a "could not write / run as administrator" line, see Permissions below.
- **Permissions.** The client patches a file inside your install, so it must be able to write there. If your install is under `Program Files` (the default location for the Harry Potter installation), Windows blocks writes unless the program is elevated, so you **must run ArchipelagoLauncher as administrator** (right-click it, "Run as administrator"). Otherwise the patch fails and the client log says so. Alternatively, use an install in a folder you can write to without elevation.
- **Don't like a swapped sound?** Type `/reroll_sounds` in the client to reshuffle everything with a fresh random set. The new shuffle is remembered for that seed, so it sticks across restarts (restart once to hear it). Run it again if the new set is no better.
- **Revert to the original sounds.** Connect to a seed with the option off (it auto-restores), or type `/restore_sounds` in the client, or manually copy `HPSounds.u.orig` over `HPSounds.u`. Either way, restart the game once to hear the original sounds again.

### Music randomizer (optional)

Set `music_randomizer: true` in your player yaml to shuffle every music track, deterministically per seed (background tracks swap with background tracks, short jingles with jingles). It works the same way as the sound randomizer: the client swaps the `Music\*.ogg` files in your install on connect, keeping a one-time backup. Because it swaps files rather than rewriting triggers, it covers cutscene, menu, and spell-lesson music too.

- **Same install path, permissions, and timing** as the sound randomizer above (it uses the same `install_folder`, picks it once, needs write access / admin under `Program Files`, and takes effect on the next launch).
- **Reshuffle**: `/reroll_music`. **Revert**: `/restore_music`, or connect to a seed with the option off. Restart once to hear the change.

### Dialogue randomizer (optional)

Set `dialogue_randomizer` in your player yaml to shuffle the spoken voice lines, deterministically per seed. It has three settings:

- `off` (default): dialogue is left alone.
- `within_actor`: each character's lines are shuffled among their own, so every character keeps their own voice but says the wrong things.
- `all_actors`: lines are shuffled across every character, so anyone can speak anyone's line.

It works the same way as the sound randomizer: the client binary-patches `<install>\Sounds\AllDialog.uax` (the voices) and the subtitle files `<install>\system\hpdialog.int` and `<install>\system\BumpDialog.int` (the latter holds the student bump lines) on connect, keeping one-time `.orig` backups of each. A game installed in another language uses that language's files instead (for example `AllDialog.DUT_uax`, `HpDialog.dut` and `BumpDialog.dut` on a Dutch disc), and those are the ones patched. All are shuffled with the same permutation, so the caption you read matches the line you hear. A few clips have no subtitle in the game to begin with (Quidditch/duel commentary, ambient mutters, alternate takes); when one of those plays it shows no caption, exactly as in the unmodified game.

- **Same install path, permissions, and timing** as the sound randomizer above (same `install_folder`, picks it once, needs write access / admin under `Program Files`, takes effect on the next launch).
- **Reshuffle**: `/reroll_dialogue` (keeps the seed's mode). **Revert**: `/restore_dialogue`, or connect to a seed with the option off, or manually copy each `.orig` backup (for example `AllDialog.uax.orig`) back over its file. Restart once to hear the change.

### PopTracker map tracker (optional)

A [PopTracker](https://github.com/black-sliver/PopTracker/) pack autotracks your run: items, checks, and goal progress update live over the AP connection, every check shows as a pin on per-floor maps, and the tracker follows Harry to whatever map he's currently in. Both game modes work, and it reads your category toggles from the seed, so it configures itself per seed.

1. Install **PopTracker v0.31.0 or newer**.
2. Download the [HP2 tracker pack](https://github.com/Kryen112/HP2PC_AP_Poptracker/releases/latest) and drop the unzipped folder into PopTracker's `packs/` folder.
3. In PopTracker, click **Load Pack**, pick the Harry Potter 2 PC pack, and choose the variant for your game mode.
4. Click the AP connection button and enter the same server address, slot name, and password you used in the client. The map and checks then update on their own as you play.

## Verify it's working

Quick checklist after first launch:

- **The client says the game connected** ("The Harry Potter 2 game connected to this client") a few seconds after you pick New Game or Load Game.
- **Toasts appear top-right** when items arrive. If not, the mod isn't loaded; see Troubleshooting below.
- **Bookcases block the spell classrooms** you haven't been granted yet. If you can walk straight into Lockhart's DADA classroom and the spell-tutorial cutscene fires immediately, the mod isn't running.
- **Picking up a wizard card** should fire a `CHECK <id>` line in the client log and (if you have any items waiting) hand you something back.
- **Goal (vanilla):** the seed completes when you defeat the Basilisk and the post-Basilisk Great Hall walk-in fires the credits.
- **Goal (open castle):** the Great Hall stays locked until you meet your configured goal clauses (`open_castle_goal_*`); once you do, walking into the Great Hall completes the slot. Type `/progress` in the client at any time to print a per-clause `[x]/[ ] have / need` summary; the in-game pause menu shows the same panel.

## Troubleshooting

**The game does not start, or SafeDisc asks for the disc**:

- Put the original disc in the drive. SafeDisc checks it on every launch.
- Make sure SafeDiscShim is installed ([step 2](#2-install-safediscshim-and-check-the-game-starts)). Without it, Windows 10 and 11 cannot run the disc check at all.
- Windows 11 **Smart App Control** can block SafeDiscShim. If the game still will not start, check Windows Security, App & browser control, Smart App Control.
- SafeDiscShim writes logs next to `<HP2 install>\system\Game.exe` (`Game.exe_SafeDiscShim.log`); attach them if you ask for help.

**The game crashes or goes black when a level starts**:

- Run it windowed: in `Documents\Harry Potter II\Game.ini`, under `[WinDrv.WindowsClient]`, set `StartupFullscreen=False`. When the client launches the game, it still makes the window fill the screen.

**Mod doesn't load** (no toasts, classrooms aren't blocked):

- Make sure you launch the install the client set up: the one saved as `install_folder` under `harry_potter_2_pc_options` in `host.yaml`.
- Close the game, including its main menu window, and type `/installmod` in the connected client (or simply reconnect). It re-deploys the mod and re-wires both inis, and its log lines say exactly what changed. If it reports a permissions error, run ArchipelagoLauncher as administrator.
- Manual checks, if you want to see for yourself: `<HP2 install>\system\HPArchipelago.u` exists; `Documents\Harry Potter II\Game.ini` (if present) has `DefaultGame=HPArchipelago.APGameInfo` and `Console=HPArchipelago.APConsole` under `[Engine.Engine]`, and a `[HPArchipelago.APIPCActor]` section with `ChannelDir=`.
- Read `C:\Users\<you>\Documents\Harry Potter II\Game.log`, search for `[Archipelago]` lines.

**Client says `Default.ini not found; is this a Harry Potter 2 install?`**:

- The folder you pointed the client at is not the game install. It wants the folder that contains `system\Game.exe`. The saved path lives under `harry_potter_2_pc_options` in `host.yaml` if you need to correct it.

**Silent NPCs / no dialog plays in cutscenes**:

- Leave `Language=` under `[Engine.Engine]` in `Default.ini` and `Game.ini` as the disc installed it. It names the language files the game loads (`dut` loads `AllDialog.DUT_uax` and the `.dut` subtitles), so a different value points at files your install does not have.
- If the dialogue randomizer is on, type `/restore_dialogue`, restart the game, and check whether the voices come back. If they do, report it with your `Game.log`.

**"HP2 PC Client" button missing from Archipelago Launcher**:

- The apworld isn't installed where the launcher can see it. Confirm `harry_potter_2_pc.apworld` exists in `<Archipelago install>\custom_worlds\`.
- Close and reopen ArchipelagoLauncher fully; launcher components are discovered on startup, not refreshed live.

**Seed generation can't find the apworld**:

- The `.apworld` file isn't in `<Archipelago install>\custom_worlds\`. Drop it there, restart ArchipelagoLauncher.

**Client disconnects mid-session**:

- The game and the client talk through files in `Documents\Harry Potter II\AP\`, so neither side has to reconnect: restart the client (and reconnect it to the server) while the game keeps running, and the game picks the new client up within a few seconds. Anything the game sent while the client was gone is held and delivered once it is back.
- Items the AP server delivered while the client was down get replayed on reconnect. Every item type (cards, spells, equipment, all bean tiers, every other filler, and traps) is durable across a client crash, reconnect, or game save-load: the client keeps a per-slot consumed-item ledger in Archipelago server storage, so an item already applied is never re-granted (no double beans) and one you haven't received yet still arrives. The only way to lose an item: receive it in-game, then quit **without saving** and reload that older save, where the ledger correctly considers it already delivered, so it won't be handed out again. Save after receiving items, or start a new game on the slot (which re-grants everything).

**Game crashes at level transition**:

- Probably an unrelated engine issue, ask in the [HP2 modding Discord](https://discord.gg/tpN4grB). The randomizer mod doesn't touch level loading.

**A specific card doesn't fire its check when picked up**:

- Open `Game.log` and search for the card's id. If the line `APCardMarker.Touch: firing CHECK <n>` is there but no AP item arrives, the AP server side is the issue.
- If `APCardMarker.Touch` doesn't fire, the marker wasn't placed (check `ReplaceCardChests:` log lines for that level).

**Still stuck?** Feel free to contact Kryen in the Archipelago Discord.

## Logs

For bug reports, attach these:

| What          | Where                                                                                                          |
| ------------- | -------------------------------------------------------------------------------------------------------------- |
| Game-side log | `C:\Users\<you>\Documents\Harry Potter II\Game.log`                                                            |
| SafeDiscShim  | `<HP2 install>\system\Game.exe_SafeDiscShim.log` (only when the game will not start)                           |
| Client log    | Scroll the **Archipelago** tab of the HP2 PC Client window, or check `<Archipelago install>\logs\`             |
| AP server log | `<Archipelago install>\logs\`                                                                                  |

The game-to-client link folder is `Documents\Harry Potter II\AP\`. It only holds short-lived message files; nothing in it needs backing up.

## Where to ask for help

- [HP2 modding Discord](https://discord.gg/tpN4grB) for game-specific issues.
- Archipelago Discord, `#future-game-design`. Feel free to contact Kryen there.
- GitHub issues at this project's repo.
