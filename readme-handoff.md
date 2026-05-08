# Handoff — written 2026-05-08 end-of-day

This file is for the next Claude that boots into this repo. Read it top-to-bottom before doing anything else. The previous session did major architectural work on card pickup (the new `APCardMarker` system) and started M6 logic + seed gen. Two specific code changes from the very end of the session are **untested in-game** and need verification first thing next session.

---

## ⚠️ FIRST THING NEXT SESSION — TEST THESE TWO CHANGES

Both landed in the final code commit (just before the docs commit). The previous Claude couldn't test them — Stefan ran out of time and signed off after Stefan reported the symptoms but before fixes were verified.

### Change 1 — APCardMarker gravity (was floating mid-air)

`mod/HPArchipelago/Classes/APCardMarker.uc` — `Spawned()` was `PHYS_None`, which left chest-spawned markers floating at the chest mouth (Stefan saw a Wadcock marker float in air). Changed to `PHYS_Falling` while still skipping the bouncing state so loose-icon replacements stay near their design-time x/y.

**Verification:**
1. `.\HP2PC_AP\scripts\rebuild_mod.ps1` (admin shell)
2. Fresh new game with the smoke seed (test/HP2_Test.yaml plandos `Card_Starkey → Wadcock`, `Card_Wadcock → Diffindo`)
3. Walk Starkey marker → AP grants Wadcock card
4. Walk to Wadcock chest → marker should drop to floor (not float at chest mouth)
5. Walk over Wadcock marker → should fire `CHECK 36` → AP grants Diffindo

If markers fall through floors instead of landing on them, switch back to `PHYS_None` for one variant — see "fallback options" below.

### Change 2 — sidecar dedup removed

`client/hp2_ap_client.py` — removed the `granted_card_game_ids` set entirely. Stefan reported that walking over the Wadcock marker (after AP had granted Wadcock from the Starkey location) didn't fire a real CHECK because the sidecar was dedup-blocking it as "watcher echo".

The dedup was a holdover from M3 when the watcher fired echo CHECKs after `SetCardOwner`. With `MarkAsGranted` setting `WasOwnedByHarry[id]=1` BEFORE `SetCardOwner` runs, the watcher's transition path is suppressed and there's no echo to dedupe. The only `CHECK <id>` source now is `APCardMarker.Touch` — which is always a real player walk-over.

**Verification:**
1. With the test seed running (gravity test above), Stefan walked Starkey → got Wadcock card
2. Walk to Wadcock's marker → sidecar log should show `Sent LocationChecks for Card_Wadcock`
3. AP grants Diffindo (per the second plando line)
4. Spellbook shows Diffindo

If you see `Ignoring CHECK 36 — sidecar just GRANTed this card; watcher echo`, the dedup wasn't fully removed — re-check `hp2_ap_client.py` for any lingering `granted_card_game_ids` reference.

### Fallback options if the gravity change is bad

- If markers fall through level geometry: revert `Spawned()` to `PHYS_None`. Chest-spawned markers float at chest mouth (annoying but pickable). Loose-icon replacements stay in place. Trade-off documented.
- If markers stop firing CHECK after the gravity change: not expected, but if so, check that `Spawned()` doesn't accidentally call `Destroy()` somewhere.

---

## Who you're working with

**Stefan Kuppen** (`stefan.kuppen@indi.nl`, GitHub: `Kryen112`).

- Solid AP Python knowledge — has contributed to AP randomizers before.
- Zero UnrealScript experience before this project; learned a lot during M1–M6.
- Zero C/C++ / reverse-engineering experience. The architecture intentionally avoids native code.

### Hard rules (saved as feedback memories — do not violate)

1. **Commit messages: 10–25 words, single sentence.** Any longer and Stefan will push back.
2. **Never put your name (Claude / AI) under a commit.** No `Co-Authored-By: Claude` trailers, ever.
3. **Never recommend stopping based on time of day.** Stefan codes long hours and finds "want to stop here for the night?" prompts annoying.
4. **Be terse.** Don't trail responses with summaries — Stefan can read the diff.

---

## Where the project is

The project is **HP2PC_AP**, an Archipelago multiworld randomizer for *Harry Potter and the Chamber of Secrets* (PC, 2002 KnowWonder release), built on Metallicafan212's HP2Engine 3.4 (UE1 fork that restored UT99 IpDrv networking).

### Milestones

| Milestone | Commit | What it proved |
| --- | --- | --- |
| M0 — Bootstrap | `48e3cac` | Repo + design docs |
| M1 — Hello-world mod | `929c493` | UScript toolchain works; `DefaultGame=` in `Game.ini` is the canonical entry point |
| M2 — TcpLink ping/pong | `cddb73f` | UScript ↔ Python bidirectional IPC over localhost:38281 |
| M3 — Card pickup round-trip | `5cedc10` (initial) → `608663d` (album-fix) → `df05524` + uncommitted (APCardMarker rewrite) | Card pickup architecture has been through three iterations; current is APCardMarker (see DESIGN.md) |
| M4 — Real AP integration | `302b27d` | Sidecar subclasses `CommonContext`; speaks real AP WebSocket protocol against MultiServer |
| M5 — Full pool + hooks | `91ddc48`, `a167dfa`, `fcd68a5` | 114 items, 117 locations, gen pipeline, all four grant types (cards/spells/key items/beans) wired both ways |
| M6 — Logic + seed gen | `df05524` + uncommitted | logic.yaml schema authored, regions.py + rules.py generated, APCardMarker chest-replacement architecture; 5 region entry rules still TBD; per-card region cataloguing still TBD |
| M7 — Goal detection | not started | Plan: poll `FEBook.bInEndGame` from `APCardWatcher`, send `ClientStatus.CLIENT_GOAL`. See `docs/MOD_TODO.md`. |
| M8 — UX polish | not started | HUD toast, vendor disable, etc. |

### Card pickup architecture as of 2026-05-08 — APCardMarker

This is the *third* card-pickup iteration. Read `docs/DESIGN.md#card-pickup-architecture-apcardmarker` for the full rationale; here's the executive summary:

- **101 generated `APCardMarker_<ClassName>` UScript subclasses** (one per card). Each extends `APCardMarker` (which extends `WizardCardIcon`) and sets `CardLocationId` to the real card id (1..101).
- **Sentinel `Id=200`** in `APCardMarker` defaults so vanilla `harry.uc:977 / RemoveHarryOwnedCardsFromLevel(None)`'s `IsOwnedByHarry(class.Default.Id)` check never matches → markers immune to the level-entry bean-swap.
- **`APGameInfo.ReplaceCardChests()`** runs at every `InitGame`: iterates `chestbronze` (covers `ChestWood`/`ChestIron`/`ChestGold` via UE1 polymorphism), `bronzecauldron`, and loose `WizardCardIcon` actors. Swaps card-class slots / icons to the corresponding `APCardMarker_<X>`. **Critical:** for loose icons, `wci.Destroy()` happens BEFORE `Spawn(marker, ..., wci.Location)` because same-coords overlap causes UE1 to silently destroy the new actor and return None from `Spawn`.
- **`APCardMarker.Touch`** fires `CHECK <CardLocationId>` over IPC and `Destroy()`. Does NOT call `SetCardOwner` (that path is reserved for the AP grant-application flow). Sets `class'APCardWatcher'.default.LocationChecked[CardLocationId]=1`.
- **`PostBeginPlay`** checks `LocationChecked[CardLocationId]` and self-destroys if already collected — re-entered levels don't re-spawn already-collected markers.
- **`Spawned()`** override: `PHYS_Falling` + skip bouncing state. Marker drops to floor (chest mouth → floor for chest spawns; loose icons usually already grounded).
- **`APCardWatcher.LocationChecked[102]`** class-default byte array, persists across level transitions in a session.
- **`APGameInfo.TryApplyCard`** for AP grants: calls `MarkAsGranted(cardId)` to set `WasOwnedByHarry[id]=1` BEFORE `SetCardOwner(id, Harry)`, so the watcher's transition path doesn't fire an echo CHECK. Album updates via `WizardCards[50]` (the canonical store FEFolioPage reads).
- **Sidecar's `granted_card_game_ids` dedup is removed** — only marker-Touch fires CHECK now, so no echo to dedupe.

### Detection (the 0.25s polling APCardWatcher)

Still in place as a safety net for any non-marker grant path (e.g., cutscene-scripted card grants):

- **Cards**: `APCardWatcher` polls `IsOwnedByHarry(id)` for ids 1–101 every 0.25s. On 0→1 transition (and not `WasOwnedByHarry[id]`), fires `CHECK <id>` and reverts `SetCardOwner(id, None)` if not `APGrantedCard[id]`.
- **Spells**: same watcher polls `harry.IsInSpellBook` for the 7 spells. AP-granted spells (`MarkSpellAsGranted`) preserved. Vanilla cutscene-granted spells are reverted (so the AP-placed item at the classroom location is the only spell granted).
- **Key items**: same watcher polls `nCount` on `StatusItemBoomslang/Bicorn/BitOGoyle` (in `StatusGroupPolyIngr`). AP grants flow through `MarkKeyItemAsGranted` to suppress echo.

### Grant application (in `APGameInfo.ApplyGrant`)

- **Cards** → `MarkAsGranted(id)` then `siCard.SetCardOwner(cardClass.default.Id, CardOwner_Harry)`. Does NOT call `RemoveHarryOwnedCardsFromLevel` (incompatible with marker architecture).
- **Spells** → `MarkSpellAsGranted(name)` then `harry.AddToSpellBookByString(name)`.
- **Key items** → `MarkKeyItemAsGranted(name)` then `managerStatus.AddBoomslang(1)` / `AddBicorn(1)` / `IncrementCount(StatusGroupPolyIngr, StatusItemBitOGoyle, 1)`.
- **Beans** → `managerStatus.AddBeans(25/50/100)` for Small/Medium/Large.

### M6 status

Code scaffolding complete. Authoring in progress.

- **`data/logic.yaml`**: schema documented at top. Regions list filled. 4 classroom locations specified. Goal `basilisk → [LevelClear_ChamberOfSecrets]`. **5 region `entry:` rules still `TBD`** — ForbiddenForest, Quidditch, BicornLevel, BoomslangLevel, GoyleLevel. Generator currently treats TBD as `True` (lenient mode) and prints a warning listing them.
- **`data/locations.yaml`**: classroom + level-completion locations have `region:` filled. **101 cards still have `region: TBD`** — Stefan catalogues these during playtest. Generator routes TBD-region cards to a placeholder TBD region reachable from Menu (open-hub).
- **Generator (`scripts/gen_apworld.py`)** emits: `apworld/items.py`, `apworld/locations.py`, `apworld/regions.py`, `apworld/rules.py`, plus 101 `mod/HPArchipelago/Classes/APCardMarker_<X>.uc` files.
- **`apworld/__init__.py`** wires region entry rules into `Region.connect(... rule=...)` and goal completion via `state.can_reach_location("LevelClear_ChamberOfSecrets", player)`.

## Setup on Stefan's machine

- Game install: `C:\Program Files (x86)\Harry Potter 2\Modded` (with M212 engine patched in). `Bingo` is the M212-bingo install, leave it alone.
- Repo: `C:\Users\kryen\Documents\Archipelago-play\Harry Potter 2 PC\HP2PC_AP`
- Archipelago framework checkout: `C:\Users\kryen\Documents\Archipelago-play\Archipelago` (sibling of the project)
- The apworld lives at `Archipelago\worlds\harry_potter_2\` — Stefan uses an `mklink /J` junction so edits in `apworld/` flow into the AP repo for live testing.
- Python 3.12 + asyncio + websockets via AP's `CommonClient`.
- UScript builds via `ucc make` in the Modded\System directory.

### PowerShell scripts in `scripts/`

- `gen_seed.ps1` — regen apworld + generate a fresh AP seed
- `host_seed.ps1` — host the latest seed on port 38282
- `run_sidecar.ps1` — start the sidecar (terminal B)
- `rebuild_mod.ps1` — robocopy mod source + run UCC make (REQUIRES admin shell)

Standard test loop: `rebuild_mod.ps1` (admin) → `gen_seed.ps1` → `host_seed.ps1` → `run_sidecar.ps1` → game.

### File encoding gotchas

- `Game.log` is **UTF-16 LE** — read it with `iconv -f UTF-16LE -t UTF-8` or you'll get garbage.
- `Game.ini`, `HP.ini`, `Default.ini` are **ANSI / Win-1252**.
- `HP.ini` in the user data folder **overrides** `Default.ini`. If you edit `EditPackages=` in `Default.ini` and it doesn't take effect, also edit `HP.ini`.

### Mod entry point — verified, do not regress

`APGameInfo` extends `Engine.GameInfo`, registered via `DefaultGame=HPArchipelago.APGameInfo` under `[Engine.Engine]` in `Game.ini`. Everything else is silently ignored by HP2/M212:

- ❌ `[Engine.GameEngine] ServerActors=` — silently dropped
- ❌ `?Mutator=` URL params — stripped by HP2's Browse
- ❌ `GameInfo.AddMutator(string)` — KnowWonder removed it

### Persistent singleton pattern — verified, do not regress

`APIPCActor` survives level transitions via `bGameRelevant=True` + `bAlwaysRelevant=True` + class-default ref initialized in `PreBeginPlay` + `APGameInfo.InitGame` checks `APIPCActor.static.GetInstance()` before spawning. One TCP connection lasts the whole session.

`APCardWatcher` is per-level (no `bGameRelevant`) but its class-default `LocationChecked[]` and `LatestInstance` survive across levels. `APGameInfo.FindActiveHarry` resolves harry through `APCardWatcher.GetLatest().Level.PlayerHarryActor` so the gameplay UWorld's harry is targeted (not Entry's).

## Known v1 limitations (parked for v2)

See `docs/DESIGN.md#v2-parking-lot` for full descriptions.

- **Spell-challenge auto-transition + locked exit door.** Walking into a classroom auto-teleports to the spell challenge with the exit locked behind. If the player doesn't already own the spell (because we revert vanilla cutscene grants), they softlock. v1 workaround: AP logic should make the spell reachable before its classroom; or plando the spell at its own classroom.
- **Save-load vs new-game distinction.** Currently no protection against loading a save from a different multiworld slot.
- Various v2 features: entrance shuffle, alt goal modes, Tier-3 check expansion, vendor card sales, trap items, etc.

## Read these in order on resume

1. `README.md` — project overview
2. `docs/ROADMAP.md` — milestone-by-milestone status
3. `docs/DESIGN.md` — every locked decision, including the APCardMarker architecture and the v2 parking lot
4. `docs/MOD_TODO.md` — UScript implementation checklist
5. `docs/DEV_SETUP.md` — toolchain commands
6. This file (you're reading it)

## Memory pointers

The `memory/` directory under `~/.claude/projects/.../` should auto-load via `MEMORY.md`. Includes:

- Stefan's role and skill profile (user memory)
- Don't-stop-recommending feedback
- Short-commit-message feedback
- No-AI-attribution feedback
- HP2 AP Randomizer — v2 parking lot
- HP2 AP Randomizer — v1 vanilla story progression (canonical level/spell flow)
- HP2/M212 engine quirks (Game.log encoding, ini layering, etc.)
- HP2 mod entry point (DefaultGame= pattern)

If those don't appear in your initial context, the memory system is broken — flag it.

## First sanity check on resume

```powershell
git log --oneline -5
```

Should show the latest two commits from this session: a code commit (M6 + APCardMarker) and a docs commit (this handoff + DESIGN/ROADMAP/MOD_TODO updates). If older, ask Stefan.

```powershell
ls docs/
```

Should show `DESIGN.md ROADMAP.md MOD_TODO.md DEV_SETUP.md AGENTS.md`.

## When unsure, ask Stefan

He'd rather you ask one specific question than guess and waste time. But spend up to a minute on read-only investigation first (grep, read existing files) so the question is specific.
