# HP2PC_AP - Harry Potter and the Chamber of Secrets PC Archipelago Randomizer

An Archipelago multiworld randomizer for _Harry Potter and the Chamber of Secrets_ (PC, 2002 EA / KnowWonder release).

**Status:** v2 - end-to-end playable. Up to **276 checks** across 7 categories: 4 spell-tutorial classrooms, 101 wizard cards (50 Bronze / 40 Silver / 11 Gold), 109 secret areas, 44 challenge stars, 10 ranked duels, 6 Quidditch matches, 2 Fred & George vendor purchases (Nimbus 2001 + Quidditch Armour), gated per-category by yaml toggles. Item pool: 7 spells (Lumos/Flipendo/Alohomora precollected), 101 tier-prefixed cards, 2 equipment items, and 8 filler types. Goal: post-Basilisk Great-Hall walk-in fires the credits cutscene which marks the slot complete. Boomslang / Bicorn / BitOGoyle still flow through vanilla story progression.

## Architecture (one-liner)

```
[HP2 game on M212 engine]
  └─ HPArchipelago.u  (UnrealScript mod, hooks pickups + spells + boss)
       └─ class'IpDrv.TcpLink' ──► localhost:38281
                                       │
                                       ▼
                          [HP2 PC Client, launched from
                           Archipelago launcher, bundled
                           inside harry_potter_2_pc.apworld]
                                       │
                                       ▼ WebSocket
                            [archipelago.gg server]
```

No C++. No memory hooking. All game-side logic is UnrealScript on Metallicafan212's modder engine (which restored UE1 networking from UT99). The `data/*.yaml` files are the source of truth for items, locations, and access logic; the `apworld/*.py` next to them is auto-generated.

## Repo layout

| Path                         | Purpose                                                                                    |
| ---------------------------- | ------------------------------------------------------------------------------------------ |
| `apworld/`                   | Python AP world definition + bundled `Client.py` (compiles to `harry_potter_2_pc.apworld`) |
| `mod/HPArchipelago/Classes/` | UnrealScript mod source, compiled with `ucc make`                                          |
| `data/items.yaml`            | Item catalog, user-authored source of truth                                                |
| `data/locations.yaml`        | Location catalog, user-authored source of truth                                            |
| `data/logic.yaml`            | Per-location access rules, user-authored source of truth                                   |
| `../DESIGN.md`               | Design decisions, with v1.1 parking lot                                                    |
| `docs/PLAYER_SETUP.md`       | Install + first-run guide for end users                                                    |
| `docs/DEV_SETUP.md`          | Dev environment + UScript build loop                                                       |

## Read this first

- **`docs/PLAYER_SETUP.md`**: install + first-run guide for end users (skip if you're modifying the mod itself).
- **`docs/DEV_SETUP.md`**: dev environment + UScript build loop.
- **`../DESIGN.md`**: every architectural decision and why.

## v1.1 scope

- **Item shuffle** (no entrance shuffle).
- **Open hub** start; all level doors unlocked from spawn; player can enter any level.
- **Non-filler items:** 7 spells + 101 wizard cards + (optional) 2 equipment items (Nimbus 2001 / Quidditch Armour). Lumos/Flipendo/Alohomora are mandatory precollected starters; cards are AP item names prefixed by tier (e.g. `Silver Card - Duke`).
- **Locations** (280 max with all toggles on): 4 spell-tutorial classrooms + 101 wizard cards + 109 secret areas + 44 challenge stars + 10 ranked duels (Duelling Club) + 6 Quidditch matches + 4 spell-challenge par times + 2 Weasley-twin vendor purchases.
- **Per-category yaml toggles:** `enable_wizard_cards` (default on), `enable_secrets` (on), `enable_challenge_stars` (on), `enable_duelling` (off), `enable_quidditch_matches` (off), `enable_spell_challenge_times` (off), `enable_quidditch_upgrades` (off). The 4 spell-tutorial classrooms are always on, spells aren't optional. With every toggle off the seed has only the 4 classrooms + 4 non-starter spells.
- **Boomslang / Bicorn / BitOGoyle** are NOT AP items; they're delivered by vanilla story progression.
- **Goal:** defeat Basilisk. Detected via `FEBook.bInEndGame` flipping when the post-Basilisk credits cutscene starts.
- **Sphere 0:** 4 spell-teaching classrooms (no items required to reach in the open-hub model).
- **Filler:** 8 types: Small/Medium/Large/Massive Pile of Beans, Wiggenweld Potion, Wiggentree Bark, Flobberworm Mucous, Chocolate Frog.
- **Gold Card Room:** the 11 gold cards live in their own region behind the 4-silver-key door. Logic gates each gold-card location on "have all 40 silvers" plus the per-card spell requirements; silver-card items cannot land in gold-card locations.
- **Distribution:** single `harry_potter_2_pc.apworld` (client bundled) + the UScript mod. The launcher shows "HP2 PC Client" once the apworld is dropped into the user's `custom_worlds/` folder.
