# HP2PC_AP - Harry Potter and the Chamber of Secrets PC Archipelago Randomizer

An Archipelago multiworld randomizer for _Harry Potter and the Chamber of Secrets_ (PC, 2002 EA / KnowWonder release).

Complete and playable end to end, in two game modes on the same install: `vanilla` (the original story flow) and `open_castle` (every level reachable from the Entry Hall after the flying car). With every category on, a seed has **560 checks in vanilla and 601 in open castle**: 101 wizard cards (50 Bronze / 40 Silver / 11 Gold), 109 secret areas (118 in open castle), 44 challenge stars (54), 12 level completions (13, including the Gold Card Room), 4 spell-tutorial classrooms (vanilla only), 10 ranked duels, 6 Quidditch matches, 4 spell-challenge par times, 2 Fred & George purchases, 255 containers (280), and 13 Tradersanity vendors. The smallest seed has 117 checks in vanilla and 114 in open castle. Goal: in vanilla, defeat the Basilisk; in open castle, open the Great Hall by meeting the configurable `open_castle_goal_*` clauses.

## Requirements

> [!IMPORTANT]
> This randomizer runs on **the original game, installed from your own disc**, with **SafeDiscShim** so the disc's copy protection works on modern Windows. Keep the disc in the drive while you play. Nothing in this project patches the game executable or bypasses its copy protection, and it ships no game files.

| Thing | Notes |
| --- | --- |
| **Harry Potter and the Chamber of Secrets (PC)** | Your own disc, KnowWonder 2002 build, installed from that disc. **Not included.** The disc must be in the drive whenever you play. |
| **SafeDiscShim** | Free, open source: <https://github.com/RibShark/SafeDiscShim/releases>. Windows 10 and 11 no longer ship the driver the disc's SafeDisc protection talks to; SafeDiscShim answers it instead, so the game starts. It does not remove the protection: the original disc is still required. |
| **Archipelago** | <https://github.com/ArchipelagoMW/Archipelago/releases>, latest stable Windows installer. |
| **HP2PC_AP** | `harry_potter_2_pc.apworld` from this repo's releases. Carries the client and the compiled mod. |

**Platforms:** Windows 10 or 11. **Linux is experimental**: the client finds the game's Wine or Proton prefix by itself, but nobody has confirmed yet that the disc check passes under Wine. See [`docs/PLAYER_SETUP.md`](docs/PLAYER_SETUP.md#linux-experimental).

**Open castle** (`game_mode: open_castle`) plays on the same disc install. The mod opens the castle while the game runs, and the client hides one piece of level geometry by patching your own map file, keeping a backup. No game files ship with this project.

Step-by-step walkthrough in [`docs/PLAYER_SETUP.md`](docs/PLAYER_SETUP.md).

## Architecture (one-liner)

```
[HP2 from your disc + SafeDiscShim]
  └─ HPArchipelago.u  (UnrealScript mod, hooks pickups + spells + boss)
       └─ files in Documents\Harry Potter II\AP\
            game → client: out_*.log batches
            client → game: in.txt, run by the game's `exec` each tick
                                       │
                                       ▼
                          [HP2 PC Client, launched from
                           Archipelago launcher, bundled
                           inside harry_potter_2_pc.apworld]
                                       │
                                       ▼ WebSocket
                            [archipelago.gg server]
```

No C++. No memory hooking. All game-side logic is UnrealScript compiled for the game's own engine, which has no networking, so the game and the client exchange small text files in a shared folder (see `apworld/game_link.py`). The `apworld/*.py` files are the source of truth for items, locations, regions, and access logic; `build_apworld.py` packages them into `harry_potter_2_pc.apworld` with no code-generation step.

## Repo layout

| Path                         | Purpose                                                                                    |
| ---------------------------- | ------------------------------------------------------------------------------------------ |
| `apworld/`                   | Python AP world definition + bundled `Client.py` (packaged into `harry_potter_2_pc.apworld`) |
| `apworld/{items,locations}.py` | Item / location id tables, groups, and classifications                                     |
| `apworld/{regions,rules}.py`, `apworld/access.py` | Access logic as boolean predicates over item names                          |
| `build_apworld.py`           | Verifies + stages the compiled mod, packages the apworld into `harry_potter_2_pc.apworld`, and installs it locally (no code generation) |
| `mod/HPArchipelago/Classes/` | UnrealScript mod source, compiled with `ucc make`                                          |
| `mod/Compiled/`              | The canonical compiled `HPArchipelago.u` + its source-hash manifest (recorded by `scripts/capture_mod.py`, shipped inside the apworld) |
| `apworld/installer.py`       | Client-side mod installer: deploys the packaged `.u` and patches the game inis in place    |
| `docs/PLAYER_SETUP.md`       | Install + first-run guide for end users                                                    |
| `docs/DEV_SETUP.md`          | Dev environment + UScript build loop                                                       |

## Read this first

- **[Requirements](#requirements) above**: the game disc and SafeDiscShim. Get the game starting from the disc before anything else.
- **`docs/PLAYER_SETUP.md`**: install + first-run guide for end users (skip if you're modifying the mod itself).
- **`docs/DEV_SETUP.md`**: dev environment + UScript build loop.

## Features

- **Item shuffle** (no entrance shuffle).
- **Two game modes** via `game_mode`: `vanilla` (the story flow, with the story levels behind bookcases until their keys arrive when `vanilla_gate_levels` is on) and `open_castle` (every level reachable from the Entry Hall after the flying car, each level transition behind one of 14 named bookcase keys). Both play on the same install; the client tells the mod which mode the seed uses.
- **Items:** 7 spells, 101 wizard cards (tier-prefixed, e.g. `Silver Card - Duke`), the bookcase keys (vanilla: 5 copies of `Progressive Level Key` plus the Duelling and Quidditch keys; open castle: 14 named keys), optionally Nimbus 2001 and Quidditch Armour, 11 filler types, and 10 trap types. `starting_spells` (default Lumos, Flipendo, Alohomora, in both modes) picks the spells Harry starts with; the rest are AP items.
- **Locations** (560 vanilla / 601 open castle with everything on): see the counts above. Wizard cards and level completions are always checks; vanilla also always has the 4 spell-tutorial classrooms.
- **Per-category yaml toggles:** `enable_wizard_cards` (default on; on shuffles the card items, off keeps each card in its own spot), `enable_secrets` (on), `enable_challenge_stars` (on), `enable_duelling` (off), `enable_quidditch_matches` (off), `enable_spell_challenge_times` (off), `enable_quidditch_upgrades` (off), `containersanity` (off), `tradersanity` (off).
- **Other options:** `starting_spells` (which spells are precollected), `vanilla_gate_levels` (vanilla bookcase key-gating, default on; the 5 story levels are gated by 5 copies of one `Progressive Level Key`, Duelling and Quidditch by their own named keys), `allow_missable_progression` (logic-relaxation flag, default off), `allow_running_logic` (`off` / `on` / `difficult`, default off; `difficult` also expects the tight-timing runs), the open-castle goal clauses `open_castle_goal_cards` / `_spells` / `_levels` / `_duels` / `_quidditch`, `always_goyle_in_slytherin_common_room` (open castle only, default on), `tradersanity` / `tradersanity_hint_on_open` / `skip_vendor_voices`, `traps` (per-type set, default all on) / `trap_fill_percent`, `sound_randomizer` / `music_randomizer` / `dialogue_randomizer`, `ring_link`, `trap_link`, `ghost_players` (see the other HP2 players as ghosts, default on), and standard `death_link`. Full descriptions and defaults in [`docs/PLAYER_SETUP.md`](docs/PLAYER_SETUP.md).
- **Boomslang / Bicorn / BitOGoyle** are NOT AP items; they're delivered by vanilla story progression.
- **Goal:** vanilla, defeat Basilisk, detected via `FEBook.bInEndGame` flipping when the post-Basilisk credits cutscene starts. Open castle, open the Great Hall by satisfying the AND'd `open_castle_goal_*` clauses (cards / spells / level objectives / duels / Quidditch).
- **Filler:** 11 types: 1 Bean, 5 Beans, 10 Beans, Small/Medium/Large/Massive Jar of Beans, Wiggenweld Potion, Wiggentree Bark, Flobberworm Mucous, Chocolate Frog.
- **Traps** (`traps`, `trap_fill_percent`): Bean Thief, Polyjuice Potion, Obliviate, Drowsiness Draught, Engorgio, Reducio, Confundus, Overcompensation, Levicorpus, Jelly-Legs Jinx.
- **Gold Card Room:** the 11 gold cards live in their own region behind the silver-key door. Logic gates each gold-card location on the silver-card count plus the per-card spell requirements: vanilla requires all 40 silvers (matches the boss-of-house gate); open castle requires 20 silvers (matches the in-game `CardLockTrigger` which only wires Lock1+Lock2). Silver-card items cannot land in gold-card locations. The room's far-end exit trigger is also a **Gold Card Room - Complete** check, the 13th open-castle level objective (`open_castle_goal_levels`); it needs the same access as the deepest gold card. When card shuffle is off the cards are locked to their own spots rather than removed, so this silver gate stays honest.
- **Distribution:** a single `harry_potter_2_pc.apworld` carrying the client and the compiled UScript mod, deployed into the player's own install (see [Requirements](#requirements)). The launcher shows "HP2 PC Client" once the apworld is dropped into the user's `custom_worlds/` folder, and the client installs (and keeps updated) the mod and its ini wiring in the game install on connect. SafeDiscShim is a separate one-time install the player does by hand.

## Display

Three client settings in `host.yaml`, all on by default and changeable at any time (they are not seed options):

- `borderless_window`: before launch the client sets the game's window to the monitor's size (at most 2048 pixels wide, keeping the monitor's shape), then hides the window frame and centers it. The window is never resized while the game runs, because the game's renderer does not survive that.
- `frame_rate_cap`: holds the game at 60 frames per second, the speed its physics and timers are tuned for. The client changes one instruction in the install's `Engine.dll` and keeps `Engine.dll.orig`; turning the setting off puts the original back.
- `widescreen_view`: the mod widens the field of view on wide screens instead of cropping, and centers the 4:3 menus with black bars at the sides.

The installer also turns off the renderer's texture precache (`UsePrecache=False`), which otherwise draws see-through textures (torch cages, fences, Harry's glasses) solid.

## No game files ship

This project contains no part of the game. The player installs the game from their own disc.

- **The mod** (`HPArchipelago.u`) is UnrealScript written for this project, compiled against the player's own game packages. It refers to the game's classes, meshes, sounds and textures by name and loads them from the player's install at runtime; it contains no copy of them.
- **The mod's own art** is made by this project, never extracted from the game: the Archipelago logo coin and its textures (from the Archipelago logo, `tools/APLogoSource.svg`), the trade-token slab (a plain box), the giant wand for the Overcompensation Trap (drawn by `tools/gen_wand_mesh.py`), and the ghost players' glasses texture (drawn by `tools/gen_ghost_glasses.py`).
- **Changes to the player's install** are made on the player's machine, to the player's own files, with a backup kept: the ini wiring, the 60 fps edit to `Engine.dll`, the open castle map edit to `Maps\Grounds_hub.unr`, and the optional sound, music and dialogue shuffles (which reorder the player's own files and never add any).
- **The executable** is never touched, and the disc's copy protection is never bypassed: SafeDiscShim, a separate open-source project, only answers the driver call modern Windows no longer does, and the disc is still required.
