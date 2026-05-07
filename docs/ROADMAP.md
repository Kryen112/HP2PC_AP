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
- `data/items.yaml` (114 entries: 7 spells + 3 key items + 101 cards + 3 filler tiers) and `data/locations.yaml` (117 entries: 4 classrooms + 12 level completions + 101 card locations).
- `scripts/gen_apworld.py` — reads `data/*.yaml`, validates uniqueness + cross-references, emits `apworld/items.py` and `apworld/locations.py`. Includes hardcoded `CARD_GAME_ID_TO_CLASS` map extracted from `StatusItemWizardCards.GetCardClassFromId`.
- `apworld/__init__.py` refactored to consume the generated modules; full pool seeds generate cleanly under AP 0.6.5.
- Sidecar uses real `card_game_id → AP location` and `AP item name → UScript class` mappings, with grant-echo deduplication so a sidecar GRANT doesn't trigger an infinite cascade via the watcher's re-detection.
- `APCardWatcher` polls cards (via `IsOwnedByHarry`), spells (via `harry.IsInSpellBook`), and key items (via `StatusItemBoomslang/Bicorn/BitOGoyle.nCount` in `StatusGroupPolyIngr`). Initial-snapshot baselines starter spells (Lumos/Flipendo/Alohomora) so cutscene-grants don't fire as fake CHECKs.
- `APIPCActor` sends differentiated `CHECK <int>` (cards), `CHECK_SPELL <name>`, `CHECK_KEYITEM <name>`.
- `APGameInfo.ApplyGrant` handles four grant types: cards (via `Spawn`+`Touch` chain), spells (via `harry.AddToSpellBookByString`), key items (via `managerStatus.AddBoomslang/AddBicorn` and `IncrementCount` for BitOGoyle), and filler beans (via `managerStatus.AddBeans` with 25/50/100 per tier).

**Deferred to M6:**
- AP location mapping for `CHECK_SPELL` (which classroom location does each spell-tutorial map to?) and `CHECK_KEYITEM` (which level location holds each key item?). Sidecar logs these but doesn't yet send `LocationChecks` for them — the mapping needs playtest data.
- Spell-start-state policy (DESIGN.md open question 7).

**De-risks:** the data pipeline. After M5, adding/changing items is a YAML edit + regen.

## M6 — Logic and seed generation

**Goal:** generated seeds are solvable end-to-end.

- Author `data/logic.yaml` per-location (start with region-coarse, refine over playtests).
- `scripts/gen_apworld.py` emits `apworld/regions.py` and `apworld/rules.py`.
- Add YAML option `goal: basilisk` (the only option in v1).
- Run AP generator with `start_inventory_from_pool: all` ("unlock everything") seed for testing — confirm every location is reachable.
- First real seed: play a normal seed start-to-finish solo. Find broken logic; fix; regen; repeat.

**De-risks:** the AP world correctness.

## M7 — Goal detection + endgame

**Goal:** finishing a seed is recognized as such.

- `APGoalDetector.uc` — hook the Great Hall post-Basilisk entry (the speedrun endpoint that naturally triggers the credits cutscene), send `{"type":"goal_complete"}`. Not the Basilisk's death function — that fires mid-cutscene before the run is genuinely complete.
- Sidecar reports goal to AP server.
- Test: play a seed, kill Basilisk, walk into the Great Hall, confirm AP server marks slot complete.

## M8 — UX polish

**Goal:** v1 ships.

- HUD toast actor (`APHUDToast.uc`) — on-screen "Received X from Y" notification, queued, drains during safe states.
- Card-receive plays native pickup FX. Spell-receive reuses 10-card-set celebration FX.
- Vendor card sales disabled.
- Levels confirmed re-entrable.
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
