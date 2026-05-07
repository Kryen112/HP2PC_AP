# Handoff — written 2026-05-07 (updated end-of-day 2026-05-07)

This file is for the next Claude that boots into this repo. Read it top-to-bottom before doing anything else. The previous Claude wrote it after a long session that took the project from M0 design docs to a working M5 with end-to-end Archipelago integration.

---

## ⚠️ IN-FLIGHT, UNTESTED — read before touching anything

Two changes landed end-of-day 2026-05-07 on a Python-less laptop with no game install. Neither has been compiled or playtested. Before doing anything else next session, work through both.

### Change 1: M3 card-album persistence fix (`mod/HPArchipelago/Classes/APGameInfo.uc`)

M212 Discord pointed at `WizardCardIcon.uc:131`. Card-grant path was rewritten from `Spawn(class) + cardActor.Touch(harry)` to a direct `siCard.SetCardOwner(cardClass.default.Id, CardOwner_Harry)` + `sgCards.RemoveHarryOwnedCardsFromLevel(None)`.

Verification:

1. `ucc make` in `Modded\System` — confirm the new `TryApplyCard` and the trimmed `ApplyGrant` compile cleanly. Locals removed from `ApplyGrant`: `cardClass`, `cardActor`, `spawnLoc`, `attempt`. Class refs needed: `WizardCardIcon`, `StatusItemWizardCards`, `StatusGroupWizardCards`, `StatusItemBronzeCards`, `StatusItemSilverCards`, `StatusItemGoldcards`, `BronzeCards`, `SilverCards`, `Goldcards`. If `ucc` complains about unresolved class refs, add the appropriate package to `EditPackages=` or fully-qualify with `HGame.<Class>`.
2. Run a real seed and have AP grant a card. Open the album. **Confirm the granted card actually appears.** If yes, this milestone closes; commit the changes (commit message ≤25 words, no AI attribution). If no, the fix is wrong — the grant log line `[Archipelago] ApplyGrant: granted card …` should still appear but the album won't update. In that case re-open DESIGN open question 6.
3. Side-effect to watch for: `RemoveHarryOwnedCardsFromLevel(None)` walks all `WizardCardIcon` actors in the current level and destroys Harry-owned ones. That's the same call `harry.uc:977` makes on level entry, so it should be safe — but if a player picks up a vanilla card and *then* AP grants a different card, other in-level card icons Harry already owns will vanish. Check the play feel.

### Change 2: spell + key-item → AP location wiring (`data/locations.yaml`, `client/hp2_ap_client.py`, `docs/MOD_TODO.md`)

Stefan provided the v1 story progression. Mapping authored:
- `data/locations.yaml` classroom entries renamed to one per non-starter spell: `Classroom_Lockhart_Rictusempra` (offset 1), `Classroom_Flitwick_Skurge` (offset 2), `Classroom_Sprout_Diffindo` (offset 3), `Classroom_Lockhart_Spongify` (offset 4). The previous `Classroom_Snape` (Potions) was dropped — Snape teaches Wiggenweld brewing, not a spell. Total location count unchanged at 117.
- `client/hp2_ap_client.py` got `SPELL_TO_LOCATION_NAME` (4 entries) and `KEYITEM_TO_LOCATION_NAME` (3 entries: Boomslang/Bicorn/BitOGoyle → respective `LevelClear_*Level`). The two `CHECK_SPELL` / `CHECK_KEYITEM` handlers now route through a shared `_send_named_location_check` helper that mirrors the existing card-CHECK flow (validate AP connection, look up location id, dedupe via `checked_locations_seen`, send `LocationChecks`).
- Lumos/Flipendo/Alohomora intentionally have no entry in `SPELL_TO_LOCATION_NAME` — they're starter cutscene spells, baselined in the watcher's initial snapshot, never fire `CHECK_SPELL`. They must be placed as start-inventory by the seed (intersects open question 7 — make the call before M6 logic).
- The 3 ingredient levels (Boomslang/Bicorn/Goyle) get their `LevelClear_*` checks via the key-item pickup hook — design call from Stefan: pickup IS level-end, one check not two. The other 9 level-clears still need a dedicated hook (now a fresh open todo at `MOD_TODO.md`).

Verification:

1. **Regen the apworld:** `py -3.12 scripts\gen_apworld.py` from the repo root. Should succeed; the validator will catch any duplicate ids/names. The 4 renamed classrooms keep their original `id_offset` values (1–4), so existing test seeds remain compatible.
2. **Test seed:** generate a fresh seed, connect both clients. Walk Harry through Lockhart's first class to learn Rictusempra. Sidecar should log `Sent LocationChecks for Classroom_Lockhart_Rictusempra` and the AP server should mark that location collected.
3. **Repeat** for Flitwick (Skurge), Sprout (Diffindo), Lockhart#2 (Spongify), and the 3 ingredient pickups.
4. **Watch for** `Game spell 'Lumos' has no AP location mapping (likely starter / non-progression); skipping` — that line firing means the starter-spell snapshot is somehow leaking; investigate the `APCardWatcher` baseline if so. It should normally never appear.

If both changes pass, delete this entire `IN-FLIGHT` section and let the rest of the doc stand.

---

## Who you're working with

**Stefan Kuppen** (`stefan.kuppen@indi.nl`, GitHub: `Kryen112`).

- Solid AP Python knowledge — has contributed to AP randomizers before.
- Zero UnrealScript experience before this project; learned a lot during M1–M5.
- Zero C/C++ / reverse-engineering experience. The architecture intentionally avoids native code.

### Hard rules (saved as feedback memories — do not violate)

1. **Commit messages: 10–25 words, single sentence.** Any longer and Stefan will push back.
2. **Never put your name (Claude / AI) under a commit.** No `Co-Authored-By: Claude` trailers, ever. Stefan force-pushed once to remove one — don't make him do it again.
3. **Never recommend stopping based on time of day.** Stefan codes long hours and finds "want to stop here for the night?" prompts annoying. If a milestone wraps up, ask "what's next?" not "want to stop?".
4. **Be terse.** Don't trail responses with summaries — Stefan can read the diff.

These are in `~/.claude/projects/.../memory/` already; you should see them load automatically.

## What exists right now

The project is **HP2PC_AP**, an Archipelago multiworld randomizer for *Harry Potter and the Chamber of Secrets* (PC, 2002 KnowWonder release), built on Metallicafan212's HP2Engine 3.4 (UE1 fork that restored UT99 IpDrv networking).

### Milestones complete (M0–M5)

| Milestone | Commit | What it proved |
| --- | --- | --- |
| M0 — Bootstrap | `48e3cac` | Repo + design docs |
| M1 — Hello-world mod | `929c493` | UScript toolchain works; `DefaultGame=` in `Game.ini` is the canonical entry point |
| M2 — TcpLink ping/pong | `cddb73f` | UScript ↔ Python bidirectional IPC over localhost:38281 |
| M3 — Card pickup round-trip | `5cedc10` | Watcher detects pickups, sidecar replies, mod applies — wire end-to-end. Album-persistence fix coded 2026-05-07 (direct `SetCardOwner` + `RemoveHarryOwnedCardsFromLevel`, not Spawn+Touch) — **untested, see in-flight section above.** |
| M4 — Real AP integration | `302b27d` | Sidecar subclasses `CommonContext`; speaks real AP WebSocket protocol against MultiServer |
| M5 — Full pool + hooks | `91ddc48`, `a167dfa`, `fcd68a5` | 114 items, 117 locations, gen pipeline, all four grant types (cards/spells/key items/beans) wired both ways |

Latest commit on `main`: see `git log --oneline -5`.

### What works end-to-end as of this handoff

Stefan has played a real seed: a CHECK in-game sends a `LocationChecks` to the AP server, the server sends back `ReceivedItems`, the sidecar forwards `GRANT <classname>`, the mod applies it. Echo cascade is solved (sidecar tracks `granted_card_game_ids` to ignore the watcher re-detecting AP-granted cards).

Detection:
- **Cards**: `APCardWatcher` polls `IsOwnedByHarry(id)` for ids 1–101 every 0.25s
- **Spells**: same watcher polls `harry.IsInSpellBook` for the 7 user-spells (excluded starter spells via initial-snapshot baseline)
- **Key items**: same watcher polls `nCount` on `StatusItemBoomslang/Bicorn/BitOGoyle` (all in `StatusGroupPolyIngr`)

Grant application (in `APGameInfo.ApplyGrant`):
- **Cards** → `siCard.SetCardOwner(cardClass.default.Id, CardOwner_Harry)` + `sgCards.RemoveHarryOwnedCardsFromLevel(None)`. Direct write to the canonical `WizardCards[50]` store; level-side cleanup destroys duplicate `WizardCardIcon` actors and replaces chest contents. Bypasses Spawn+Touch (whose `CanPickupNow` guard short-circuited for runtime-spawned actors).
- **Spells** → `harry.AddToSpellBookByString(name)`
- **Key items** → `managerStatus.AddBoomslang(1)` / `AddBicorn(1)` / `IncrementCount(StatusGroupPolyIngr, StatusItemBitOGoyle, 1)`
- **Beans** → `managerStatus.AddBeans(25/50/100)` for Small/Medium/Large

## What's NOT done

### Open questions

1. **Spell-start-state policy.** When AP grants a spell, what about the level that *teaches* that spell? Auto-skip? Replay? Open question for M6 — see DESIGN.md open question 7.
2. **Spell + key-item location mapping.** The mod *detects* spells and key items learned/picked up, but the sidecar currently only **logs** them — it doesn't yet send `LocationChecks` because we don't know which AP location each one maps to. That mapping needs playtest data (which classroom teaches which spell, which level holds which key item). Lands in M6.

### Next milestones

- **M6 — Logic + seed gen.** Author `data/logic.yaml`, regenerate apworld with proper region connections + access rules. Resolve the spell-mapping question. Run `start_inventory_from_pool: all` seed test, then play a real seed solo. Logic iteration is the long pole of the project — budget extra time.
- **M7 — Goal detection.** Subclass `Basilisk`, override death function, send `goal_complete`.
- **M8 — UX polish.** HUD toast, pickup FX on grants, vendor disable, etc.

## Setup on Stefan's machine

- Game install: `C:\Program Files (x86)\Harry Potter 2\Modded` (with M212 engine patched in). `Bingo` is the M212-bingo install, leave it alone.
- Repo: `C:\Users\kryen\Documents\Archipelago-play\Harry Potter 2 PC\HP2PC_AP`
- Archipelago framework checkout: `C:\Users\kryen\Documents\Archipelago-play\Archipelago` (sibling of the project)
- The apworld lives at `Archipelago\worlds\harry_potter_2\` — Stefan uses an `mklink /J` junction so edits in `apworld/` flow into the AP repo for live testing.
- Python 3.12 + asyncio + websockets via AP's `CommonClient`.
- UScript builds via `ucc make` in the Modded\System directory.

### File encoding gotchas

- `Game.log` is **UTF-16 LE** — read it with the right encoding or you'll get garbage.
- `Game.ini`, `HP.ini`, `Default.ini` are **ANSI / Win-1252**.
- `HP.ini` in the user data folder **overrides** `Default.ini`. If you edit `EditPackages=` in `Default.ini` and it doesn't take effect, also edit `HP.ini`.

### Mod entry point — verified, do not regress

`APGameInfo` extends `Engine.GameInfo`, registered via `DefaultGame=HPArchipelago.APGameInfo` under `[Engine.Engine]` in `Game.ini`. Everything else is silently ignored by HP2/M212:

- ❌ `[Engine.GameEngine] ServerActors=` — silently dropped
- ❌ `?Mutator=` URL params — stripped by HP2's Browse
- ❌ `GameInfo.AddMutator(string)` — KnowWonder removed it

See `docs/DESIGN.md#mod-entry-point` for the long version.

### Persistent singleton pattern — verified, do not regress

`APIPCActor` survives level transitions via:
- `bGameRelevant=True` and `bAlwaysRelevant=True` in `defaultproperties`
- A class-default reference (`var APIPCActor PersistentInstance` at static scope) initialized in `PreBeginPlay`
- `APGameInfo.InitGame` checks `APIPCActor.static.GetInstance()` before spawning — so re-entry doesn't churn

Result: one `APIPCActor`, one TCP connection, lasts the whole game session.

## Read these in order on startup

1. `README.md` — project overview, status line up to date as of M5
2. `docs/ROADMAP.md` — milestone-by-milestone status with commit hashes
3. `docs/DESIGN.md` — every locked decision, including the v2 parking lot
4. `docs/MOD_TODO.md` — what the UScript mod has to do, with completion state
5. `docs/DEV_SETUP.md` — toolchain commands, build loop, file paths
6. This file (you're reading it)

The DESIGN doc has a **v2 parking lot** at the bottom. Anything not in v1 lives there. If Stefan proposes a feature mid-conversation that's already parked, gently redirect.

## Memory pointers

The `memory/` directory under `~/.claude/projects/.../` already has entries for:
- Stefan's role and skill profile (user memory)
- Don't-stop-recommending feedback
- Short-commit-message feedback
- No-AI-attribution feedback

When you start the session, those should auto-load via `MEMORY.md`. If they don't appear, something's wrong with the memory system.

## First sanity check on resume

```powershell
git log --oneline -5
```

Should show `f978109` or later as HEAD on `main`. If it's older, Stefan has either reset or you're on a stale checkout — ask before doing anything.

```powershell
ls docs/
```

Should show `DESIGN.md ROADMAP.md MOD_TODO.md DEV_SETUP.md AGENTS.md`. If any are missing, ask.

## When unsure, ask Stefan

He'd rather you ask one specific question than guess and waste time. But spend up to a minute on read-only investigation first (grep, read existing files) so the question is specific. "I see `IsInSpellBook` in `harry.uc:1234` — is that what we should hook?" beats "how do I detect spells?".
