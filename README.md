# HP2PC_AP - Harry Potter and the Chamber of Secrets PC Archipelago Randomizer

An Archipelago multiworld randomizer for _Harry Potter and the Chamber of Secrets_ (PC, 2002 EA / KnowWonder release).

Complete and playable end to end. Up to **~579 checks** across 10 categories: 4 spell-tutorial classrooms, 101 wizard cards (50 Bronze / 40 Silver / 11 Gold), 109 secret areas, 44 challenge stars, 10 ranked duels, 6 Quidditch matches, 4 spell-challenge par times, 2 Fred & George vendor purchases (Nimbus 2001 + Quidditch Armour), ~283 containersanity containers, and up to 13 Tradersanity vendor checks, gated per-category by yaml toggles. Item pool: 7 spells (vanilla precollects Lumos/Flipendo/Alohomora; open castle precollects none), 101 tier-prefixed cards, 2 equipment items, and 8 filler types. Two game modes via `game_mode`: `vanilla` (retail + M212 story flow) and `open_castle` (HP2 Bingo distribution, every level open from spawn). Goal: in vanilla, the post-Basilisk Great-Hall walk-in fires the credits cutscene which marks the slot complete; in open castle, opening the Great Hall via the configurable `open_castle_goal_*` clauses. Boomslang / Bicorn / BitOGoyle still flow through vanilla story progression.

## Architecture (one-liner)

```
[HP2 game on M212 engine]
  └─ HPArchipelago.u  (UnrealScript mod, hooks pickups + spells + boss)
       └─ class'IpDrv.TcpLink' ──► localhost:42779
                                       │
                                       ▼
                          [HP2 PC Client, launched from
                           Archipelago launcher, bundled
                           inside harry_potter_2_pc.apworld]
                                       │
                                       ▼ WebSocket
                            [archipelago.gg server]
```

No C++. No memory hooking. All game-side logic is UnrealScript on Metallicafan212's modder engine (which restored UE1 networking from UT99). The `apworld/*.py` files are the source of truth for items, locations, regions, and access logic; `build_apworld.py` packages them into `harry_potter_2_pc.apworld` with no code-generation step.

## Repo layout

| Path                         | Purpose                                                                                    |
| ---------------------------- | ------------------------------------------------------------------------------------------ |
| `apworld/`                   | Python AP world definition + bundled `Client.py` (packaged into `harry_potter_2_pc.apworld`) |
| `apworld/{items,locations}.py` | Item / location id tables, groups, and classifications                                     |
| `apworld/{regions,rules}.py`, `apworld/access.py` | Access logic as boolean predicates over item names                          |
| `build_apworld.py`           | Packages the apworld into `harry_potter_2_pc.apworld` and installs it locally (no code generation) |
| `mod/HPArchipelago/Classes/` | UnrealScript mod source, compiled with `ucc make`                                          || `docs/PLAYER_SETUP.md`       | Install + first-run guide for end users                                                    |
| `docs/DEV_SETUP.md`          | Dev environment + UScript build loop                                                       |

## Read this first

- **`docs/PLAYER_SETUP.md`**: install + first-run guide for end users (skip if you're modifying the mod itself).
- **`docs/DEV_SETUP.md`**: dev environment + UScript build loop.

## Features

- **Item shuffle** (no entrance shuffle).
- **Two game modes** via `game_mode`: `vanilla` (retail + M212; linear story flow, open hub once keys are collected) and `open_castle` (HP2 Bingo distribution; every level open from spawn, no spells precollected). The mod auto-detects the HP2 Bingo install at runtime; the apworld selects mode from the yaml.
- **Open hub** start; all level doors unlocked from spawn; player can enter any level.
- **Non-filler items:** 7 spells + 101 wizard cards + (optional) 2 equipment items (Nimbus 2001 / Quidditch Armour). The `starting_spells` yaml option (default Flipendo/Lumos/Alohomora) picks which spells are precollected starters; any spell not listed enters the AP item pool. Cards are AP item names prefixed by tier (e.g. `Silver Card - Duke`).
- **Locations** (~579 max with all toggles on): 4 spell-tutorial classrooms + 101 wizard cards + 109 secret areas + 44 challenge stars + 10 ranked duels (Duelling Club) + 6 Quidditch matches + 4 spell-challenge par times + 2 Weasley-twin vendor purchases + ~283 containersanity containers + up to 13 Tradersanity vendor checks.
- **Per-category yaml toggles:** `enable_wizard_cards` (default on), `enable_secrets` (on), `enable_challenge_stars` (on), `enable_duelling` (off), `enable_quidditch_matches` (off), `enable_spell_challenge_times` (off), `enable_quidditch_upgrades` (off), `containersanity` (off). The 4 spell-tutorial classrooms are always on, spells aren't optional. With every toggle off the seed has only the 4 classrooms + 4 non-starter spells.
- **Other options:** `starting_spells` (which spells are precollected), `vanilla_gate_levels` (vanilla bookcase key-gating, default on; the 5 story levels are gated by 5 copies of one `Progressive Level Key`, Duelling and Quidditch by their own named keys), `allow_missable_progression` (logic-relaxation flag, default off), `allow_running_logic` (`off` / `on` / `difficult`, default off; `difficult` also expects the tight-timing runs), the open-castle goal clauses `open_castle_goal_cards` / `_spells` / `_levels` / `_duels` / `_quidditch`, `tradersanity` / `tradersanity_hint_on_open` / `skip_vendor_voices`, `traps` (per-type set, default all on) / `trap_fill_percent`, `sound_randomizer` / `music_randomizer` / `dialogue_randomizer`, `ring_link`, `trap_link`, and standard `death_link`. Full descriptions and defaults in [`docs/PLAYER_SETUP.md`](docs/PLAYER_SETUP.md).
- **Boomslang / Bicorn / BitOGoyle** are NOT AP items; they're delivered by vanilla story progression.
- **Goal:** vanilla, defeat Basilisk, detected via `FEBook.bInEndGame` flipping when the post-Basilisk credits cutscene starts. Open castle, open the Great Hall by satisfying the AND'd `open_castle_goal_*` clauses (cards / spells / level objectives / duels / Quidditch).
- **Sphere 0:** 4 spell-teaching classrooms (no items required to reach in the open-hub model).
- **Filler:** 8 types: Small/Medium/Large/Massive Jar of Beans, Wiggenweld Potion, Wiggentree Bark, Flobberworm Mucous, Chocolate Frog.
- **Gold Card Room:** the 11 gold cards live in their own region behind the silver-key door. Logic gates each gold-card location on the silver-card count plus the per-card spell requirements: vanilla requires all 40 silvers (matches the boss-of-house gate); open castle requires 20 silvers (matches the in-game `CardLockTrigger` which only wires Lock1+Lock2). Silver-card items cannot land in gold-card locations. The room's far-end exit trigger is also a **Gold Card Room - Complete** check, the 13th open-castle level objective (`open_castle_goal_levels`); it needs the same access as the deepest gold card. When card shuffle is off the cards are locked to their own spots rather than removed, so this silver gate stays honest.
- **Distribution:** single `harry_potter_2_pc.apworld` (client bundled) + the UScript mod. The launcher shows "HP2 PC Client" once the apworld is dropped into the user's `custom_worlds/` folder.
