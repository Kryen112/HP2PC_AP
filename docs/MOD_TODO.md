# MOD_TODO — UnrealScript implementation checklist

Running list of things the UScript mod must do. Build out across milestones M1–M8 (`docs/ROADMAP.md`). Tick off as you go.

## Hooks (intercept vanilla events to send AP `check_sent`)

- [x] **Card pickup hook (M3+M6, 2026-05-08)** — superseded by `APCardMarker` architecture. `APGameInfo.ReplaceCardChests()` runs at every `InitGame`: iterates `chestbronze` (covers all chest variants via polymorphism), `bronzecauldron`, and loose `WizardCardIcon` actors; replaces card-class slots / icons with `APCardMarker_<ClassName>` (one of 101 generated subclasses). Markers extend `WizardCardIcon` so they look identical, but carry sentinel `Id=200` (vanilla bean-swap can't match) and the real card id in `CardLocationId`. On `Touch` they fire `CHECK <CardLocationId>` and self-destroy — no `SetCardOwner` no celebration no exploit. `APCardWatcher` still polls `IsOwnedByHarry` as a safety net for cutscene-script grants the marker swap doesn't cover. Full design in `docs/DESIGN.md#card-pickup-architecture-apcardmarker`.
- [x] **Spell-tutorial completion hook (M5+M6, 2026-05-07)** — `APCardWatcher` polls `harry.IsInSpellBook` and fires `CHECK_SPELL <name>` on diff; sidecar's `SPELL_TO_LOCATION_NAME` maps the 4 non-starter spells (Rictusempra, Skurge, Diffindo, Spongify) to `Classroom_Lockhart_Rictusempra` / `_Flitwick_Skurge` / `_Sprout_Diffindo` / `_Lockhart_Spongify` respectively, then sends `LocationChecks`. Lumos/Flipendo/Alohomora are starter cutscene spells — baselined in the watcher's initial snapshot, never fire CHECK_SPELL, and are mandatory precollected items in the APWorld.
- [~] **Special pickup/interact checks (Boomslang, Bicorn, BitOGoyle)** — DEFERRED TO v2. Removed from v1 item/location pool (2026-05-11) — the items flow through vanilla story progression. `APCardWatcher` still polls and fires `CHECK_KEYITEM` for vanilla pickups, but the sidecar's `KEYITEM_TO_LOCATION_NAME` is empty so those CHECKs are silently dropped. Re-instate when the mod-side trigger work is reliable: AP marker/icon at Boomslang and Bicorn pickup spots, and the end-of-Goyle interaction/touch for BitOGoyle.
- [x] **Goal-complete hook (post-Basilisk credits roll) — verified working 2026-05-11.** Investigation 2026-05-07 traced the credit-roll flow:
    - Post-Basilisk cutscene `.cut` invokes the `RunCredits` cutscene command.
    - `harry.uc:5582` matches it and calls `HPConsole(Player.Console).menuBook.RunTheCredits();`.
    - `FEBook.uc:1378` `RunTheCredits()` → `ShowCredits()` (line 1392), which sets `bInEndGame = True` and opens the credits page.
    - `bInEndGame` defaults False (`FEBook.uc:103`), is *only* set True in `ShowCredits()` (the also-defined `EndGame()` at line 1373 is dead — never called from anywhere). Single, reliable goal signal.
    - **Plan:** add a `bInEndGame` poll to `APCardWatcher.Tick`, alongside the existing cards/spells/key-items polls (0.25s cadence). On False → True transition, fire one-shot `GOAL_COMPLETE` line over IPC. Reach via `HPConsole(PlayerHarry.Player.Console).menuBook` — the same access pattern the vanilla command handler uses, so it's known-correct. Null-check both `Console` and `menuBook` (may be None during level loads).
    - **Sidecar side:** add a `GOAL_COMPLETE` branch in `_handle_game_line` that sends `{"cmd": "StatusUpdate", "status": ClientStatus.CLIENT_GOAL}` over the AP WebSocket. `ClientStatus` is already imported from `NetUtils` (`hp2_ap_client.py:57`).
    - **Implementation (2026-05-08, verified 2026-05-11):** `APIPCActor.SendGoalComplete()` adds the IPC line; `APCardWatcher.Timer()` polls `HPConsole(HarryRef.Player.Console).menuBook.bInEndGame` with a `WasInEndGame` one-shot guard and null-checks Player/Console/menuBook; sidecar `_handle_game_line` GOAL_COMPLETE branch sends `ClientStatus.CLIENT_GOAL` with a `goal_sent` dedupe flag. End-to-end verified — entering the Great Hall after Basilisk, skipping the cutscene, fires `bInEndGame=True`, AP marks the slot complete, items released.
    - Considered alternatives: subclass `FEBook` and override `RunTheCredits()` (cleaner OO hook but requires registering our subclass through the menu system — risky); subclass `harry` and override `CutCommand` to intercept "RunCredits" (invasive — `harry` is referenced by exact type all over the codebase); hook a level-script `Trigger` at the Great Hall doors (would fire at Great Hall arrival rather than a few seconds later at credits start, more aligned with Stefan's "speedrun endpoint" phrasing — but level scripts live in `.unr` files not decompiled here, so identification needs `UnrealEd` access on the game machine; deferred).
    - **Latency:** the post-arrival cutscene plays for several seconds before `RunCredits` fires, so `bInEndGame` flips ~5-10s after Harry walks into the Great Hall. Fine for AP — the seed is "complete" the moment any credits-bound cutscene starts; AP doesn't care about sub-second precision.

## Inbound (apply items granted by the AP server)

- [x] **`APItemReceiver` (M3+M5)** — implemented inside `APGameInfo.ApplyGrant`. Dispatches by item name: spells, key items, beans, cards. Spell + key item + bean apply functions are naturally idempotent (`AddToSpellBookByString` no-ops if already known; key item adds increase nCount but the watcher's snapshot baselines starter state; beans just increment).
- [x] **Apply spell (M5, a167dfa)** — `harry.AddToSpellBookByString(name)`. Idempotent per HP2's own `AddToSpellBook` guard (`SpellBook[type] == None` check). Celebration FX not added; deferred to M8 polish.
- [x] **Apply card (M3+M5+M6, 2026-05-08)** — `APGameInfo.TryApplyCard` resolves the `WizardCardIcon` subclass via `DynamicLoadObject("HGame." $ ItemName)`, picks the right `StatusItemBronze/Silver/Goldcards` via `ClassIsChildOf`, calls `APCardWatcher.MarkAsGranted(cardId)` to suppress watcher-echo, then writes `siCard.SetCardOwner(cardClass.default.Id, CardOwner_Harry)`. Does NOT call `RemoveHarryOwnedCardsFromLevel` (it bean-swapped chests in the current level — incompatible with the APCardMarker chest-replacement architecture; vanilla `harry.uc:977` does the level-entry sweep but markers carry sentinel `Id=200` and survive). Sidecar's `granted_card_game_ids` dedup removed in same revision — markers are the only CHECK source so no echo to dedupe.
- [x] **Apply key item (M5, fcd68a5)** — Boomslang/Bicorn via `managerStatus.AddBoomslang(1)` / `AddBicorn(1)` helpers; BitOGoyle via explicit `IncrementCount(StatusGroupPolyIngr, StatusItemBitOGoyle, 1)` (no helper exists). Silent (no toast yet — M8).
- [x] **Apply filler (beans) (M5, fcd68a5)** — `managerStatus.AddBeans(N)` with 25/50/100 for Small/Medium/Large tiers. Silent (no toast yet — M8).

## Item delivery queue

- [x] **`APItemQueue`** — FIFO queue in `APIPCActor.PendingGrants`. `GRANT` messages enqueue via `QueueGrant`. `TryDrainPendingGrants` (Timer-driven, 0.25s tick) applies items only in safe states: `Level.TimeSeconds >= GrantWarmupUntil` (8 seconds after connect), `Level.Pauser == ""` (no menu / loading / cutscene pause), a ready gameplay `harry`, and a snapshotted `APCardWatcher`. One item per 0.75 seconds to prevent FX/sound flooding.
- [ ] **HUD toast** — for every applied item, also emit an on-screen "Received <item> from <player>" message. Stack vertically, fade after a few seconds.

## Vendor disable

- [ ] **Disable vendor card sales** — find the vendor inventory class; remove cards from the available SKUs. Beans / potion ingredients still sold normally. Currently a missed card in an un-replayable level (e.g., Goyle) will be re-sold by Fred/George as a vanilla card with no AP check firing.

## Classroom challenge blockers (M8)

- [x] **Rictusempra bookcase** — `APGameInfo.BlockRictaClassroomIfMissing` spawns a `BookcaseGlassDoors` actor at the cutscene-intro location for `02060DADARictaInt` when the player doesn't yet own Rictusempra; `RemoveRictaBlocker` clears it when AP grants the spell. Verified working.
- [ ] **Skurge bookcase** — mirror the Rictusempra pattern for Flitwick's classroom. Identify the cutscene/trigger that fires the Skurge spell challenge, spawn a blocker at it when the player doesn't own Skurge, remove on AP grant. Add a fallback tag scan (same pattern as `RemoveRictaBlocker`) for save-load resilience.
- [ ] **Diffindo bookcase** — mirror for Sprout's herbology classroom.
- [ ] **Spongify bookcase** — tricky: Spongify is taught in Lockhart's DADA classroom, the same room as Rictusempra. A door-side bookcase would block Rictusempra too. Instead, gate the spell-challenge auto-teleport (intercept whatever trigger fires the Spongify challenge) rather than the room entry.

## Level lockouts

- [ ] **Confirm levels are re-entrable** after completion. Vanilla HP2 might or might not lock you out of completed levels; investigate during playtest. If it does, patch the level-state flag check.

## Mod entry point (verified M1, 2026-05-07)

- [x] **`APGameInfo`** — subclass of `Engine.GameInfo`. Override `event InitGame(string Options, out string Error)` to call `Super.InitGame(...)` then spawn `APIPCActor` (and any other persistent mod actors) via `DynamicLoadObject` + `Spawn()`. Registered via `DefaultGame=HPArchipelago.APGameInfo` in `Game.ini` `[Engine.Engine]`. Fires once per level transition.

  Stock UE1 hooks that **do not work** in HP2/M212: `[Engine.GameEngine] ServerActors=` (silently ignored), `?Mutator=` URL params (dropped by HP2's Browse), and `GameInfo.AddMutator(string)` (stripped by KnowWonder). See `docs/DESIGN.md#mod-entry-point` for the working pattern and the verified-dead alternatives.

## IPC

- [x] **`APIPCActor` (M2/M3, 2026-05-07)** — extends `IpDrv.TcpLink`, connects to `localhost:38281` via `StringToIpAddr` (no DNS roundtrip). Persists across levels via `bGameRelevant=True` + `bAlwaysRelevant=True` + class-default singleton ref + per-instance check in `APGameInfo.InitGame`. Hardened 2026-05-11: `ReceivedText` now appends to `RecvBuffer` and parses every `\n`-terminated line (a sidecar resync burst is one TCP chunk with many lines — pre-fix this dropped ~95% of GRANTs). All `gi.IPCActor.Send*` call sites now go through `class'APIPCActor'.static.GetInstance()` so post-save-load CHECKs still flow when `APGameInfo.InitGame` is skipped by `ProcessServerTravel`.
- [x] **Boot sequence / resync:** sidecar's `_resync_durable_grants` replays all durable items on `HELLO`. Idempotent apply means double-delivery is safe. Sidecar `game_writer` race fixed 2026-05-11 — finally clause only nulls if the writer is still ours, so an old-handler wakeup after a new connection doesn't strand the live writer.
- [x] **Persistence across levels** — solved with the singleton + `bGameRelevant`/`bAlwaysRelevant` pattern. One `APIPCActor`, one connection, lasts the whole game session.

## Config

- [ ] **`APConfig`** — port, possibly the slot name as a fallback. Editable via console (`set APConfig nPort 38281`) or .ini.

## Cosmetic / known issues (M8 polish)

- [ ] **Chest card-spawn dedupe (low priority)** — `chestbronze.turnover` runs `for(iBean=0; iBean<iNumberOfBeans; iBean++) generateobject()`, and `generateobject` calls native `FancySpawn(EjectedObjects[iBean], ...)`. `FancySpawn` (HP2Engine, no decompiled source) jitters per call across cardinal offsets at increasing radius, so a single card-slot replacement explodes into N markers — 18 for `ChestWood2/Grounds_Night` (logged 2026-05-08, see `Game_2026-05-08(07_12_52).log` lines 987–1006). Vanilla collapsed the duplicates via `RemoveHarryOwnedCardsFromLevel` after first pickup; we deliberately stripped that call (DESIGN.md trade-off — it would also clobber other chests' card slots). Player-visible behavior is fine: only one card flies out (the rest stack at near-identical coords and the first Touch fires CHECK + Destroys), the others sit invisible/inert. Logs are noisy: 18 `PostBeginPlay` lines per Wadcock-style chest open. **Failed fix attempt 2026-05-09:** tried (a) `foreach AllActors(class'APCardMarker', ...)` dedupe in `PostBeginPlay` — never matched (suspect: native `FancySpawn` batches actor creation so PostBeginPlay siblings aren't visible to `AllActors` yet); then (b) class-default `HasPrimaryMarker[102]` byte-array registry with per-level reset in `APGameInfo.InitGame` — over-eager, killed the survivor too (root cause not diagnosed; needs more logging next attempt). Both reverts now in place. When revisiting: add a `Log` line immediately before/after each registry write to confirm what's happening, and consider a different scope for the registry (e.g. on `APCardWatcher` instead of class-default on `APCardMarker`).

## Open questions for playtest

- Whether each of the 7 spells is taught in a classroom, picked up from a book, or earned in a challenge — needs cataloguing. (Determines the 4 sphere-0 location names.)
- Whether the post-tutorial level transition is fired by the cutscene, by a trigger, or by a state change — determines what to suppress.
- Exact AP marker/icon approach for Boomslang and Bicorn, plus the cleanest trigger for BitOGoyle's Goyle-touch check.
- ~~What the Great Hall post-Basilisk entry trigger is.~~ Resolved 2026-05-07: hook `FEBook.bInEndGame` instead of the level-script trigger. See the M7 entry above for the full plan.
