# DEV_SETUP — HP2PC_AP

How this dev machine is configured and the daily build/run loop. Update whenever a pinned version, path, or step changes.

---

## System requirements

- **OS:** Windows 10 or 11 64-bit. (Per M212's FAQ, Win 7/8 may not work; Win 11 has reported quirks but is supported.)
- **RAM:** 8 GB minimum, 16 GB recommended.
- **CPU:** any 64-bit AMD/Intel. (M212's engine is 64-bit; the original retail game was 32-bit.)

## Pinned versions

| Component | Version | Notes |
| --- | --- | --- |
| **Python** | **3.12.x** (currently 3.12.10) | AP 0.6.4 dropped 3.10. 3.12 is the safe middle of AP's supported range (3.11 / 3.12 / 3.13). |
| **Archipelago framework** | **0.6.7** (release tag) | Released 2026-04-01. Pinned to a tag, **not `main`** — `main` breaks. Bump deliberately, not by drift. |
| **M212 HP2Engine** | **3.4** | From the FAQ doc's "Version 3.4" header. |
| **HP2PC_AP** | pre-alpha (M0) | See `ROADMAP.md`. |

## Installed paths (this PC)

| What | Where |
| --- | --- |
| Retail HP2 (vanilla reference, untouched) | `C:\Program Files (x86)\Harry Potter 2\Bingo\` |
| M212-modded HP2 (dev + play target) | `C:\Program Files (x86)\Harry Potter 2\Modded\` |
| `UCC.exe` (the UScript compiler) | `...\Modded\system\UCC.exe` |
| `UnrealEd.exe` | `...\Modded\system\UnrealEd.exe` |
| `Game.exe` | `...\Modded\system\Game.exe` |
| `Default.ini` (per-install engine config) | `...\Modded\system\Default.ini` |
| `IpDrv.dll` (UT99-restored networking) | `...\Modded\system\IpDrv.dll` |
| Python 3.12 | `C:\Users\kryen\AppData\Local\Programs\Python\Python312\python.exe` (use `py -3.12` to invoke) |
| HP2PC_AP repo | `C:\Users\kryen\Documents\Archipelago-play\Harry Potter 2 PC\HP2PC_AP\` |
| M212 user data (saves, `User.ini`, `HP2.log`) | `C:\Users\kryen\Documents\Harry - Coding Evolved\` |
| Retail HP2 user data (saves, kept separate from M212) | `C:\Users\kryen\Documents\Harry Potter II\` |

Start Menu shortcuts (created by the M212 installer, repointed to `Modded\` on 2026-05-07):

- `M212 → Launch Editor` → opens `Modded\system\UnrealEd.exe`
- `M212 → Launch Game` → opens `Modded\system\Game.exe`
- Public Desktop "Harry Potter 2" still points at vanilla `Bingo\`. Leave for vanilla sanity checks.

## Python environment

Project-local venv keeps HP2PC_AP from fighting other AP projects on this PC.

```powershell
cd "C:\Users\kryen\Documents\Archipelago-play\Harry Potter 2 PC\HP2PC_AP"
py -3.12 -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install --upgrade pip
# Project-side deps (will grow as M2+ lands)
pip install pyyaml
```

`.venv/` is already excluded by `.gitignore`.

## Archipelago framework (separate clone)

The AP framework lives **outside** this repo. The HP2PC_AP `apworld/` is dropped into AP's `worlds/` directory at gen time.

```powershell
cd "C:\Users\kryen\Documents\Archipelago-play"
git clone --branch 0.6.7 --depth 1 https://github.com/ArchipelagoMW/Archipelago.git
cd Archipelago
py -3.12 -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
```

Once HP2PC_AP gets a real `apworld/` (M5), drop or symlink it into `Archipelago/worlds/harry_potter_2/` to generate seeds.

## One-time M212 engine prep (elevated PowerShell)

One change is needed in `Modded\system\Default.ini` to register the package with UCC. `Modded\` lives in `Program Files (x86)` so this requires elevated PowerShell.

`Default.ini` extends past the `EditPackages=` list with graphics-adapter sections, so **don't append at end-of-file** — that lands in the wrong section. Insert immediately after `EditPackages=M212Share` (the last existing entry):

```powershell
$path = 'C:\Program Files (x86)\Harry Potter 2\Modded\system\Default.ini'
$lines = Get-Content -LiteralPath $path -Encoding Default
$idx = ($lines | Select-String -Pattern '^EditPackages=M212Share$' | Select-Object -Last 1).LineNumber
$new = $lines[0..($idx-1)] + 'EditPackages=HPArchipelago' + $lines[$idx..($lines.Count-1)]
$new | Set-Content -LiteralPath $path -Encoding Default
```

That's it. No `icacls` grants — earlier we tried granting Modify permissions on `Modded\system\` and `Modded\HPArchipelago\` to enable non-admin builds, but it ended up entangled with a freeze we couldn't reproduce afterward, so the simpler path is to just use elevated PowerShell for each build. Daily builds are fast enough that the UAC prompt isn't a real friction point.

## Build loop (UScript mod)

Status: scripted helper not yet written — manual steps for now. Both steps require elevated PowerShell because `Modded\` is in `Program Files (x86)`.

1. Edit UScript source under `mod/HPArchipelago/Classes/*.uc` in the repo.
2. Mirror the package folder into the engine and compile, in one shot:

   ```powershell
   $repo = 'C:\Users\kryen\Documents\Archipelago-play\Harry Potter 2 PC\HP2PC_AP'
   $sys = 'C:\Program Files (x86)\Harry Potter 2\Modded\system'
   robocopy "$repo\mod\HPArchipelago" 'C:\Program Files (x86)\Harry Potter 2\Modded\HPArchipelago' /MIR /XF .gitkeep
   Push-Location $sys
   .\UCC.exe make
   Pop-Location
   ```
3. The compiled `HPArchipelago.u` ends up in `Modded\system\`. UCC always recompiles `UnrealShare.u` too (M212 ships sample classes whose `.uc` mtimes are newer than the shipped `.u`); the rebuilt `UnrealShare.u` is benign — verified to not break the game. `.u` files stay out of git per `.gitignore`.

## Run loop

Launch via the **M212 → Launch Game** Start Menu shortcut (or `Modded\system\Game.exe` directly). Logs land at:

- `Documents\Harry - Coding Evolved\Game.log` — current run, **UTF-16LE encoded**. Use `Get-Content -Encoding Unicode`.
- `Documents\Harry - Coding Evolved\Logs\Game_<timestamp>.log` — auto-archived previous runs.

To search logs from PowerShell:

```powershell
Get-Content -LiteralPath 'C:\Users\kryen\Documents\Harry - Coding Evolved\Game.log' -Encoding Unicode | Select-String -Pattern 'Archipelago'
```

For M2+ (with sidecar): activate the project venv, run `python client/hp2_client.py` (sidecar listens on `localhost:38281`), then launch the game.

**Heads-up: `[Engine.GameEngine] ServerActors=` does not work** for runtime registration on M212/HP2 (verified 2026-05-07). The mutator chain *is* alive — `Base Mutator is <Level>.Mutator<N>` shows up per level transition — so the next experiment for runtime hookup is mutator-via-URL on the launcher shortcut. See `docs/MOD_TODO.md`.

## Fresh-PC bootstrap

If you (or a future Claude) clones this repo on a new Windows machine, do these in order:

1. Install retail HP2 (KnowWonder 2002). Keep this copy untouched as the vanilla reference (the `Bingo\` role above).
2. Make a second copy of the install folder for modding (the `Modded\` role above), or let the M212 installer write into its own copy.
3. Download the M212 editor installer from the FAQ doc (link only shared in the modding Discord — do not redistribute), run it, point at the modding copy, accept defaults.
4. Install Python 3.12 from python.org.
5. Clone HP2PC_AP and `Archipelago` (at the pinned tag) side by side.
6. Run the **One-time M212 engine prep** section above (elevated).
7. Repoint any Start Menu shortcuts the M212 installer leaves under `ProgramData\...\M212\` if you renamed the modding copy folder (see the 2026-05-07 rename note above).
8. Read `readme-may-7th.md` if it's still in the repo, then `docs/DESIGN.md` and `docs/ROADMAP.md`.

## Known gotchas

- **Every UScript build needs elevated PowerShell** because `Modded\` is in `Program Files (x86)`. We considered `icacls` Modify-grants to enable non-admin builds; abandoned because the grants entangled with a freeze we couldn't reproduce afterward. Elevated PS is the simpler, safer default.
- **Default.ini extends past the EditPackages list.** Lines ~389+ are graphics-adapter sections (`[Diamond Stealth III/...]`, `[ATI 3D Rage Pro]`, etc.). Inserting `EditPackages=HPArchipelago` via `Add-Content` or any append-to-end will land in the wrong section. Always insert *immediately after* `EditPackages=M212Share` — the snippet in the engine prep section above does this correctly.
- **`[Engine.GameEngine] ServerActors=` is silently ignored** by M212/HP2 (verified 2026-05-07). A valid entry pointing at a real, compiled class produces zero log evidence and zero `PreBeginPlay` invocation. Don't design around it. The mutator chain works; investigate mutator-via-URL or HGame's GameInfo subclass for runtime hooks.
- **File encodings differ between user-data files** in `Documents\Harry - Coding Evolved\`:
    - `Game.log` — UTF-16LE (BOM `FF FE`). Use `Get-Content -Encoding Unicode` / `Set-Content -Encoding Unicode`.
    - `Game.ini`, `User.ini`, `HP.ini`, and `Default.ini` in `Modded\system\` — ANSI / Windows-1252, no BOM. Use `-Encoding Default`.
    - Wrong encoding silently produces garbage and silent edit failures.
- **UCC make always recompiles `UnrealShare.u`** (M212 ships sample `.uc` files there with newer mtimes than the shipped `.u`). The rebuild is benign — verified to not break the game. Don't try to "protect" UnrealShare with timestamp tricks; it's fine as-is.
- **`LanguageCode=nl` log spam** is normal idle-UI noise driven by Windows REGIONAL FORMAT (not display language). M212 ships only `.int` and `.kor` locale files in `system\`, so any non-English regional format generates this at UI-tick rate. Doesn't indicate a fault.
- **Folder naming is intentional.** `Bingo\` = retail vanilla, `Modded\` = M212. The M212 installer preserves your language; the `.lnk` inside `Modded\` may be in Swedish — that's expected.
- **`IpDrv` networking** is restored from UT99 in M212's engine but hasn't been end-to-end tested by M212 in years (per Discord 2026-05-06). Treat as working but verify in M2.
- **M212 saves and `User.ini`** live in `Documents\Harry - Coding Evolved\` — separate from the retail install's `Documents\Harry Potter II\`. If you ever reinstall M212 and the option to "delete the documents folder when updating" is checked, your saves go away.
- **Third-party renderers/overlays** (Dxtory, texture upscalers, FPS overlays) crash M212's engine. Disable them.
