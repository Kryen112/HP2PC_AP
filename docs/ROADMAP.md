# ROADMAP — HP2PC_AP

Milestone-by-milestone plan toward shipping v1. Each milestone is a single demoable thing. Don't skip ahead — earlier milestones de-risk later ones.

---

## M0 — Bootstrap (this commit)

Done. Repo, design docs, items catalog, location skeleton, mod TODO list.

## M1 — Hello-World mod

**Goal:** prove the toolchain works end-to-end with a trivial mod.

- Install M212's HP2Engine on the dev machine and reproduce the `image_from_metellicafan.png` System folder.
- Add a trivial `HPArchipelago/Classes/HelloMutator.uc` that prints `"Archipelago: hello"` to the log on level load.
- Compile via `ucc make` against M212's engine. Get `HPArchipelago.u` built.
- Add `HPArchipelago` to `EditPackages` in `default.ini`. Launch HP2, confirm the log line appears.
- Document the build steps in `docs/DEV_SETUP.md`.

**De-risks:** the entire UScript toolchain.

## M2 — TcpLink ping/pong

**Goal:** prove UScript can talk to a Python process.

- Write `client/hp2_client.py` as a stub: opens TCP listener on `localhost:38281`, prints any line received, can send back a line on stdin.
- Add `APIPCActor.uc` — uses `class'IpDrv.TcpLink'` to connect to localhost. On connect, sends `{"type":"hello"}\n`. On any received line, log it.
- Test bidirectional: launch sidecar, launch game, confirm `hello` appears in sidecar, type a line in sidecar, confirm it appears in game log.
- Add reconnect-on-disconnect with capped backoff.

**De-risks:** networking layer. Once this works, the rest is data plumbing.

## M3 — One card round-trip

**Goal:** the smallest possible AP-style flow, no AP server yet.

- Subclass `BronzeCards`/`SilverCards`/`Goldcards` in the mod. Override `Touch()` to send `{"type":"check_sent","card_id":<Id>}` over IPC, then call `Super.Touch()` so vanilla pickup proceeds.
- Add a fake "AP server" mode in `hp2_client.py` that, on receiving `check_sent`, immediately replies `{"type":"grant_item","item":"WCAgrippa"}`.
- In the mod, implement `APItemReceiver`. On `grant_item` for a card, call `siCard.SetCardOwner(Id, CardOwner_Harry)` for that card.
- Test: pick up Card A in-game; sidecar logs the check; sidecar grants Card B; verify Card B appears in album.

**De-risks:** card-pickup hook + idempotent grant.

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
