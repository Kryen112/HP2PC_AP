# Handoff — written 2026-05-09 end-of-day

This file is for the next Claude that boots into this repo. Read it top-to-bottom before doing anything else. The previous session prepped the apworld + sidecar for a real solo playthrough and Stefan started cataloguing per-card regions in `data/locations.yaml` mid-playthrough.

---

## Verified end-of-session 2026-05-09

- **18-marker chest investigation closed (deferred to M8 polish).** Root cause is `chestbronze.turnover`'s `for(iBean=0; iBean<iNumberOfBeans; iBean++) generateobject()` loop — `ChestWood2/Grounds_Night` has `iNumberOfBeans=18` and the native `FancySpawn` jitters per call across cardinal offsets at increasing radius, so one card-slot replacement explodes into 18 markers. Player visually only sees one card flying out (the rest stack at near-identical coords); the first `Touch` fires CHECK and `Destroys`, the others sit invisible/inert. Two dedupe attempts (foreach `AllActors` and class-default `HasPrimaryMarker[]` registry) both failed in different ways and were reverted; full forensics are in `docs/MOD_TODO.md` under "Cosmetic / known issues (M8 polish)". **Do not redo the investigation** — read the MOD_TODO entry first.
- **Real-playthrough seed pipeline working end-to-end under the old scaffold.** `tests/HP2_Test.yaml` is now configured for a full solo playthrough: the APWorld precollects Lumos/Flipendo/Alohomora (avoiding the watcher's revert of vanilla cutscene grants), `plando_items` places each non-starter spell at its own classroom (workaround for the classroom-softlock v2-parking-lot item), and Card_Starkey/Wadcock/etc are randomized like everything else. The old seed verified 117 unique placements, no card duplicates, sphere 0 = the 3 starter spells, sphere 1 = the 4 classroom spells. Superseded 2026-05-10: v1 now generates 108 checks after removing level-completion locations.
- **108-check generation verified 2026-05-10.** `Generate.py --plando "items"` fills 104 random items after 3 mandatory starter-spell precollections and 4 classroom spell plandos. `scripts/gen_seed.ps1` now passes `--plando "items"` so those classroom plandos actually apply.
- **`apworld/__init__.py` opted into AP common options.** Custom `HP2Options(PerGameCommonOptions)` adds `start_inventory_from_pool: StartInventoryPool` (`PerGameCommonOptions` only includes the dict-form `start_inventory`, not the from-pool variant). Also added `get_filler_item_name` returning a random `FILLER_NAMES` choice — without this, AP's default filler picker pulls any item name including cards, producing `Card_X: <duplicate-card-name>` placements when the pool shrinks (e.g. via `start_inventory_from_pool`).
- **Sidecar quality-of-life fixes** so Stefan's playthrough terminal isn't full of noise/grief:
    - INFO-level logs now visible — `logging.basicConfig(level=logging.INFO, ...)` instead of just `setLevel`. Without basicConfig, INFO falls through to lastResort handler which only emits WARNING+. Earlier session showed only `Cannot send to game (no connection)` warnings; everything else was silently dropped.
    - Items received before the game connects are queued, not warned. New `pending_grants: list[str]` on `HP2Context`; `_send_to_game` appends to the queue when `game_writer` is None/closing; `handle_game_connection` drains the queue first thing on game connect. Same path covers mid-session game crash + reconnect (sidecar stays connected to AP across game disconnects, items received in between are queued).
    - Graceful Ctrl+C — removed the `await writer.wait_closed()` call entirely (Windows ProactorEventLoop's `_loop_reading` raises `ConnectionResetError` from the loop's internal task when the socket is already reset, which surfaces as "Unhandled exception in client_connected_cb" no matter how you wrap it). Belt-and-suspenders: `_suppress_socket_reset` loop exception handler installed in `main_async` filters `ConnectionResetError`/`ConnectionAbortedError` from any other path. The `pkg_resources` deprecation warning is also silenced via `warnings.filterwarnings` before `import CommonClient`.
- **`scripts/gen_seed.ps1` now reads from `tests/` in the repo** (was reading the stale `Archipelago\hp2_only_players\` copy and silently using yesterday's plando). Single source of truth: edits to `tests/HP2_Test.yaml` flow into the next gen.

### Next session

Stefan was mid-playthrough at end-of-session, cataloguing per-card region in `data/locations.yaml` (currently 101 cards have `region: TBD`). Two parallel tracks for the next Claude:

1. **Help Stefan finish the playthrough** — answer questions about which level to enter next, where to find specific cards, etc. Reference `data/locations.yaml`, the spoiler.txt in the latest seed under `Archipelago\output\hp2_test\`, and the v1 vanilla story progression project memory.
2. **Fill the 5 TBD region `entry:` rules** in `data/logic.yaml` (ForbiddenForest, Quidditch, BicornLevel, BoomslangLevel, GoyleLevel) once Stefan has enough playtest data to know what each region requires. Generator currently fires the lenient-warning each gen — that's fine during playtest but must close before v1.

Pre-existing architectural follow-ups that did NOT progress this session: special AP-marker/interact checks for Boomslang/Bicorn/BitOGoyle, HUD toast / safe-state queue drainer (MOD_TODO "Item delivery queue"), vendor card-sale disable, M7 GOAL_COMPLETE in-game verification.

Immediate implementation follow-ups:

1. **Boomslang/Bicorn special checks** — find the vanilla ingredient pickup actors and replace or augment them with AP marker/icon checks that send `Special_Boomslang` and `Special_Bicorn`.
2. **BitOGoyle special check** — hook the end-of-Goyle interaction/touch and send `Special_BitOGoyle`; do not treat BitOGoyle as a vanilla pickup item.
3. **M7 goal verification** — compile/run the drafted `GOAL_COMPLETE` path in-game and confirm the AP server marks the slot complete after Basilisk + Great Hall walk-in + credits latency.

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
| M5 — Full pool + hooks | `91ddc48`, `a167dfa`, `fcd68a5` | 114 item entries, generated location pipeline, all four grant types (cards/spells/key items/beans) wired both ways |
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
- **Special progression items**: same watcher polls `nCount` on `StatusItemBoomslang/Bicorn/BitOGoyle` (in `StatusGroupPolyIngr`). AP grants flow through `MarkKeyItemAsGranted` to suppress echo. This polling path is not the final check model: Boomslang/Bicorn should be AP marker/icon checks, and BitOGoyle should be the Goyle end interaction/touch because there is no vanilla pickup item.

### Grant application (in `APGameInfo.ApplyGrant`)

- **Cards** → `MarkAsGranted(id)` then `siCard.SetCardOwner(cardClass.default.Id, CardOwner_Harry)`. Does NOT call `RemoveHarryOwnedCardsFromLevel` (incompatible with marker architecture).
- **Spells** → `MarkSpellAsGranted(name)` then `harry.AddToSpellBookByString(name)`.
- **Key items** → `MarkKeyItemAsGranted(name)` then `managerStatus.AddBoomslang(1)` / `AddBicorn(1)` / `IncrementCount(StatusGroupPolyIngr, StatusItemBitOGoyle, 1)`.
- **Beans** → `managerStatus.AddBeans(25/50/100)` for Small/Medium/Large.

### M6 status

Code scaffolding complete. Authoring in progress.

- **`data/logic.yaml`**: schema documented at top. Regions list filled. 4 classroom locations plus 3 special checks specified. Goal `basilisk` uses a direct all-spells rule for generation; runtime completion still comes from `GOAL_COMPLETE`. **5 region `entry:` rules still `TBD`** — ForbiddenForest, Quidditch, BicornLevel, BoomslangLevel, GoyleLevel. Generator currently treats TBD as `True` (lenient mode) and prints a warning listing them.
- **`data/locations.yaml`**: matches the 108-check v1 model: 4 classrooms + 101 cards + Boomslang/Bicorn/BitOGoyle special checks. **101 cards still have `region: TBD`** — Stefan catalogues these during playtest. Generator routes TBD-region cards to a placeholder TBD region reachable from Menu (open-hub).
- **Generator (`scripts/gen_apworld.py`)** emits: `apworld/items.py`, `apworld/locations.py`, `apworld/regions.py`, `apworld/rules.py`, plus 101 `mod/HPArchipelago/Classes/APCardMarker_<X>.uc` files.
- **`apworld/__init__.py`** wires region entry rules into `Region.connect(... rule=...)`. AP generation completion uses the direct Basilisk rule from `apworld/rules.py`; actual slot completion uses the Basilisk/credits `GOAL_COMPLETE` path.

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
