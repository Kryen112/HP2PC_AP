# HP2PC_AP — Harry Potter and the Chamber of Secrets PC Archipelago Randomizer

An Archipelago multiworld randomizer for *Harry Potter and the Chamber of Secrets* (PC, 2002 EA / KnowWonder release).

**Status:** pre-alpha, end-to-end playable. M0–M7 done. M8 (UX polish) underway — all four bookcase challenge blocks (Rictusempra / Skurge / Diffindo / Spongify) are implemented and verified. The v1 source-data model is 108 items / 105 checks: 7 spells (3 starter precollected) + 101 wizard cards, placed across 4 classrooms + 101 card pickups. Boomslang / Bicorn / BitOGoyle were dropped from AP for v1 and flow through vanilla story progression. Goal mechanic verified 2026-05-11 — post-Basilisk Great-Hall walk-in + credits cutscene releases items and marks the slot complete. See `docs/ROADMAP.md` for milestone status, `readme-handoff.md` for end-of-session context, and `docs/DESIGN.md#open-questions-to-resolve-in-playtest` for active blockers.

## Architecture (one-liner)

```
[HP2 game on M212 engine]
  └─ HPArchipelago.u  (UnrealScript mod, hooks pickups + spells + boss)
       └─ class'IpDrv.TcpLink' ──► localhost:38281
                                       │
                                       ▼
                          [Python sidecar (hp2_client.py)]
                                       │
                                       ▼ WebSocket
                            [archipelago.gg server]
```

No C++. No memory hooking. All game-side logic is UnrealScript on Metallicafan212's modder engine (which restored UE1 networking from UT99). The `data/*.yaml` files are the source of truth for items, locations, and access logic; Python is generated from them.

## Repo layout

| Path | Purpose |
| --- | --- |
| `apworld/` | Python AP world definition (compiles to `harry_potter_2_pc.apworld`) |
| `client/` | Python sidecar bridging UScript ↔ AP server |
| `mod/HPArchipelago/Classes/` | UnrealScript mod source, compiled with `ucc make` |
| `data/items.yaml` | Item catalog — user-authored source of truth |
| `data/locations.yaml` | Location catalog — user-authored source of truth |
| `data/logic.yaml` | Per-location access rules — user-authored source of truth |
| `scripts/gen_apworld.py` | Generates `apworld/*.py` from `data/*.yaml` |
| `docs/DESIGN.md` | Design decisions, with v2 parking lot |
| `docs/ROADMAP.md` | Milestone plan |
| `docs/AGENTS.md` | Proposed Claude Code subagents/skills |
| `docs/MOD_TODO.md` | Running list of UScript mod implementation tasks |

## Read this first

- **`docs/PLAYER_SETUP.md`** — install + first-run guide for end users (skip if you're modifying the mod itself).
- **`docs/DEV_SETUP.md`** — dev environment + UScript build loop.
- **`docs/DESIGN.md`** — every architectural decision and why.
- **`docs/ROADMAP.md`** — what to build and in what order.
- **`docs/MOD_TODO.md`** — what the UScript mod has to do.
- **`readme-handoff.md`** — most recent handoff for the next Claude session; read this top-to-bottom before doing anything else.

## v1 scope (locked)

- **Item shuffle** (no entrance shuffle).
- **Open hub** start; all level doors unlocked from spawn; player can enter any level.
- **108 unique non-filler items:** 7 spells + 101 wizard cards. Lumos/Flipendo/Alohomora are mandatory precollected starters, leaving 105 items to place.
- **105 checks**: 4 spell-tutorial classrooms + 101 card pickups.
- **Boomslang / Bicorn / BitOGoyle** are NOT AP items in v1; they're delivered by vanilla story progression and re-instated as AP checks in v2 once the mod-side trigger work lands (see `docs/MOD_TODO.md`).
- **Goal:** defeat Basilisk. Detected via `FEBook.bInEndGame` flipping when the post-Basilisk credits cutscene starts (verified working 2026-05-11).
- **Sphere 0:** 4 spell-teaching classrooms (no items required to reach in the open-hub model).
- **Filler:** beans (3 tiers — small/medium/large).
- **Placement constraint:** gold-card chest locations cannot hold silver-card items (would create a 40-silvers-to-unlock-gold-chest circular dependency).
- **Distribution v1:** manual zip release (apworld + mod + Python client).
