# Resume — May 7th, 2026

This file is for the version of Claude that picks up tomorrow on a fresh PC with a fresh checkout. Read it top-to-bottom before doing anything else. Then delete it (or leave it as a session log — the user picks).

---

## Context for fresh Claude

We are building **HP2PC_AP**, an Archipelago multiworld randomizer for *Harry Potter and the Chamber of Secrets* (PC, 2002 EA / KnowWonder release). The user is **Stefan Kuppen** (`stefan.kuppen@indi.nl`). They have:

- **Solid AP Python knowledge** (have written/contributed to AP randomizers before)
- **Zero UnrealScript experience**
- **Zero C/C++ / reverse-engineering experience**

The architecture intentionally avoids native code so the user can do all the modding in UnrealScript on Metallicafan212's HP2 modder engine (which has UT99-restored networking — `IpDrv.dll` / `TcpLink` is available, confirmed on 2026-05-06 via the HP modding Discord).

## What exists in this repo right now

This repo is the output of a long design-grilling session with the user. **No code has been written yet.** What's here:

- `README.md` — top-level overview of the project.
- `docs/DESIGN.md` — every architectural decision, rationale, and the v2 parking lot.
- `docs/ROADMAP.md` — milestone plan M0–M8.
- `docs/AGENTS.md` — proposed Claude Code subagents/skills, to be scaffolded during M1–M2.
- `docs/MOD_TODO.md` — UScript implementation checklist.
- `data/items.yaml` — 111 items catalogued (7 spells, 101 cards by class+tier+name, 3 key items, 3 filler bean tiers).
- `data/locations.yaml` — ~117 locations skeleton (4 classrooms, 12 level completions, 101 cards). Most regions = `TBD`; user fills in during playtest.
- `data/logic.yaml` — region entry rules (rough), location rule scaffolding, goal definition.
- `.gitignore` — Python + UScript build artifacts excluded.

## Read these in order

1. `README.md` (1 min)
2. `docs/DESIGN.md` (5 min — every locked decision lives here)
3. `docs/ROADMAP.md` (2 min — what's next)
4. `docs/MOD_TODO.md` (2 min — what the mod has to do)
5. `docs/AGENTS.md` (skim — only relevant when you reach M2)

The DESIGN doc has a **v2 parking lot** at the bottom. Anything not in v1 lives there. If the user proposes a feature mid-conversation that's already parked, gently redirect to v1.

## Recommended next actions in priority order

1. **Sanity-check the current commit.** `cat docs/DESIGN.md` should say "single version supported, M212 engine, 7 spells + 101 cards + 3 key items, defeat Basilisk goal." If it doesn't match what the user remembers, ask.
2. **Set up `docs/DEV_SETUP.md`** — currently missing. Write it together with the user covering: where to install M212's HP2Engine, where the build runs `ucc make`, where compiled `.u` files go, what Python version + AP framework version is pinned. **Recommendation:** Python 3.10+, Archipelago framework matching the upstream AP `main` at the time of writing. Pin the version once chosen.
3. **Begin Milestone 1 (Hello-World mod).** See `docs/ROADMAP.md#m1`. Concretely: write a 10-line `mod/HPArchipelago/Classes/HelloMutator.uc` that logs a message on level load, get it to compile under M212's engine, get the log message to appear in-game. This validates the entire toolchain before any AP work.
4. **Ask the user about scaffolding the proposed agents** in `docs/AGENTS.md` — but **do this AFTER M1 ships**. Pre-creating agents before the toolchain works is premature.

## External resources you'll need access to

These are NOT cloned into this repo (they're huge) but were used heavily during design. The user should re-clone them on the new PC, _outside_ this repo:

- `https://github.com/metallicafan212/HP2UScriptDecompile` — full decompiled retail UScript source. **Read this whenever you write a UScript hook.** Especially `HGame/Classes/WizardCards/WizardCardIcon.uc` (card pickup pattern), `HGame/Classes/Bosses/Basilisk.uc` (goal hook target), `HGame/Classes/Spells/*` (spell base classes).
- `https://github.com/metallicafan212/HarryPotterUnrealWiki` — modding wiki. The `Main-Resources` and `Tutorials` pages list all editor/tool downloads.
- `https://docs.google.com/document/d/1b_AsvqQtcTTLohgOdXqTHbC-oK6-KsD5ZeBuX4Usw2A` — Metallicafan212's HP2 editor + engine doc. Required to download M212's engine.
- HP modding Discord: `https://discord.gg/th3K6Epnug` — ask `Metallicafan212` and `AdamJD` directly for engine/UScript questions.

## Things the user already discovered or asked the Discord about (don't re-ask)

- **Networking confirmed working in M212's engine.** `IpDrv.dll` is present in M212's HP2Engine `System/` folder (visible in image_from_metellicafan.png from the original session). M212 said: "I restored it from UT99. Should work fine, I haven't tested it in years." Treat as working but verify end-to-end during M2.
- **Stock KW networking is stripped.** The randomizer therefore *requires* M212's engine for players. Goes in the player setup README.
- **Cards in source: 50 Bronze + 40 Silver + 11 Gold = 101 confirmed.** Don't re-count.
- **FlobberMucus and WiggenBark are NOT key items** (potion ingredients, buyable from NPCs). User confirmed. They're not in `data/items.yaml`.

## Open questions deferred to playtest

These cannot be answered without playing the game. Don't try to resolve them by reading source — wait for the user to playtest.

1. The 4th classroom location (we have Lockhart's, Sprout's, Snape's — what's the 4th tutorial?). Update `data/locations.yaml#classrooms`.
2. Which spell each classroom teaches in vanilla. Update notes in `data/locations.yaml`.
3. Per-card vanilla regions for the 101 card locations (currently all `region: TBD`). User catalogues during the unlock-everything seed playtest.
4. Per-location requirements for cards behind extra obstacles. Update `data/logic.yaml`.
5. Which trigger fires the post-tutorial level transition (cutscene end? flag check?). Determines what to suppress in `APSpellHook.uc`.
6. Whether HP2 has a "level cleared" persistent flag that locks re-entry. If so, patch it.
7. The exact name of the Basilisk death function (`Died`, `Killed`, custom?) — read `Basilisk.uc` once available.
8. Final Chamber of Secrets entry gate: all spells, all challenges cleared, or both. Currently set to all-spells in `logic.yaml`.

## Behavior the user wants from you

- **One question at a time** when grilling on design (this was an explicit ask during the original session). Don't pile up multiple decisions in a single response.
- **Always provide a recommendation** alongside any design question.
- **Stay in v1 scope.** If a feature isn't in `docs/ROADMAP.md` for M1–M8, push back unless the user explicitly invokes a parking-lot item.
- **The user authors logic.yaml; you scaffold.** Don't try to write game-knowledge-heavy logic rules yourself.

## What's saved in Claude memory (this PC only — won't carry to the new PC)

The previous Claude instance on the original PC saved one project memory: `project_hp2ap_v2_parking_lot.md` covering deferred features. This is **not in the repo** and **won't follow to the new PC** — but the same content is in `docs/DESIGN.md#v2-parking-lot`, which IS in the repo. So nothing's actually lost. You can save your own memory on the new PC after you've read the docs.

## Sign-off

Last design conversation finished 2026-05-06 ~22:40 local time. User signed off explicitly to continue tomorrow on a different PC. Repo committed and pushed to `https://github.com/Kryen112/HP2PC_AP`. Resume by reading the docs and asking the user "where do you want to start — M1 setup, or any open design question first?".
