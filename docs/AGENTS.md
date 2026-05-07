# AGENTS — Proposed Claude Code subagents and slash commands

What specialized helpers to set up in `.claude/` so each task gets a focused context. None of these exist yet — this doc is a proposal for what to scaffold during M1–M2.

## Subagents (`.claude/agents/*.md`)

### `uscript-author`

**Purpose:** writes and reviews UnrealScript `.uc` files for the mod.

**Pre-loaded context:** path to `../uscript/` (the decompiled retail source — read-only reference); pointers to `HGame/Classes/WizardCards/WizardCardIcon.uc`, `HGame/Classes/Bosses/Basilisk.uc`, and the spell base classes; M212 engine quirks (UT99-restored IpDrv); a summary of `docs/MOD_TODO.md`.

**When to invoke:** any task that creates or modifies files under `mod/HPArchipelago/Classes/`. The user has zero UScript experience, so this agent's job is to act as a UScript expert pair-programmer.

**Suggested tools:** Read, Edit, Write, Glob, Grep.

### `apworld-scaffolder`

**Purpose:** generates `apworld/*.py` from `data/*.yaml`, and reviews AP world code.

**Pre-loaded context:** AP framework conventions (Region, Entrance, Location, Item, Rules); the YAML schemas in `data/`; the AP framework version pinned in `docs/DEV_SETUP.md`.

**When to invoke:** any task in `apworld/`, `client/`, or `scripts/gen_apworld.py`. After every edit to `data/*.yaml`, this agent re-runs the generator and inspects the diff.

**Suggested tools:** Read, Edit, Write, Bash, Glob, Grep.

### `hp2-source-explorer`

**Purpose:** read-only "where is X defined in HP2?" search agent.

**Pre-loaded context:** `../uscript/` directory layout, key namespaces (`HGame`, `HEngine`, `HProps`, etc.), how HP2 classes inherit.

**When to invoke:** "where does the game handle X?" / "is there a class that does Y?" before writing UScript hooks. Saves the main agent from grepping through 4500+ files.

**Suggested tools:** Read, Glob, Grep. NO Edit/Write — read-only.

### `playtest-logger`

**Purpose:** during a playtest session, record observations and turn them into `data/logic.yaml` entries.

**Pre-loaded context:** the YAML schema; the location list; "what counts as a playtest observation" (e.g., "Card X requires spell Y to reach because of obstacle Z").

**When to invoke:** the user is doing a playtest run and reports findings; this agent appends to logic.yaml in a structured way.

**Suggested tools:** Read, Edit, Write.

## Slash commands / skills

Wrap repetitive workflows so they're one keystroke. These live in `.claude/commands/`.

### `/gen-apworld`

Runs `python scripts/gen_apworld.py` and reports the diff. Use after every edit to `data/*.yaml`.

### `/build-mod`

Runs `ucc make` against M212's engine and copies the resulting `HPArchipelago.u` into the game's `System/` folder. Reports compile errors. Path to the M212 engine is in a config the user sets up once during M1.

### `/playtest`

Boots the local AP server (or connects to a remote one), launches `client/hp2_client.py`, then launches HP2 on M212's engine. Tears down on exit. End-to-end "open a playtest session" command.

### `/check-logic`

Runs the AP generator with `start_inventory_from_pool: all` and reports any unreachable location or generation error. Use as a cheap CI check after editing logic.

## What NOT to set up

- A "writes Python and UScript both" mega-agent. Splitting them keeps each context small and focused.
- An "auto-playtest" agent. Playtests need a human in front of the game; automating them is v3 territory at best.
- A "review my entire codebase" agent. Use the built-in `Plan` and `Explore` agents for that.

## How to scaffold

When you reach M2, ask Claude in your repo: *"Scaffold `.claude/agents/uscript-author.md` and `.claude/commands/build-mod.md` per `docs/AGENTS.md`."* Claude knows the format. Don't pre-create them now — they'll evolve as the project does, and stale agent definitions are worse than no agent.
