# Handoff — written 2026-05-07

This file is for the next Claude that boots into this repo. Read it top-to-bottom before doing anything else. The previous Claude wrote it after a long session that took the project from M0 design docs to a working M5 with end-to-end Archipelago integration.

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
| M3 — Card pickup round-trip | `5cedc10` | Watcher detects pickups, sidecar replies, mod applies — wire end-to-end. Album persistence is an open question (see below). |
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
- **Cards** → `Spawn(class)` + `Touch(harry)` chain (works in-memory, but album-persistence is unresolved — see open question)
- **Spells** → `harry.AddToSpellBookByString(name)`
- **Key items** → `managerStatus.AddBoomslang(1)` / `AddBicorn(1)` / `IncrementCount(StatusGroupPolyIngr, StatusItemBitOGoyle, 1)`
- **Beans** → `managerStatus.AddBeans(25/50/100)` for Small/Medium/Large

## What's NOT done

### Open questions

1. **Card album persistence (M3 open).** AP-granted cards don't show in the album. HP2 wipes `WizardCards[]` between operations. Stefan still needs to post the question to the M212 Discord — `task #23` is pending. Until answered, AP-granted cards work mechanically but visually don't show up in the album. Don't try to fix this without the Discord answer; the previous Claude went deep on diagnostics and concluded it needs M212 dev input.
2. **Spell-start-state policy.** When AP grants a spell, what about the level that *teaches* that spell? Auto-skip? Replay? Open question for M6 — see DESIGN.md open question 7.
3. **Spell + key-item location mapping.** The mod *detects* spells and key items learned/picked up, but the sidecar currently only **logs** them — it doesn't yet send `LocationChecks` because we don't know which AP location each one maps to. That mapping needs playtest data (which classroom teaches which spell, which level holds which key item). Lands in M6.

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
- HP2 card-grant persistence open question (project memory)

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
