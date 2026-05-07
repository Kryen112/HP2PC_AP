# HP2PC_AP — Harry Potter and the Chamber of Secrets PC Archipelago Randomizer

An Archipelago multiworld randomizer for *Harry Potter and the Chamber of Secrets* (PC, 2002 EA / KnowWonder release).

**Status:** pre-alpha, design phase. Nothing playable yet.

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
| `apworld/` | Python AP world definition (compiles to `harry_potter_2.apworld`) |
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

- **`docs/DESIGN.md`** — every architectural decision and why.
- **`docs/ROADMAP.md`** — what to build and in what order.
- **`docs/MOD_TODO.md`** — what the UScript mod has to do.
- **`readme-may-7th.md`** — handoff doc from 2026-05-06; safe to delete after first re-resume.

## v1 scope (locked)

- **Item shuffle** (no entrance shuffle).
- **Open hub** start; all level doors unlocked from spawn; player can enter any level.
- **111 items** in pool: 7 spells + 101 wizard cards + Boomslang + Bicorn + BitOGoyle.
- **~117+ locations**: 4 spell-tutorial classrooms + 12 level completions + 101 card pickups + small extras to be enumerated.
- **Goal:** defeat Basilisk.
- **Sphere 0:** 4 spell-teaching classrooms (no items required to reach).
- **Filler:** beans (3 tiers — small/medium/large).
- **Distribution v1:** manual zip release (apworld + mod + Python client).
