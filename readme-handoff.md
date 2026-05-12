# Handoff — written 2026-05-11 end-of-day

This file is for the next Claude that boots into this repo. Read it top-to-bottom before doing anything else. The previous session pushed M6 + M7 over the finish line, hardened the marker/chest/sidecar plumbing, and authored the full v1 logic.

---

## Resume point for next session (2026-05-12, on Stefan's other PC)

**Pick this up first.** Stefan is continuing tomorrow on his other PC, so the next Claude must read this section before doing anything else.

- **Diffindo bookcase blockers**: done. Row of 3 bookcases in front of Sprout's `08040HerbDiffIntro` cutscene in Grounds_hub covers the doorway. (Tried 4 originally; 3 is enough.)
- Diffindo offsets are WORLD coords (no rotation transformation) — we switched from local coords because the cutscene's `Yaw=49136 (≈270°)` rotation made diagonal stepping in local space too painful to reason about. World coords match exactly what the spawnLoc log lines show. Bookcase ORIENTATION is still derived from `cs.Rotation + 32768 yaw` so the bookcases face Harry's approach; only POSITION is world-coords.
- All Diffindo machinery (idempotency dropped for multi-bookcase, tag-scan removal of all 3, save-load resilience via `APCardWatcher.TrySpawnClassroomBlockers`) is in place and working.

**What still needs doing in M8**: `docs/PLAYER_SETUP.md`, v1.0.0 release zip. All four bookcase blockers (Ricta / Skurge / Diffindo / Spongify), the full vendor card-sale rewrite (Phases A filter / B replacement / C assignment), the HUD toast (`APHUDToast.uc` with panel bg + woosh sound + tier in text + sender/recipient slot name), and the seed-gen smoke test (`tests/test_generation.py` — subprocess-driven, default N=25, scale via `--count`) are in place. See `docs/ROADMAP.md` M8 + `docs/MOD_TODO.md`.

---

## Verified end-of-session 2026-05-11

The seed is end-to-end playable, including goal completion. Stefan ran from `Adv1Willow` to the Basilisk and the post-Basilisk Great-Hall walk-in fired `GOAL_COMPLETE`; the AP server marked the slot complete and released items.

### Logic.yaml authoring (M6 done)

- All 18 region entry rules authored. Alohomora is encoded explicitly wherever it's required (region entry for 10 regions where every card needs it; per-location for the rest) — Stefan plans to expose an "Alohomora-not-starter" YAML option later, so the logic must be honest about which locations depend on it.
- All 101 cards have a `region:` in `data/locations.yaml`. Card_Sykes was originally mis-listed as Furmage in Castle Exterior; corrected to put Card_Furmage in `SpongifyChallenge` and Card_Sykes in `CastleExterior` (with `requires: "Spongify"`).
- 38 per-location `requires:` overrides — see `data/logic.yaml`.
- Pool size: **108 items / 105 checks** (was 111/108). Boomslang / Bicorn / BitOGoyle and their three Special_* locations were pulled from v1 (they flow through vanilla story; will return in v2 once the mod-side trigger work is reliable).
- Day/night unified — no separate `HogwartsNight` region; Card_Oglethorpe placed in `CastleExterior` with `requires: "Alohomora & Spongify & Diffindo"`.
- Placement constraint: gold-card chest locations cannot hold silver-card items (`add_item_rule` in `apworld/__init__.py:set_rules`). Prevents the 40-silvers-to-unlock-gold-chest circular dependency.
- Generator + seed gen both clean: `gen_apworld.py` emits 111 items / 105 locations / 18 regions / 38 per-location overrides; `Generate.py` fills 104 random items in ~50ms.

### Mod-side hardening (mostly M8 polish)

- **Save-load spell revert FIXED.** Pre-fix, the watcher restored from a `.usa` cache had `bSnapshotted=True` but stale/zeroed `APGrantedSpell[]`, so its revert loop wiped any AP-granted spells the save preserved. Fix: `APCardWatcher.EnsureLatestRegistration` clears `bSnapshotted=False` when it claims `LatestInstance` from a stale slot, forcing a re-Snapshot.
- **Sidecar reconnect race FIXED.** `handle_game_connection` `finally` clause now guards `if self.game_writer is writer:` before nulling — on Windows ProactorEventLoop, an old handler's late wakeup no longer clobbers the new connection's writer.
- **Multi-line `ReceivedText` FIXED.** Was stripping at first `\n` and discarding the rest, so a 78-line resync burst dropped ~76 of the GRANTs. Now buffers `RecvBuffer` across chunks and parses every line.
- **Save-load `IPCActor=None` FIXED.** `ProcessServerTravel` skips `APGameInfo.InitGame`, so the post-save-load `APGameInfo` instance had `IPCActor=None` and every game→sidecar CHECK silently dropped. Fix: all `gi.IPCActor.Send*` call sites now use `class'APIPCActor'.static.GetInstance()` (5 sites in `APCardMarker.uc` + `APCardWatcher.uc`).
- **Playable-state grant gate REPLACED the 8s warmup.** `APGameInfo.IsPlayerInPlayableState(harry, out reason)` is now the authoritative "Harry is actually playing" check called from `APIPCActor.TryDrainPendingGrants` after the pre-existing `Level.Pauser` / `FindGrantReadyHarry` / `watcher.bSnapshotted` gates. Whitelists `harry.GetStateName()=='PlayerWalking'` only (`PlayerSwimming` isn't reachable in v1; every other state defers — `stateCutIdle`, `SpellLearning`, `harryfrozen`, `stateDead`, `GameEnded`, `exittoMenu`, `stateInactive`, `Mounting`/`MountFinish`, Quidditch, dueling, `statePickupItem`, `statePotionMixing*`, `wingspell`, `LookAtActor`, `ChessDeath`, `CelebrateCardSet`, etc.). Also rejects `bIsCaptured`, `bKeepStationary` (vendor), and `HPHud(myHUD).IsCutSceneOrPopupInProgress()` (covers the tick gap between cutscene start and `stateCutIdle` transition, plus cutscene-skip border animation via `managerCutScene.bBothBordersActive`). The previous 8s warmup was deleted entirely — every condition it was hedging against (watcher cold, loading-screen leak, post-load cutscene, resync flood) is now explicitly gated by either this helper or the pre-existing checks plus the 0.75s drain spacing. Reconnect/save-load grants now drain ~0.75s after Harry hits PlayerWalking instead of ~8.75s. **Tightened 2026-05-12** after observing items leaking during opening cutscenes: added `HasActiveCutScene` (any `CutScene` actor with `bPlaying=True` defers — `IsCutSceneOrPopupInProgress` only returns True after the cutscene script issues `CAPTURE`, leaving a window before that), and added `NextGrantDrainEarliest` stability cooldown bumped 3.0s by `Snapshot` (post-snapshot warmup, covers the gap before `bLevelLoadStarts` cutscenes hit `Play()`) and 1.0s by every defer branch (post-defer cooldown, requires harry to stay in PlayerWalking for ≥1s of consecutive checks rather than leaking on a single 0.25s-tick flicker between cutscene segments).
- **TCP reconnect FIXED.** `APIPCActor.Closed` was a one-line log — sidecar Ctrl+C left the mod silent for the rest of the session. Now `Closed()` clears `RecvBuffer` (any partial line is stale post-disconnect), sets `bWantsReconnect=True`, and schedules a 1s retry. `Timer()` calls `TryReconnect()` every 0.25s tick with exponential backoff (1s → 16s cap, reset to 1s on `Opened`). `PreBeginPlay`'s initial connect goes through the same path so a sidecar not yet running at game boot reconnects automatically.
- **Outbound AP-offline queue FIXED.** Pre-fix, sidecar's `_handle_game_line` dropped CHECK / CHECK_SPELL / CHECK_KEYITEM / GOAL_COMPLETE on the floor when `self.server` was None — fatal because `APCardMarker.Touch` self-destroys the marker so the location can't be re-checked by re-walking. New `pending_ap_outbound: list[dict]` in `HP2Context.__init__`, drained from `on_package("Connected")` via `_flush_pending_ap_outbound`. `_send_or_queue_ap_msg(msg, label)` is the single funnel for all four outbound message types. `goal_sent` refined: tracks "have we claimed the goal locally" (set on first `GOAL_COMPLETE` line), while AP delivery rides the queue so an AP outage during goal time still completes the slot on reconnect. In-memory only — a sidecar crash during an AP outage still loses queued checks. Disk persistence parked alongside bean durability (see `docs/DESIGN.md#v2-parking-lot`).
- **Mover-attached cards FIXED.** `MarkAsLoose` is now a no-op (was `PHYS_None`, which pinned the marker to world coords); the `Wait` state has a real `HitWall` that zeroes velocity on contact so the card settles on its surface instead of drifting, and movers carry it via collision. Chamber-II descending platform now carries `Card_Elphick` down correctly.
- **Chest persistence FIXED.** `TryReplaceCardSlot` bean-swaps slots to `class'Jellybean'` when `LocationChecked[id]==1` — for both vanilla `WCxxx` slots AND already-replaced `APCardMarker_xxx` slots (the latter happens on twin-level revisits where the cache restored our replacement). Plus: if a chest is in `bOpened` state but its slot still has an unchecked `APCardMarker`, the chest is reset (`bOpened=False`, `bProjTarget=class'chestbronze'.default.bProjTarget`, `eVulnerableToSpell=class'chestbronze'.default.eVulnerableToSpell`, `GotoState('waitforspell')`) so the player can re-open after walking away without picking up. Same for `bronzecauldron`.
- **Loose-icon persistence sorted.** Loose-spawned markers keep `bPersistent=True` (the vanilla default) via the `bIsLooseSpawn` flag — `MarkAsLoose` sets it, the deferred `Timer` skips `bPersistent=False` when it's set. Chest-spawned markers still go non-persistent so they don't stack on re-entry (the chestbronze.uc:163 `newSpawn.bPersistent = bMakeSpawnPersistent` stamp is overridden by our Timer next tick).

### What's left for v1 (M8)

All four classroom challenge blockers (Rictusempra / Skurge / Diffindo / Spongify) are implemented and verified. Spongify reuses the Rictusempra cutscene anchor at the shared DADA doorway, gated on `harry.iGameState >= 130` (post-Slytherin-Common-Room story beat) so it only spawns once vanilla would prompt the Spongify lesson.

Other M8 work: player-facing setup walkthrough, seed-gen smoke test, v1.0.0 release zip.

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
5. **One design question at a time, always recommend.** When uncertain, propose a default and ask.
6. **Stefan authors `data/logic.yaml`; you scaffold.** When new logic data is needed, ask him — don't guess from source.

---

## Where the project is

The project is **HP2PC_AP**, an Archipelago multiworld randomizer for *Harry Potter and the Chamber of Secrets* (PC, 2002 KnowWonder release), built on Metallicafan212's HP2Engine 3.4 (UE1 fork that restored UT99 IpDrv networking).

### Milestones

| Milestone | Status | What it proved |
| --- | --- | --- |
| M0 — Bootstrap | ✅ `48e3cac` | Repo + design docs |
| M1 — Hello-world mod | ✅ `929c493` | UScript toolchain works; `DefaultGame=` in `Game.ini` is the canonical entry point |
| M2 — TcpLink ping/pong | ✅ `cddb73f` | UScript ↔ Python bidirectional IPC over localhost:38281 |
| M3 — Card pickup round-trip | ✅ superseded by M6 APCardMarker | Initial card pickup path; replaced |
| M4 — Real AP integration | ✅ `302b27d` | Sidecar subclasses `CommonContext`; speaks real AP protocol |
| M5 — Full pool + hooks | ✅ `91ddc48`, `a167dfa`, `fcd68a5` | All grant types wired |
| M6 — Logic + seed gen | ✅ (this session) | 105 locations, 108 items, 38 per-location rules, fully solvable |
| M7 — Goal detection | ✅ (verified this session) | `bInEndGame` poll → `GOAL_COMPLETE` → AP slot completion |
| M8 — UX polish | ⏳ in progress | Bookcase blockers + vendor card rewrite + HUD toast done; setup doc + seed-gen test + release zip remaining |

### Card pickup architecture — APCardMarker

This is the *third* card-pickup iteration. Read `docs/DESIGN.md#card-pickup-architecture-apcardmarker` for the full rationale; here's the executive summary:

- **101 generated `APCardMarker_<ClassName>` UScript subclasses** (one per card). Each extends `APCardMarker` (which extends `WizardCardIcon`) and sets `CardLocationId` to the real card id (1..101).
- **Sentinel `Id=200`** in `APCardMarker` defaults so vanilla `harry.uc:977 / RemoveHarryOwnedCardsFromLevel(None)`'s `IsOwnedByHarry(class.Default.Id)` check never matches → markers immune to the level-entry bean-swap.
- **`APGameInfo.ReplaceCardChests()`** runs at every `InitGame`: iterates `chestbronze` (covers `ChestWood`/`ChestIron`/`ChestGold` via UE1 polymorphism), `bronzecauldron`, and loose `WizardCardIcon` actors. Bean-swaps slots to `Jellybean` when the location is already checked (mirrors vanilla `RemoveHarryOwnedCardsFromLevel`), otherwise swaps card-class slots / icons to the corresponding `APCardMarker_<X>`. For loose icons, `wci.Destroy()` happens BEFORE `Spawn(marker, ..., wci.Location)` because same-coords overlap causes UE1 to silently destroy the new actor and return None from `Spawn`. Tag and Base from the vanilla wci are copied onto the marker so the mover's PostBeginPlay `AttachTag` scan still picks the marker up (mover-carried cards like Chamber-II's Elphick).
- **`APCardMarker.Touch`** fires `CHECK <CardLocationId>` over IPC (via `class'APIPCActor'.static.GetInstance()`) and `Destroy()`. Does NOT call `SetCardOwner` (that path is reserved for the AP grant-application flow). Sets `class'APCardWatcher'.default.LocationChecked[CardLocationId]=1`.
- **`PostBeginPlay`** checks `LocationChecked[CardLocationId]` and self-destroys if already collected — re-entered levels don't re-spawn already-collected markers. Also schedules a one-shot `Timer` 0.05s later that sets `bPersistent=False` for chest-spawned markers (overrides `chestbronze.generateobject`'s `newSpawn.bPersistent = bMakeSpawnPersistent` stamp). Loose-spawned markers set `bIsLooseSpawn=True` in `MarkAsLoose` so the Timer skips the `bPersistent=False`.
- **`Wait` state** has its own `HitWall` that zeroes velocity — card settles flat on whatever it lands on instead of drifting (no more PHYS_None pinning).
- **`APGameInfo.TryApplyCard`** for AP grants: calls `MarkAsGranted(cardId)` to set `WasOwnedByHarry[id]=1` BEFORE `SetCardOwner(id, Harry)`, so the watcher's transition path doesn't fire an echo CHECK. Album updates via `WizardCards[50]` (the canonical store FEFolioPage reads).

### Detection (the 0.25s polling APCardWatcher)

Still in place as a safety net for any non-marker grant path (e.g., cutscene-scripted card grants):

- **Cards**: `APCardWatcher` polls `IsOwnedByHarry(id)` for ids 1–101 every 0.25s. On 0→1 transition (and not `WasOwnedByHarry[id]`), fires `CHECK <id>` and reverts `SetCardOwner(id, None)` if not `APGrantedCard[id]`.
- **Spells**: same watcher polls `harry.IsInSpellBook` for the 7 spells. AP-granted spells (`MarkSpellAsGranted`) preserved. Vanilla cutscene-granted spells are reverted (so the AP-placed item at the classroom location is the only spell granted).
- **Special progression items**: same watcher polls `nCount` on `StatusItemBoomslang/Bicorn/BitOGoyle`. v1 has these as vanilla-only (not AP items/locations), so the `CHECK_KEYITEM` calls fire but the sidecar's `KEYITEM_TO_LOCATION_NAME` is empty and silently skips. Will be revived in v2.
- **Goal**: polls `HPConsole(HarryRef.Player.Console).menuBook.bInEndGame` with a one-shot `WasInEndGame` guard. Fires `GOAL_COMPLETE` on False→True; sidecar relays as `ClientStatus.CLIENT_GOAL`.

### Grant application (in `APGameInfo.ApplyGrant`)

- **Cards** → `MarkAsGranted(id)` then `siCard.SetCardOwner(cardClass.default.Id, CardOwner_Harry)`. Does NOT call `RemoveHarryOwnedCardsFromLevel` (incompatible with marker architecture).
- **Spells** → `MarkSpellAsGranted(name)` then `harry.AddToSpellBookByString(name)`.
- **Key items** → `TryApplyKeyItem` is still present and idempotent (`AddBoomslang(1)` / `AddBicorn(1)` / `IncrementCount` for BitOGoyle), but AP will never deliver these in v1 because they're not in the item pool.
- **Beans** → `managerStatus.AddBeans(25/50/100)` for Small/Medium/Large.

## Setup on Stefan's machine

- Game install: `C:\Program Files (x86)\Harry Potter 2\Modded` (with M212 engine patched in). `Bingo` is the M212-bingo install, leave it alone.
- Repo: `C:\Users\kryen\Documents\Archipelago-play\Harry Potter 2 PC\HP2PC_AP`
- Archipelago framework checkout: `C:\Users\kryen\Documents\Archipelago-play\Archipelago` (sibling of the project)
- HP2 UScript decompile (NEW since last handoff): `C:\Users\kryen\Documents\Archipelago-play\Harry Potter 2 PC\HP2UScriptDecompile\` — read it for vanilla reference instead of WebFetching GitHub.
- The apworld lives at `Archipelago\worlds\harry_potter_2_pc\` — Stefan uses an `mklink /J` junction so edits in `apworld/` flow into the AP repo for live testing. (Renamed 2026-05-12 from `harry_potter_2` so future console ports — NGC/PS1/PS2/GBC — can claim their own world names without colliding.)
- Python 3.12 + asyncio + websockets via AP's `CommonClient`.
- UScript builds via `ucc make` in the Modded\System directory. **The script reports success even when the `.u` write fails** (game still running locks the file); always close the game before rebuilding, and if grants/checks behave like the old code, check `HPArchipelago.u` mtime vs source mtime.

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

`APIPCActor` survives level transitions via `bGameRelevant=True` + `bAlwaysRelevant=True` + class-default ref initialized in `PreBeginPlay` + `APGameInfo.InitGame` checks `APIPCActor.static.GetInstance()` before spawning. One TCP connection lasts the whole session. **Save-load (`ProcessServerTravel`) skips `APGameInfo.InitGame`** so always reach the singleton via `class'APIPCActor'.static.GetInstance()`, NOT `gi.IPCActor` (the post-save-load `gi.IPCActor` is None).

`APCardWatcher` is per-level (no `bGameRelevant`) but its class-default `LocationChecked[]` and `LatestInstance` survive across levels. `APGameInfo.FindActiveHarry` resolves harry through `APCardWatcher.GetLatest().Level.PlayerHarryActor` so the gameplay UWorld's harry is targeted (not Entry's). On save-load, the watcher's restored `bSnapshotted` is cleared by `EnsureLatestRegistration` so a re-Snapshot baselines the restored spellbook correctly.

## Known v1 limitations (parked for v2)

See `docs/DESIGN.md#v2-parking-lot` for full descriptions.

- **Boomslang / Bicorn / BitOGoyle as AP items/checks** — pulled from v1 pool (vanilla story progression). Reinstate when the mod-side trigger work is reliable (AP marker/icon at Boomslang and Bicorn pickup, end-of-Goyle touch for BitOGoyle).
- **Spell-challenge auto-transition + locked exit door** for Skurge / Diffindo / Spongify. v1 workaround: AP plando-places each spell at its own classroom and all four mod-side bookcase blockers (Rictusempra / Skurge / Diffindo / Spongify) prevent entry without the spell.
- **Save-load vs new-game distinction.** Currently no protection against loading a save from a different multiworld slot.
- Various v2 features: entrance shuffle, alt goal modes, Tier-3 check expansion (Quidditch matches, vendor purchases, dueling), trap items, etc.

## Read these in order on resume

1. `README.md` — project overview
2. `docs/ROADMAP.md` — milestone-by-milestone status
3. `docs/DESIGN.md` — every locked decision, including the APCardMarker architecture and the v2 parking lot
4. `docs/MOD_TODO.md` — UScript implementation checklist
5. `docs/DEV_SETUP.md` — toolchain commands
6. This file (you're reading it)

## Memory pointers

The `memory/` directory under `~/.claude/projects/.../` should auto-load via `MEMORY.md`. Includes Stefan's role/skill profile, the no-AI-attribution rule, short-commit rule, no-stop-recommending rule, HP2/M212 engine quirks, mod entry point, and the local-clone path for the UScript decompile.

If those don't appear in your initial context, the memory system is broken — flag it.

## First sanity check on resume

```powershell
git log --oneline -5
```

Should show the commits from the 2026-05-11 session: the big M6/M7/M8-progress bundle.

```powershell
ls docs/
```

Should show `DESIGN.md ROADMAP.md MOD_TODO.md DEV_SETUP.md AGENTS.md`.

## When unsure, ask Stefan

He'd rather you ask one specific question than guess and waste time. But spend up to a minute on read-only investigation first (grep, read existing files) so the question is specific.
