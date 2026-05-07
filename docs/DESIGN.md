# DESIGN — HP2PC_AP

Living design doc. Captures every decision made during design and the reasoning behind it. Update as decisions change. The v2 parking lot at the bottom collects deferred features.

---

## Game target

- **Game:** Harry Potter and the Chamber of Secrets, PC, 2002 EA / KnowWonder release.
- **Engine:** Unreal Engine 1 (KnowWonder fork). Modders use **Metallicafan212's custom engine** (`HP2Engine`), which restores UE1 networking from UT99 (`IpDrv.dll`) and ships `UnrealEd`, `UCC`, `UDebugger`. Players of the randomizer must use M212's engine, not stock KW.
- **Single version supported.** Multi-version support is out of scope.

## Architecture

```
[HP2 game on M212 engine]
  └─ HPArchipelago.u  (UnrealScript mod)
       └─ class'IpDrv.TcpLink'  →  localhost:38281
                                          │
                                          ▼
                           [Python sidecar — client/hp2_client.py]
                                          │
                                          ▼ WebSocket
                              [archipelago.gg server]
```

**No native code.** All game-side logic is UnrealScript. Python sidecar handles AP WebSocket. This was the architecture once we confirmed M212's engine has TcpLink available; before that, file-IPC was the fallback plan.

## Reference resources

- **Decompiled UScript source:** `https://github.com/metallicafan212/HP2UScriptDecompile` (cloned locally during design as `../uscript/`). Read-only reference.
- **Modding wiki:** `https://github.com/metallicafan212/HarryPotterUnrealWiki` and its GitHub Wiki.
- **M212 editor doc:** `https://docs.google.com/document/d/1b_AsvqQtcTTLohgOdXqTHbC-oK6-KsD5ZeBuX4Usw2A`
- **HP modding Discord:** `https://discord.gg/th3K6Epnug` — ask `Metallicafan212` and `AdamJD` for engine/UScript questions.
- **Built-in debug commands** (used during testing): `set HGame.baseConsole bDebugMode true`, F4 level select, F6 heal, F9 unlock all spells, `editactor class=X`, `savegame N` / `loadgame N`.

## Scope (v1)

- **Item shuffle** only. World layout, level connections, cutscenes unchanged. Entrance shuffle parked.
- **Open hub start.** Player spawns in Hogwarts grounds / castle entrance. Every level door is unlocked except where a hard key item gates it (BitOGoyle for Slytherin Common; spells for Chamber).
- **Levels (12 known so far):** Whomping Willow, Rictusempra Challenge, Skurge Challenge, Diffindo Challenge, Spongify Challenge, Forbidden Forest, Quidditch, Bicorn level, Boomslang level, Goyle level, Slytherin Common Room, Chamber of Secrets. To be cross-checked against the wiki + game in playtest.
- **Goal:** defeat Basilisk (`HGame/Classes/Bosses/Basilisk.uc`). Detected by overriding the Basilisk's death function.

## Items (111 unique, each appears once)

- **7 spells:** Alohomora, Diffindo, Flipendo, Lumos, Rictusempra, Skurge, Spongify.
- **101 wizard cards:** 50 Bronze + 40 Silver + 11 Gold (counts confirmed from decompile).
- **3 key items:** Boomslang, Bicorn, BitOGoyle.
- **FlobberMucus and WiggenBark are NOT key items** — they're potion ingredients buyable from NPCs, not progression. Excluded from the pool.

## Locations (~117+, to be enumerated in playtest)

- **4 spell-teaching classrooms** (sphere-0 — reachable with zero items).
- **12 level completions** (one per level).
- **101 wizard card pickups** (one per vanilla card location — needs cataloguing during playtest).
- **Possible extras:** mid-level checkpoints, NPC handoffs. Decide per-level during playtest.

## Sphere-0

The 4 spell-teaching classrooms are reachable with zero items. Generator places at least one progression spell at one of them. **No starting-spell YAML option needed** — sphere-0 unlocks itself via tutorial completion. (Earlier the design called for a `starting_spell` option; this was dropped once we realized the tutorials are sphere-0 checks.)

## Item delivery UX

- **Style:** Silent grant + AP-style HUD toast ("Received Flipendo from <player>").
- **Cards on receive:** play native `BronzePickup` / `SilverPickup` / `GoldPickup` FX (already in source). Set count = previous + 1, the existing `siCard.SetCardOwner(Id, CardOwner_Harry)` does the work.
- **Spells on receive:** spells have no native pickup FX, so reuse the **10-card-set celebration FX** (`BronzeStamina` for "you collected 10 bronzes" / `SilverUnlock` for silvers — both spawned by `WizardCardIcon.uc:104,117`).
- **Key items on receive:** silent + toast (no native FX needed).
- **Cutscene/menu safety:** items received during cutscenes, menus, level loads, Quidditch matches, etc. are queued. Drained one-per-~1.5s during safe states (Harry under player control, no menu open).

## Spell-teaching cutscenes

Lockhart's class and other spell tutorials become **AP checks**. Cutscene plays normally; instead of teaching the canonical spell, Lockhart "teaches you an Archipelago item" — the seed places whatever item there. Tutorial completion must NOT auto-transition into the matching challenge level (that's a separate AP region with its own checks). Mod intercepts and cancels the post-tutorial transition; player returns to wherever they were.

## Vendors

**Vendor card sales disabled in v1.** In vanilla, vendors sell missed cards for beans. With AP randomization, vendors selling cards would let the player short-circuit the multiworld. Since each level is now infinitely replayable, the player can always go back and find a card the seed placed somewhere.

## Logic graph

- **Lives in Python only**, in the AP world. Game side enforces nothing — vanilla obstacles already block progress (a Diffindo wall blocks until you have Diffindo; that's enough).
- **Granularity: per-location.** Every location has its own access rule, even if many will initially share the region's rule. Reason: precision, easier playtest iteration.
- **Authoring source of truth:** `data/logic.yaml`, hand-written by user. `scripts/gen_apworld.py` projects it into `apworld/rules.py`.
- **Iteration loop:** generate seed with `start_inventory_from_pool: all` (the AP "unlock everything" YAML option) → playtest → observe what blocks each location → encode in `data/logic.yaml` → regen apworld → repeat.

## IPC (game ↔ Python sidecar)

- **Transport:** raw TCP over localhost (port 38281 by default, configurable). UScript uses `class'IpDrv.TcpLink'`.
- **Protocol:** newline-delimited JSON. Each message has `{type, payload}`. Types are minimal in v1: `hello`, `ack`, `check_sent` (game→Python), `grant_item` (Python→game), `goal_complete` (game→Python).
- **Reconnection:** mod attempts reconnect on disconnect with exponential backoff. Items granted while disconnected are caught up on reconnect (the AP server is the source of truth — Python re-sends).

### Mod entry point

HP2/M212 do **not** honor stock UE1 mod hooks: `[Engine.GameEngine] ServerActors=` is silently ignored, and `?Mutator=` URL params are dropped during HP2's `Entry → gameplay-map` browse. The verified-working pattern (M1, 2026-05-07) is to subclass `Engine.GameInfo`:

```uscript
class APGameInfo extends GameInfo;

event InitGame(string Options, out string Error)
{
    local class<Actor> ipcClass;
    Super.InitGame(Options, Error);
    ipcClass = class<Actor>(DynamicLoadObject("HPArchipelago.APIPCActor", class'Class'));
    if (ipcClass != None) Spawn(ipcClass);
}
```

and register it via `DefaultGame=HPArchipelago.APGameInfo` in `Documents\Harry - Coding Evolved\Game.ini` under `[Engine.Engine]`. `event InitGame()` then fires once per level transition, where we spawn the IPC actor (and any other mod actors). Note: HP2's `GameInfo` is missing the stock `AddMutator(string)` function — KnowWonder stripped it. Use `DynamicLoadObject` + `Spawn()` directly.

## Save game persistence

- **AP server is source of truth.** When the Python client connects, it asks the server for the current items-received list and replays them to the mod via `grant_item`. The mod's `apply_item` is **idempotent** — granting Flipendo when Harry already has Flipendo is a no-op.
- **Saves work normally.** The native HP2 save game stores spells/cards/key items as it always has. If the player loads a save from before they joined the multiworld, the next sync from the server will re-apply everything they should have.

## Connection / setup UX

- **Standard AP pattern.** Player runs `python hp2_client.py` (or a packaged exe), which prompts for AP server URL + slot name + password, opens a localhost listener, then the player launches the game on M212's engine. Mod connects to localhost on map load.
- No bundled launcher in v1.

## Distribution

- **Manual zip release.** Each release contains: the apworld file, the compiled mod `.u`, the Python client, an install README pointing at M212's engine. Players install by hand. Ship a versioned zip per release.

---

## v2 parking lot

Features explicitly deferred from v1. Each of these came up during design and was scoped out to keep v1 shippable.

- **Entrance shuffle** — randomize the level-to-level graph (Floo destinations, etc.). Requires per-entrance/exit cataloguing, softlock prevention, possibly cutscene re-stitching. Big, separate piece of work.
- **Alternative goal modes** — selectable via YAML: "all gold cards (requires silver cards)", "mcguffin hunt". v1 = Basilisk only. Data structures should leave room for these without schema breakage.
- **Tier 3 check expansion** — Quidditch matches, dueling club, every collectible bean, hidden bean stashes, time trials. v1 sticks to cards + spells + key items + level completions.
- **Vendor card sales re-enabled (vanity only)** — vendors could sell duplicates of cards the player has already received from AP. Lore-flavorful, complicates economy. Defer.
- **Original spell-teaching cutscene replays for received spells (option B)** — replay Lockhart's full teach cutscene when AP grants you Flipendo. Considered, parked as flavor option.
- **Item-on-floor delivery (option D)** — spawn AP items as world pickups Harry walks over rather than instant grants. More immersive, more work.
- **Bundled launcher .exe** that orchestrates client + game start.
- **Native AP launcher integration** that auto-loads the apworld.
- **Trap items** — Cornish Pixie trap, Detention trap, etc. Optional YAML toggle.
- **Multiple version support** — different KW builds, different languages. v1 is single-version-locked.
- **Configurable starting spell** — was considered when sphere-0 was a problem. No longer needed since 4 classrooms are sphere-0. Could come back as a "skip the tutorials" mode.

---

## Open questions to resolve in playtest

1. Exact level list — does the wiki/community have a canonical list? Cross-check against the 12 above.
2. Which spells are taught in classrooms (the 4 sphere-0 locations), which in challenge levels, which by NPCs/books? Need to map for the spell-tutorial location names.
3. Per-card vanilla locations (which level each of the 101 cards lives in by default) — required for `data/locations.yaml`.
4. Whether `start_inventory_from_pool: all` actually works as expected with this APWorld, or whether we need a custom "give everything" YAML option.
5. Confirm that vanilla obstacles in HP2 really do hold the line in modded mode — i.e., a Flipendo block won't break for a player who lacks Flipendo just because the mod is loaded.
6. **Card-grant persistence into the album** (raised 2026-05-07 during M3). Calling `siCard.SetCardOwner(Id, CardOwner_Harry)` from a script — even via the full vanilla `WizardCardIcon.Touch` chain on a runtime-spawned card — writes the data correctly (verified by polling `IsOwnedByHarry`) but the entry is wiped by HP2 internal logic within milliseconds. Re-reading the same `StatusItemBronzeCards` instance from the same harry's `managerStatus` after the wipe shows `nCount=0` even though the watcher saw the card a tick earlier. Theory: HP2 keeps a separate "official" cards store and re-syncs `WizardCards[]` from it during normal gameplay events; only cards added via the canonical pickup-with-save path enter the official store. Need M212 Discord input on the canonical hook for AP-style scripted grants. This affects: card-as-key-item progression, the album, and any goal logic that reads card ownership.
6. **Save-load vs new-game distinction** (raised 2026-05-07 during M2 testing). Each level transition currently spawns a fresh `APIPCActor` and reconnects, regardless of whether it's a new game or a save load. The connection itself is cheap and always-on is correct. The real concern is **item state**: if the player loads a vanilla save (or a save from a *different* multiworld slot), the local save has items the AP server didn't grant, or is missing items the server *did* grant. Open sub-questions:
    - Tag saves with the AP slot name on first connect, refuse to sync if the connected slot doesn't match the save's tag?
    - Alternatively: trust local save state for "checks already collected" but still re-apply server's `grant_item` list (idempotent) on every level load. Combined-state model.
    - What does the player see when they load a save that doesn't match the connected slot? Big toast, refuse to grant, refuse to send checks, just print a warning?
    Decide before M3 (one-card round-trip) so the IPC protocol can carry the slot tag from the start.
