# MOD_TODO — UnrealScript implementation checklist

Running list of things the UScript mod must do. Build out across milestones M1–M8 (`docs/ROADMAP.md`). Tick off as you go.

## Hooks (intercept vanilla events to send AP `check_sent`)

- [x] **Card pickup hook (M3, 2026-05-07)** — implemented as `APCardWatcher`, a polling Actor spawned from `APGameInfo.InitGame()`. It binds to `harry.managerStatus`'s bronze/silver/gold StatusItems and polls `IsOwnedByHarry(id)` for ids 1–101 every 0.25s. On diff, fires `CHECK <id>` over IPC. Catches every grant pathway including cutscene-script and chest grants — broader coverage than the original Touch-override plan. Subclassing `BronzeCards`/etc. proved unnecessary.
- [~] **Spell-tutorial completion hook (M5, partial)** — `APCardWatcher` polls `harry.IsInSpellBook` and fires `CHECK_SPELL <name>` on diff. Detects all 7 user spells. Initial snapshot baselines starter spells (Lumos/Flipendo/Alohomora). **Still TODO:** map detected spell to a specific classroom location (M6 + playtest data) so the sidecar can send `LocationChecks`. Also unsolved: suppress the auto-transition into the matching challenge level (DESIGN open #7).
- [x] **Key-item pickup hook (M5, fcd68a5)** — `APCardWatcher` polls `StatusItemBoomslang/Bicorn/BitOGoyle.nCount` in `StatusGroupPolyIngr` (all three are in PolyIngr — confirmed at runtime). Fires `CHECK_KEYITEM <name>` on transition from 0 → 1. Sidecar logs but doesn't yet send `LocationChecks` (location mapping → M6).
- [ ] **Level completion hook** — find the level-end trigger fired at the end of each level; fire `check_sent` with the level ID. Allow the level to end normally.
- [ ] **Basilisk death hook** — subclass `Basilisk` (`HGame/Classes/Bosses/Basilisk.uc`), override its death function, fire `goal_complete`, then call Super.

## Inbound (apply items granted by the AP server)

- [x] **`APItemReceiver` (M3+M5)** — implemented inside `APGameInfo.ApplyGrant`. Dispatches by item name: spells, key items, beans, cards. Spell + key item + bean apply functions are naturally idempotent (`AddToSpellBookByString` no-ops if already known; key item adds increase nCount but the watcher's snapshot baselines starter state; beans just increment).
- [x] **Apply spell (M5, a167dfa)** — `harry.AddToSpellBookByString(name)`. Idempotent per HP2's own `AddToSpellBook` guard (`SpellBook[type] == None` check). Celebration FX not added; deferred to M8 polish.
- [~] **Apply card** — partial (M3, 2026-05-07). `APGameInfo.ApplyGrant` spawns the card class at harry's location and calls `Touch(harry)`, invoking the full vanilla `WizardCardIcon.Touch` chain (`SetCardOwner` + `RemoveHarryOwnedCardsFromLevel` + `Super.Touch` → `DoPickupProp` → `managerStatus.PickupItem`). The watcher confirms the SetCardOwner write succeeds in-memory. **However** HP2 wipes `WizardCards[]` between operations and the album does not reflect AP-granted cards. Open M212 Discord question — see `docs/DESIGN.md` open question 6. Also note: the grant arrives at the mod via `GRANT <UScriptClassName>` from the sidecar (M5 wired the real `AP item name → UScript class` mapping; sidecar deduplicates the watcher echo so the grant doesn't trigger an infinite cascade).
- [x] **Apply key item (M5, fcd68a5)** — Boomslang/Bicorn via `managerStatus.AddBoomslang(1)` / `AddBicorn(1)` helpers; BitOGoyle via explicit `IncrementCount(StatusGroupPolyIngr, StatusItemBitOGoyle, 1)` (no helper exists). Silent (no toast yet — M8).
- [x] **Apply filler (beans) (M5, fcd68a5)** — `managerStatus.AddBeans(N)` with 25/50/100 for Small/Medium/Large tiers. Silent (no toast yet — M8).

## Item delivery queue

- [ ] **`APItemQueue`** — FIFO queue. `grant_item` messages enqueue. A `Tick`-based drainer applies items only in **safe states**:
  - Harry exists, has player control (no `bIsInCutscene`, no menu open, no level load in progress, not Quidditch mid-match, not in dialog).
  - One item per ~1.5 seconds to prevent FX/sound flooding.
- [ ] **HUD toast** — for every applied item, also emit an on-screen "Received <item> from <player>" message. Stack vertically, fade after a few seconds.

## Vendor disable

- [ ] **Disable vendor card sales** — find the vendor inventory class; remove cards from the available SKUs. Beans / potion ingredients still sold normally.

## Level lockouts

- [ ] **Confirm levels are re-entrable** after completion. Vanilla HP2 might or might not lock you out of completed levels; investigate during playtest. If it does, patch the level-state flag check.

## Mod entry point (verified M1, 2026-05-07)

- [x] **`APGameInfo`** — subclass of `Engine.GameInfo`. Override `event InitGame(string Options, out string Error)` to call `Super.InitGame(...)` then spawn `APIPCActor` (and any other persistent mod actors) via `DynamicLoadObject` + `Spawn()`. Registered via `DefaultGame=HPArchipelago.APGameInfo` in `Game.ini` `[Engine.Engine]`. Fires once per level transition.

  Stock UE1 hooks that **do not work** in HP2/M212: `[Engine.GameEngine] ServerActors=` (silently ignored), `?Mutator=` URL params (dropped by HP2's Browse), and `GameInfo.AddMutator(string)` (stripped by KnowWonder). See `docs/DESIGN.md#mod-entry-point` for the working pattern and the verified-dead alternatives.

## IPC

- [x] **`APIPCActor` (M2/M3, 2026-05-07)** — extends `IpDrv.TcpLink`, connects to `localhost:38281` via `StringToIpAddr` (no DNS roundtrip). Persists across levels via `bGameRelevant=True` + `bAlwaysRelevant=True` + class-default singleton ref + per-instance check in `APGameInfo.InitGame`. Sidecar accept-loop tolerates per-level reconnects but the singleton means it doesn't churn unnecessarily. Currently uses simple `HELLO` / `CHECK <id>` / `GRANT <classname>` text protocol; will move to JSON in M4.
- [ ] **Boot sequence:** on level load, if not connected, attempt connect. On connect, request the items-received list from the sidecar (which got it from the AP server) and re-apply via `APItemReceiver` (idempotent). *(Today: connect happens but no replay on connect — needs to be added in M4.)*
- [x] **Persistence across levels** — solved with the singleton + `bGameRelevant`/`bAlwaysRelevant` pattern. One `APIPCActor`, one connection, lasts the whole game session.

## Config

- [ ] **`APConfig`** — port, possibly the slot name as a fallback. Editable via console (`set APConfig nPort 38281`) or .ini.

## Open questions for playtest

- Whether each of the 7 spells is taught in a classroom, picked up from a book, or earned in a challenge — needs cataloguing. (Determines the 4 sphere-0 location names.)
- Whether the post-tutorial level transition is fired by the cutscene, by a trigger, or by a state change — determines what to suppress.
- Whether HP2 has a "level cleared" persistent flag; if yes, whether re-entry is gated by it.
- What the Basilisk death function is actually called (`Died`, `Killed`, custom). Confirm in `Basilisk.uc` / `baseBasilisk.uc`.
