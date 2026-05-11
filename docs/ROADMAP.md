# ROADMAP — HP2PC_AP

Milestone-by-milestone plan toward shipping v1. Each milestone is a single demoable thing. Don't skip ahead — earlier milestones de-risk later ones.

---

## M0 — Bootstrap ✅ (commit 48e3cac)

Done. Repo, design docs, items catalog, location skeleton, mod TODO list.

## M1 — Hello-World mod ✅ (commit 929c493)

**Goal:** prove the toolchain works end-to-end with a trivial mod.

Done. Toolchain proven via `APGameInfo` subclass + `DefaultGame=` registration. Stock UE1 hooks (`[Engine.GameEngine] ServerActors=`, `?Mutator=` URL) confirmed dead in HP2/M212; the working entry point is documented in `docs/DESIGN.md#mod-entry-point`. `docs/DEV_SETUP.md` covers the build/run loop and gotchas.

## M2 — TcpLink ping/pong ✅ (commit cddb73f)

**Goal:** prove UScript can talk to a Python process.

Done. `APIPCActor` extends `IpDrv.TcpLink` with hardcoded 127.0.0.1, persists across level transitions via singleton + `bGameRelevant=True`/`bAlwaysRelevant=True`. Sidecar (`client/hp2_client.py`) is an accept-loop, multi-thread reader/writer Python stub. Bidirectional traffic verified.

## M3 — One card round-trip ✅ (commit 5cedc10)

**Goal:** the smallest possible AP-style flow, no AP server yet.

**Done:**
- `APCardWatcher` polls all 3 status tiers every 0.25s and fires `CHECK <id>` on diff. Catches every grant pathway (cutscene, chest, walk-over). Verified for Hesper Starkey (cutscene, id=7) and Joscelind Wadcock (chest, id=36).
- Sidecar test mode: skip first CHECK, auto-reply `GRANT WCAgrippa` to second.
- `APGameInfo.ApplyGrant` parses `GRANT <classname>` and applies the card directly via `siCard.SetCardOwner(Id, CardOwner_Harry)` + `sgCards.RemoveHarryOwnedCardsFromLevel(None)` — bypassing the spawn-and-Touch chain (whose `CanPickupNow` precondition was short-circuiting before line 131 of vanilla `WizardCardIcon.Touch`). Album persistence confirmed; M212 Discord answer (2026-05-07) pointed at the missing `RemoveHarryOwnedCardsFromLevel` call.
- Watcher confirms the SetCardOwner write via re-detection (CHECK fires for the granted Id).

> **Superseded in M6.** The watcher-as-primary-card-detector path and the `RemoveHarryOwnedCardsFromLevel`-based grant flow were replaced by `APCardMarker` (chest/cauldron/loose-icon swap with `MarkAsGranted` echo-suppression). The watcher still polls as a safety net for cutscene grants. Current behaviour is in `docs/DESIGN.md#card-pickup-architecture-apcardmarker` and `docs/MOD_TODO.md`.

## M4 — Real Archipelago integration

**Goal:** speak the real AP protocol against `archipelago.gg`.

- Build minimal `apworld/` — 1 region (Hub), 1 location (TestCard), 1 item (TestSpell), goal = collect TestSpell.
- Pin AP framework version (e.g. `Archipelago 0.5.x`); document in `docs/DEV_SETUP.md`.
- Replace the stub server in `hp2_client.py` with a real AP WebSocket client (using AP's Python SDK).
- Generate a real seed against your apworld; connect with the client; verify pickup flow works against a real server.

**De-risks:** AP framework integration.

## M5 — Items: full pool ✅ (commits 91ddc48, a167dfa, fcd68a5)

**Goal:** all 111 items + locations addressable in code, both directions wired.

**Done:**
- `data/items.yaml` (114 entries: 7 spells + 3 special progression items + 101 cards + 3 filler tiers) and the v1 location model (108 checks: 4 classrooms + 101 card locations + Boomslang/Bicorn/BitOGoyle special checks).
- `scripts/gen_apworld.py` — reads `data/*.yaml`, validates uniqueness + cross-references, emits `apworld/items.py` and `apworld/locations.py`. Includes hardcoded `CARD_GAME_ID_TO_CLASS` map extracted from `StatusItemWizardCards.GetCardClassFromId`.
- `apworld/__init__.py` refactored to consume the generated modules; full pool seeds generate cleanly under AP 0.6.5.
- Sidecar uses real `card_game_id → AP location` and `AP item name → UScript class` mappings, with grant-echo deduplication so a sidecar GRANT doesn't trigger an infinite cascade via the watcher's re-detection.
- `APCardWatcher` polls cards (via `IsOwnedByHarry`), spells (via `harry.IsInSpellBook`), and key items (via `StatusItemBoomslang/Bicorn/BitOGoyle.nCount` in `StatusGroupPolyIngr`). Initial-snapshot baselines starter spells (Lumos/Flipendo/Alohomora) so cutscene-grants don't fire as fake CHECKs.
- `APIPCActor` sends differentiated `CHECK <int>` (cards), `CHECK_SPELL <name>`, `CHECK_KEYITEM <name>`.
- `APGameInfo.ApplyGrant` handles four grant types: cards (via `Spawn`+`Touch` chain), spells (via `harry.AddToSpellBookByString`), key items (via `managerStatus.AddBoomslang/AddBicorn` and `IncrementCount` for BitOGoyle), and filler beans (via `managerStatus.AddBeans` with 25/50/100 per tier).

> **Cards path superseded in M6.** The `Spawn`+`Touch` chain for card grants was replaced by `MarkAsGranted` + direct `siCard.SetCardOwner` write (no Spawn, no Touch, no celebration cutscene). Spell / key item / bean grant paths described above remain current. See `docs/DESIGN.md#card-pickup-architecture-apcardmarker`.

**Deferred to M6:**
- AP location mapping for `CHECK_SPELL` (which classroom location does each spell-tutorial map to?) and the three special pickup/interact checks. Sidecar logs these but doesn't yet send `LocationChecks` for them — the mapping needs playtest data.
- Spell-start-state policy (DESIGN.md open question 7).

**De-risks:** the data pipeline. After M5, adding/changing items is a YAML edit + regen.

## M6 — Logic and seed generation ✅ (committed through 2026-05-11)

**Goal:** generated seeds are solvable end-to-end.

**Done:**
- `data/logic.yaml` schema authored (string-grammar `requires`, `Lumos & Flipendo | Alohomora`-style). Region list + classroom locations populated. Card per-location overrides empty for now (Stefan fills as playtest catalogues card homes).
- `scripts/gen_apworld.py` emits `apworld/regions.py` (region defs + entry rules), `apworld/rules.py` (per-location overrides + goal definition), and 101 `mod/HPArchipelago/Classes/APCardMarker_<X>.uc` subclasses for the chest-replacement architecture.
- `apworld/__init__.py` wires region entry rules into `Region.connect(... rule=...)`. Goal generation uses the Basilisk spell requirement from `logic.yaml`; runtime completion signal is `GOAL_COMPLETE`.
- Goal `basilisk` declared in `logic.yaml`; default goal in `__init__.py`. (YAML option for choosing goal is parked v2.)
- TBD-lenient mode: rules with `entry: TBD` compile to `True` so seeds gen during playtest. Generator prints a warning listing unfilled regions.
- Card-pickup architecture rewritten — `APCardMarker_<X>` replaces every card class in chests/cauldrons/loose-icon spots at level entry. Markers fire CHECK on Touch, no `SetCardOwner`, no celebration cutscene. See `docs/DESIGN.md#card-pickup-architecture-apcardmarker`.

**Done (2026-05-09):**
- AP common-options support: `HP2World.options_dataclass = HP2Options(PerGameCommonOptions)` adds `start_inventory_from_pool: StartInventoryPool` (not in vanilla `PerGameCommonOptions`). Still useful for playtest YAMLs; v1 starter spells are now mandatory precollected items.
- `HP2World.get_filler_item_name()` returns a random `FILLER_NAMES` choice. Default would pick any item name including cards, producing duplicate `Card_X: <existing-card>` placements when the pool shrinks (e.g. via start_inventory_from_pool).
- `tests/HP2_Test.yaml` configured for solo playthrough: starter spells are precollected by the APWorld, 4 non-starter spells plando'd at their classrooms (spell-challenge-softlock workaround), Card_*-level placements all random.
- `scripts/gen_seed.ps1` now reads from the repo's `tests/` (was reading a stale copy in `Archipelago\hp2_only_players\`). Single source of truth.
- Sidecar quality-of-life: INFO logs now visible (`logging.basicConfig` not just `setLevel`); items received before the game connects are queued and drained on game connect (was warning + dropping); graceful Ctrl+C (skip `wait_closed()` plus loop-level `ConnectionResetError` filter); `pkg_resources` deprecation warning silenced.

**Done (2026-05-10):**
- Removed level-completion locations/rules from source data and generated APWorld output.
- Added `Special_Boomslang`, `Special_Bicorn`, and `Special_BitOGoyle` checks.
- Updated the generator to treat `special_checks` as a first-class location category and to support direct goal logic rules.
- Updated the sidecar special-item mapping to send Boomslang/Bicorn/BitOGoyle checks to the new special locations.
- Moved Lumos/Flipendo/Alohomora into mandatory APWorld precollection so the 111 unique non-filler items fit the 108-location v1 model.
- Verified AP generation under the 108-check model; `Generate.py` fills 104 random items after 3 precollected starter spells and 4 classroom plandos.

**Done (2026-05-11):**
- All 18 region entry rules authored with full spell-chain requirements (Alohomora explicitly listed where it's required, in anticipation of a future "Alohomora-not-starter" YAML option).
- All 101 cards have a region in `data/locations.yaml` (one — Card_Sykes — was caught as a typo in original cataloguing and corrected).
- 38 per-location override rules cover the cards/classrooms whose requirements differ from their region entry.
- Boomslang / Bicorn / BitOGoyle removed from the AP item/location pool — v1 lets them flow through vanilla story progression. Pool is now 108 items / 105 checks (was 111/108).
- Day/night unified — no separate `HogwartsNight` region (Castle-Exterior cards reachable in either daylight or night version of Grounds_hub).
- Gold-card chest locations forbidden from receiving Silver-card items via `add_item_rule` (prevents 40-silver-to-unlock-gold-chest circular dependency).
- Spell-challenge softlock workaround: each non-starter spell is plando'd at its own classroom + bookcase blocker class (Rictusempra-only implemented mod-side; Skurge/Diffindo/Spongify bookcase blockers are M8 work).

**Deferred to v2 (see `docs/DESIGN.md#v2-parking-lot`):**
- Boomslang/Bicorn/BitOGoyle as AP checks + items.
- Spell-challenge softlock proper fix (unlock the exit door via UScript so spells can land elsewhere).
- Quidditch matches and vendor-purchases as Tier-3 checks.

**De-risks:** the AP world correctness.

## M7 — Goal detection + endgame ✅ (verified 2026-05-11)

**Goal:** finishing a seed is recognized as such.

**Done:**
- `APIPCActor.SendGoalComplete()` adds a one-shot `GOAL_COMPLETE` IPC line.
- `APCardWatcher.Timer()` polls `FEBook.bInEndGame` (set True by `ShowCredits` at `FEBook.uc:1392` when the post-Basilisk credits cutscene runs) via `HPConsole(HarryRef.Player.Console).menuBook`, fires `SendGoalComplete()` on False→True transition with a `WasInEndGame` one-shot guard. Reuses the existing 0.25s timer rather than adding a separate `APGoalDetector` actor — the original plan's standalone-actor design folded into the watcher because the access pattern is identical.
- Sidecar `_handle_game_line` adds a `GOAL_COMPLETE` branch that sends `{"cmd": "StatusUpdate", "status": ClientStatus.CLIENT_GOAL}` to the AP WebSocket, with a `goal_sent` dedupe flag for defence-in-depth.

**Verified 2026-05-11:** post-Basilisk Great-Hall walk-in (cutscene skipped) fires `bInEndGame=True`, mod sends `GOAL_COMPLETE`, sidecar relays `ClientStatus.CLIENT_GOAL` to the AP server, AP releases items and marks the slot complete. End-to-end working.

**De-risks:** end-of-run signal correctness.

## M8 — UX polish ⏳ in progress

**Goal:** v1 ships.

**Done (2026-05-11 series):**
- Mover-attached cards follow movers (Chamber-II descending platform: Card_Elphick rides down).
- Chest persistence: opened chest + collected card → chest stays open with Jellybean on re-entry (vanilla post-pickup parity); opened + not collected → chest resets to closed-and-spell-vulnerable so the player can try again (no softlock).
- Loose-icon persistence: marker survives via cache for unpicked loose cards; on twin-level pickup the cached marker self-destroys via `PostBeginPlay`'s LocationChecked guard.
- Twin-level card chests (Wadcock day/night): once picked up on either side, the other side bean-swaps to Jellybean.
- IPC robustness: `ReceivedText` now buffers across TCP chunks so multi-line packets aren't truncated; `APIPCActor.GetInstance()` singleton accessor used everywhere (save-load resilient); sidecar `game_writer` race fixed on reconnect.
- Save-load spell-revert fix: `APCardWatcher.EnsureLatestRegistration` clears `bSnapshotted` so the post-save-load instance re-snapshots before its revert loop runs, preventing the "Flipendo/Lumos/Rictusempra/Skurge wiped after save reload" bug.
- **Playable-state grant gate.** `APGameInfo.IsPlayerInPlayableState(harry, out reason)` is now the authoritative "Harry is actually playing" check called from `APIPCActor.TryDrainPendingGrants` after the existing `Level.Pauser` / `FindGrantReadyHarry` / `watcher.bSnapshotted` gates. Whitelists `harry.GetStateName()=='PlayerWalking'` only (`PlayerSwimming` not used in v1; every other state — `stateCutIdle`, `SpellLearning`, `harryfrozen`, `stateDead`, `GameEnded`, `exittoMenu`, `stateInactive`, `Mounting`/`MountFinish`, Quidditch, dueling, `statePickupItem`, `statePotionMixing*`, `wingspell`, `LookAtActor`, `ChessDeath`, `CelebrateCardSet`, etc. — defers). Also rejects `bIsCaptured` (Filch/Snape capture), `bKeepStationary` (vendor engagement), and `HPHud(myHUD).IsCutSceneOrPopupInProgress()` (covers the tick window between cutscene start and `stateCutIdle` transition, and cutscene-skip border animation). Removed the previous 8s post-connect warmup — every condition it was hedging against (watcher not yet snapshotted, loading-screen leak, post-load cutscene, resync flood) is now explicitly gated by either this helper or the pre-existing checks plus the 0.75s drain spacing.
- **IPC reconnect resilience.** Sidecar terminal closes / crashes used to leave the mod silent for the rest of the session — `APIPCActor.Closed` was a one-line log. Now `Closed()` clears `RecvBuffer` (any partial line is stale post-disconnect), sets `bWantsReconnect=True`, and schedules `TryReconnect` via the existing 0.25s Timer with exponential backoff (1s → 16s cap, reset to 1s on `Opened`). `PreBeginPlay`'s initial connect now goes through the same `TryReconnect` path so a sidecar not yet running at game boot reconnects automatically when it comes up.
- **Outbound AP-offline queue.** Previously the sidecar dropped CHECK / CHECK_SPELL / CHECK_KEYITEM / GOAL_COMPLETE on the floor when `self.server` was None, with no recovery — fatal because `APCardMarker.Touch` self-destroys the marker so the location can't be re-checked by re-walking. New `pending_ap_outbound: list[dict]` in `HP2Context.__init__`, drained from `on_package("Connected")` via `_flush_pending_ap_outbound`. `_send_or_queue_ap_msg(msg, label)` is the single funnel for all four outbound message types. `goal_sent` semantic refined: tracks "have we claimed the goal locally" (set immediately on first `GOAL_COMPLETE` line), while the actual AP delivery rides the queue so an AP outage during goal time still completes the slot on reconnect. In-memory only; disk persistence parked alongside bean durability (see `docs/DESIGN.md#v2-parking-lot`).

**Still TODO:**
- **Bookcase challenge blocks** for Skurge / Diffindo / Spongify classrooms (Rictusempra bookcase already implemented and verified). Spongify shares the DADA room with Rictusempra so its blocker needs a different approach (gate the auto-teleport into the spell challenge, not the room entry).
- HUD toast actor (`APHUDToast.uc`) — on-screen "Received X from Y" notification, queued, drains during safe states.
- Vendor card sales disabled.
- Player-facing `docs/PLAYER_SETUP.md` walkthrough.
- `tests/test_generation.py`: "100 seeds generate without error".
- Tagged `v1.0.0` GitHub release zip.

---

## Estimated effort

This is a hobby project; estimates are wide. Roughly:

- M1–M4 (proving the stack): 2–4 weeks of evenings.
- M5–M6 (the bulk — data + logic + playtests): 1–3 months. Logic authoring is the long pole.
- M7–M8 (polish + ship): 2–4 weeks.

Total to v1.0.0: roughly **3–5 months of evenings/weekends**. The risk is logic iteration in M6; budget extra there.

## What you do NOT do during v1

See `docs/DESIGN.md#v2-parking-lot`. If a feature there starts to feel essential mid-v1, push back hard — most won't be.
