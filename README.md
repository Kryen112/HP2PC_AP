# HP2PC_AP — Harry Potter and the Chamber of Secrets PC Archipelago Randomizer

An Archipelago multiworld randomizer for *Harry Potter and the Chamber of Secrets* (PC, 2002 EA / KnowWonder release).

**Status:** v1.0 — end-to-end playable. 108 items / 105 checks: 7 spells (3 starter precollected) + 101 wizard cards, placed across 4 classrooms + 101 card pickups. Boomslang / Bicorn / BitOGoyle flow through vanilla story progression (will return as AP items in v2). Goal: post-Basilisk Great-Hall walk-in fires the credits cutscene which marks the slot complete.

## Architecture (one-liner)

```
[HP2 game on M212 engine]
  └─ HPArchipelago.u  (UnrealScript mod, hooks pickups + spells + boss)
       └─ class'IpDrv.TcpLink' ──► localhost:38281
                                       │
                                       ▼
                          [HP2 PC Client — launched from
                           Archipelago launcher, bundled
                           inside harry_potter_2_pc.apworld]
                                       │
                                       ▼ WebSocket
                            [archipelago.gg server]
```

No C++. No memory hooking. All game-side logic is UnrealScript on Metallicafan212's modder engine (which restored UE1 networking from UT99). The `data/*.yaml` files are the source of truth for items, locations, and access logic; the `apworld/*.py` next to them is auto-generated.

## Repo layout

| Path | Purpose |
| --- | --- |
| `apworld/` | Python AP world definition + bundled `Client.py` (compiles to `harry_potter_2_pc.apworld`) |
| `mod/HPArchipelago/Classes/` | UnrealScript mod source, compiled with `ucc make` |
| `data/items.yaml` | Item catalog — user-authored source of truth |
| `data/locations.yaml` | Location catalog — user-authored source of truth |
| `data/logic.yaml` | Per-location access rules — user-authored source of truth |
| `../DESIGN.md` | Design decisions, with v2 parking lot |
| `docs/PLAYER_SETUP.md` | Install + first-run guide for end users |
| `docs/DEV_SETUP.md` | Dev environment + UScript build loop |

## Read this first

- **`docs/PLAYER_SETUP.md`** — install + first-run guide for end users (skip if you're modifying the mod itself).
- **`docs/DEV_SETUP.md`** — dev environment + UScript build loop.
- **`../DESIGN.md`** — every architectural decision and why.

## v1 scope (locked)

- **Item shuffle** (no entrance shuffle).
- **Open hub** start; all level doors unlocked from spawn; player can enter any level.
- **108 unique non-filler items:** 7 spells + 101 wizard cards. Lumos/Flipendo/Alohomora are mandatory precollected starters, leaving 105 items to place.
- **105 checks**: 4 spell-tutorial classrooms + 101 card pickups.
- **Boomslang / Bicorn / BitOGoyle** are NOT AP items in v1; they're delivered by vanilla story progression and re-instated as AP checks in v2 once the mod-side trigger work lands.
- **Goal:** defeat Basilisk. Detected via `FEBook.bInEndGame` flipping when the post-Basilisk credits cutscene starts (verified working 2026-05-11).
- **Sphere 0:** 4 spell-teaching classrooms (no items required to reach in the open-hub model).
- **Filler:** beans (3 tiers — small/medium/large).
- **Placement constraint:** gold-card chest locations cannot hold silver-card items (would create a 40-silvers-to-unlock-gold-chest circular dependency).
- **Distribution v1:** single `harry_potter_2_pc.apworld` (client bundled) + the UScript mod. The launcher shows "HP2 PC Client" once the apworld is dropped into the user's `custom_worlds/` folder.
