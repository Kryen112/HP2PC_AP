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

## M3 — One card round-trip ✅ (commit 5cedc10) — with open question

**Goal:** the smallest possible AP-style flow, no AP server yet.

**Done:**
- `APCardWatcher` polls all 3 status tiers every 0.25s and fires `CHECK <id>` on diff. Catches every grant pathway (cutscene, chest, walk-over). Verified for Hesper Starkey (cutscene, id=7) and Joscelind Wadcock (chest, id=36).
- Sidecar test mode: skip first CHECK, auto-reply `GRANT WCAgrippa` to second.
- `APGameInfo.ApplyGrant` parses `GRANT <classname>`, spawns the card class at Harry, fires `cardActor.Touch(harry)` to invoke the full vanilla pickup chain.
- Watcher confirms the SetCardOwner write via re-detection (CHECK fires for the granted Id).

**Open question (asked on M212 Discord):** HP2 wipes `WizardCards[]` between operations. Same StatusItem instance, same harry, polled before vs after — different data. The album reads the wiped state, so AP-granted cards don't appear in the album yet. Round-trip wire is fully proven; album persistence is the unresolved part. See `docs/DESIGN.md` open question 6 and the `project_hp2_card_grant_persistence` memory.

## M4 — Real Archipelago integration

**Goal:** speak the real AP protocol against `archipelago.gg`.

- Build minimal `apworld/` — 1 region (Hub), 1 location (TestCard), 1 item (TestSpell), goal = collect TestSpell.
- Pin AP framework version (e.g. `Archipelago 0.5.x`); document in `docs/DEV_SETUP.md`.
- Replace the stub server in `hp2_client.py` with a real AP WebSocket client (using AP's Python SDK).
- Generate a real seed against your apworld; connect with the client; verify pickup flow works against a real server.

**De-risks:** AP framework integration.

## M5 — Items: full pool

**Goal:** all 111 items + locations addressable in code.

- Author `data/items.yaml` (101 cards + 7 spells + 3 key items, each with stable AP item ID, classification = progression / useful / filler).
- Author skeleton `data/locations.yaml` (~117 entries, region = Unknown until playtest).
- Implement `scripts/gen_apworld.py` — reads `data/*.yaml`, emits `apworld/items.py` and `apworld/locations.py`.
- Implement spell hooks (`APSpellHook.uc`): spell-tutorial completion fires `check_sent`, blocks the post-tutorial level transition.
- Implement key-item hooks (`APKeyItemHook.uc`): Boomslang/Bicorn/BitOGoyle pickups fire `check_sent`.
- Beans filler items added.

**De-risks:** the data pipeline. After M5, adding/changing items is a YAML edit.

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

- `APGoalDetector.uc` — subclass `Basilisk`, override death function, send `{"type":"goal_complete"}`.
- Sidecar reports goal to AP server.
- Test: play a seed, kill Basilisk, confirm AP server marks slot complete.

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
