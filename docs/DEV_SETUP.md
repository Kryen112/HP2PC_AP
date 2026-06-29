# DEV_SETUP - HP2PC_AP

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
| **Archipelago framework** | **0.6.7** (release tag) | Released 2026-04-01. Pinned to a tag, **not `main`**. `main` breaks. Bump deliberately, not by drift. |
| **M212 HP2Engine** | **3.4** | From the FAQ doc's "Version 3.4" header. |

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
| Python 3.12 | `C:\Users\<you>\AppData\Local\Programs\Python\Python312\python.exe` (use `py -3.12` to invoke) |
| HP2PC_AP repo | `C:\Users\<you>\Documents\Archipelago-play\Harry Potter 2 PC\HP2PC_AP\` |
| M212 user data (saves, `User.ini`, `HP2.log`) | `C:\Users\<you>\Documents\Harry - Coding Evolved\` |
| Retail HP2 user data (saves, kept separate from M212) | `C:\Users\<you>\Documents\Harry Potter II\` |

Start Menu shortcuts (created by the M212 installer, repointed to `Modded\` on 2026-05-07):

- `M212 → Launch Editor` → opens `Modded\system\UnrealEd.exe`
- `M212 → Launch Game` → opens `Modded\system\Game.exe`
- Public Desktop "Harry Potter 2" still points at vanilla `Bingo\`. Leave for vanilla sanity checks.

## Python environment

Project-local venv keeps HP2PC_AP from fighting other AP projects on this PC.

```powershell
cd "C:\Users\<you>\Documents\Archipelago-play\Harry Potter 2 PC\HP2PC_AP"
py -3.12 -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install --upgrade pip
# Project-side deps
pip install pyyaml
```

`.venv/` is already excluded by `.gitignore`.

## Archipelago framework (existing install)

The existing AP framework install is at `C:\Users\<you>\Documents\Archipelago-play\Archipelago\`, checked out at the **0.6.7** release tag (matching the pin above). HP2PC_AP integrates with this existing install rather than maintaining a separate clone.

For HP2PC_AP development, the repo's `apworld/` directory is the AP-world source. To make AP discover it during seed generation, we mirror it into `Archipelago/worlds/harry_potter_2_pc/` via a directory junction:

```powershell
New-Item -ItemType Junction `
  -Path   'C:\Users\<you>\Documents\Archipelago-play\Archipelago\worlds\harry_potter_2_pc' `
  -Target 'C:\Users\<you>\Documents\Archipelago-play\Harry Potter 2 PC\HP2PC_AP\apworld'
```

(One-time setup. Edits in the repo's `apworld/` are immediately visible to the AP framework via the junction. No copy step.)

> **Don't use `mklink /J` from PowerShell** even though it's the canonical UE1-modder snippet. `mklink` is a `cmd.exe` builtin; PowerShell strips the quotes around its args before cmd sees them, so a path with spaces silently truncates at the first space, producing a broken junction that points at a non-existent directory and a misleading `excluding harry_potter_2_pc ... no __init__.py` warning during seed gen. The `New-Item` form above doesn't have this problem.

If you ever need to recreate the junction (e.g., it got broken), `cmd /c rmdir <junction-path>` removes it safely without touching the target, then re-run the `New-Item` command.

To bump the AP framework version, do a controlled `git fetch && git checkout <tag>` in `Archipelago-play\Archipelago\`. Test that other AP projects still work, then test HP2PC_AP.

## Player files (AP slot YAMLs)

`gen_seed.ps1` invokes `Generate.py --player_files_path "$ap\Players"`, reading every `.yaml` in the AP install's standard `Players/` directory. Drop your slot YAMLs there.

For solo HP2 testing, one slot suffices. A typical `HP2_Test.yaml` for full playthrough:

```yaml
name: HP2_Test
description: HP2 full-playthrough seed for logic cataloguing
game: Harry Potter 2 PC
Harry Potter 2 PC:
  plando_items:
    - { item: Rictusempra, location: "Learned Rictusempra", from_pool: true, force: silent }
    - { item: Skurge,      location: "Learned Skurge",      from_pool: true, force: silent }
    - { item: Diffindo,    location: "Learned Diffindo",    from_pool: true, force: silent }
    - { item: Spongify,    location: "Learned Spongify",    from_pool: true, force: silent }
```

Why each entry:

- **Lumos/Flipendo/Alohomora are not listed here.** They're the default `starting_spells`, so the world precollects them and they need no plando entry. In vanilla, Lumos and Flipendo are force-precollected regardless, since clearing the Whomping Willow physically needs both.
- **`plando_items` 4 classroom locks.** Walking into a classroom auto-teleports to the spell challenge with the exit locked behind. If the player doesn't already own the spell, they softlock. The proper fix unlocks the door via UScript; the workaround (used in the sample YAML above) is to plando each spell at its own classroom so picking it up at the challenge end grants the spell that opens the exit.
- **`from_pool: true`** removes the plando'd copy from the random pool (no duplicates). **`force: silent`** suppresses the noisy "plando applied" stdout per entry.

For "everything-unlocked" playtest mode (skip cataloguing, prove the AP solver), use `start_inventory_from_pool` for the 4 non-starter spells + 3 special progression items and drop the classroom plandos.

## One-time M212 engine prep

UCC needs two `EditPackages=` entries to compile `HPArchipelago`:

- **`IpDrv`** so it can resolve `class APIPCActor extends IpDrv.TcpLink`. M212 ships `IpDrv.dll`+`IpDrv.u` in `Modded\system\` but doesn't register them in `Default.ini` automatically. You must add this entry yourself.
- **`HPArchipelago`** so UCC compiles our package at all.

Both must land in `Modded\system\Default.ini` AND in `Documents\Harry - Coding Evolved\HP.ini` if HP.ini exists. UCC reads from HP.ini once it's been created (typically after first game launch), and from that point Default.ini edits alone are ignored (see Known gotchas). The snippet below patches both files, is idempotent (re-running won't duplicate), and skips HP.ini if it doesn't exist yet.

`Default.ini` extends past the `EditPackages=` list with graphics-adapter sections, so **don't append at end-of-file**. That lands in the wrong section. The snippet inserts immediately after `EditPackages=M212Share` (the last existing entry).

Run in **elevated PowerShell** (Default.ini lives in `Program Files (x86)`):

```powershell
function Update-EditPackages {
    param([string]$IniPath)
    if (-not (Test-Path -LiteralPath $IniPath)) { Write-Host "Skip (absent): $IniPath"; return }
    $lines = Get-Content -LiteralPath $IniPath -Encoding Default
    # Strip any existing IpDrv/HPArchipelago entries so re-running doesn't duplicate
    $lines = @($lines | Where-Object { $_ -notmatch '^EditPackages=(IpDrv|HPArchipelago)$' })
    $idx = ($lines | Select-String -Pattern '^EditPackages=M212Share$' | Select-Object -Last 1).LineNumber
    if (-not $idx) { throw "EditPackages=M212Share not found in $IniPath - is this an M212 install?" }
    $new = $lines[0..($idx-1)] + 'EditPackages=IpDrv' + 'EditPackages=HPArchipelago' + $lines[$idx..($lines.Count-1)]
    $new | Set-Content -LiteralPath $IniPath -Encoding Default
    Write-Host "Updated: $IniPath"
}

Update-EditPackages 'C:\Program Files (x86)\Harry Potter 2\Modded\system\Default.ini'
Update-EditPackages "$env:USERPROFILE\Documents\Harry - Coding Evolved\HP.ini"
```

That's it. No `icacls` grants. Earlier we tried granting Modify permissions on `Modded\system\` and `Modded\HPArchipelago\` to enable non-admin builds, but it ended up entangled with a freeze we couldn't reproduce afterward, so the simpler path is to just use elevated PowerShell for each build. Daily builds are fast enough that the UAC prompt isn't a real friction point.

## Build loop (UScript mod)

Status: scripted helper not yet written. Manual steps for now. Both steps require elevated PowerShell because `Modded\` is in `Program Files (x86)`.

1. Edit UScript source under `mod/HPArchipelago/Classes/*.uc` in the repo.
2. Mirror the package folder into the engine and compile, in one shot:

   ```powershell
   $repo = 'C:\Users\<you>\Documents\Archipelago-play\Harry Potter 2 PC\HP2PC_AP'
   $sys = 'C:\Program Files (x86)\Harry Potter 2\Modded\system'
   robocopy "$repo\mod\HPArchipelago" 'C:\Program Files (x86)\Harry Potter 2\Modded\HPArchipelago' /MIR /XF .gitkeep
   Push-Location $sys
   .\UCC.exe make
   Pop-Location
   ```
3. The compiled `HPArchipelago.u` ends up in `Modded\system\`. UCC always recompiles `UnrealShare.u` too (M212 ships sample classes whose `.uc` mtimes are newer than the shipped `.u`); the rebuilt `UnrealShare.u` is benign, verified to not break the game. `.u` files stay out of git per `.gitignore`.

## Run loop

Launch via the **M212 → Launch Game** Start Menu shortcut (or `Modded\system\Game.exe` directly). Logs land at:

- `Documents\Harry - Coding Evolved\Game.log`, current run, **UTF-16LE encoded**. Use `Get-Content -Encoding Unicode`.
- `Documents\Harry - Coding Evolved\Logs\Game_<timestamp>.log`, auto-archived previous runs.

To search logs from PowerShell:

```powershell
Get-Content -LiteralPath 'C:\Users\<you>\Documents\Harry - Coding Evolved\Game.log' -Encoding Unicode | Select-String -Pattern 'Archipelago'
```

## Running the client (dev)

The client is `apworld/Client.py` and is shipped inside `harry_potter_2_pc.apworld`. End users launch it via the **HP2 PC Client** button in ArchipelagoLauncher; no exe build step.

For dev (running against a local seed), launch it as a module of the apworld so its relative imports resolve:

```powershell
$ap = 'C:\Users\<you>\Documents\Archipelago-play\Archipelago'
Push-Location $ap
try {
    py -3.12 -m worlds.harry_potter_2_pc.Client --name HP2_Test --connect localhost:38281
} finally {
    Pop-Location
}
```

This is what `scripts/run_client.ps1` does. Requires the apworld junction (see **Archipelago framework** section) so `worlds.harry_potter_2_pc` resolves to the repo's `apworld/` directory.

Alternative: `ArchipelagoLauncher.exe "HP2 PC Client"` runs the launcher entry point directly (Kivy GUI), same path users take.

**Heads-up: `[Engine.GameEngine] ServerActors=` does not work** for runtime registration on M212/HP2 (verified 2026-05-07). Runtime hookup goes through a `GameInfo` subclass registered with `DefaultGame=HPArchipelago.APGameInfo` in `Game.ini`'s `[Engine.Engine]`; the mod spawns its actors from that class's `InitGame`. The mutator-via-URL route was also a dead end.

## Fresh-PC bootstrap

If you clone this repo on a new Windows machine, do these in order:

1. Install retail HP2 (KnowWonder 2002). Keep this copy untouched as the vanilla reference (the `Bingo\` role above).
2. Make a second copy of the install folder for modding (the `Modded\` role above), or let the M212 installer write into its own copy.
3. Download the M212 editor installer from the FAQ doc (link only shared in the modding Discord, do not redistribute), run it, point at the modding copy, accept defaults.
4. Install Python 3.12 from python.org (or `winget install Python.Python.3.12`). The pinned 3.12 must be present even if a newer Python is installed. AP 0.6.7 supports 3.11/3.12/3.13, and 3.14+ is too new.
5. Clone HP2PC_AP and `Archipelago` (at the pinned tag) side by side.
6. Run the **One-time M212 engine prep** section above (elevated).
7. Create the apworld junction (**Archipelago framework** section above).
8. Create the AP player files (**Player files** section above).
9. Repoint any Start Menu shortcuts the M212 installer leaves under `ProgramData\...\M212\` if you renamed the modding copy folder (see the 2026-05-07 rename note above).
10. Read `../README.md` for the project overview and feature set.

## Known gotchas

- **Every UScript build needs elevated PowerShell** because `Modded\` is in `Program Files (x86)`. We considered `icacls` Modify-grants to enable non-admin builds; abandoned because the grants entangled with a freeze we couldn't reproduce afterward. Elevated PS is the simpler, safer default.
- **Default.ini extends past the EditPackages list.** Lines ~389+ are graphics-adapter sections (`[Diamond Stealth III/...]`, `[ATI 3D Rage Pro]`, etc.). Inserting `EditPackages=HPArchipelago` via `Add-Content` or any append-to-end will land in the wrong section. Always insert *immediately after* `EditPackages=M212Share`. The snippet in the engine prep section above does this correctly.
- **HP.ini overrides Default.ini at runtime AND for UCC.** First game launch copies `Default.ini`'s `[Editor.EditorEngine]` (`EditPackages=`) and `[Core.System]` (`Paths=`, render-device, etc.) into `Documents\Harry - Coding Evolved\HP.ini`. After that, both Game.exe and UCC.exe read from HP.ini. Edits to Default.ini alone are ignored. If a Default.ini change doesn't take effect, also apply it to HP.ini. Bit us during fresh-laptop install: adding `EditPackages=IpDrv` to Default.ini alone left UCC failing with `Class APIPCActor has invalid parent IpDrv.TcpLink` until HP.ini was patched too. The engine prep snippet above handles both files.
- **`mklink /J` from PowerShell silently truncates path args with spaces.** It's a `cmd.exe` builtin; PowerShell strips quoting before cmd sees it, so the second arg becomes just the part before the first space. The resulting junction is dead. It points at a non-existent directory, and `Generate.py` reports `excluding harry_potter_2_pc ... no __init__.py`. Use `New-Item -ItemType Junction -Path <link> -Target <target>` (native PowerShell) instead (see Archipelago framework section). To recreate a broken junction, `cmd /c rmdir <junction>` removes it safely without touching the target.
- **`[Engine.GameEngine] ServerActors=` is silently ignored** by M212/HP2 (verified 2026-05-07). A valid entry pointing at a real, compiled class produces zero log evidence and zero `PreBeginPlay` invocation. Don't design around it. Runtime hooks go through a `GameInfo` subclass instead (`DefaultGame=HPArchipelago.APGameInfo`); mutator-via-URL was a dead end.
- **File encodings differ between user-data files** in `Documents\Harry - Coding Evolved\`:
    - `Game.log`, UTF-16LE (BOM `FF FE`). Use `Get-Content -Encoding Unicode` / `Set-Content -Encoding Unicode`.
    - `Game.ini`, `User.ini`, `HP.ini`, and `Default.ini` in `Modded\system\`, ANSI / Windows-1252, no BOM. Use `-Encoding Default`.
    - Wrong encoding silently produces garbage and silent edit failures.
- **UCC make always recompiles `UnrealShare.u`** (M212 ships sample `.uc` files there with newer mtimes than the shipped `.u`). The rebuild is benign, verified to not break the game. Don't try to "protect" UnrealShare with timestamp tricks; it's fine as-is.
- **`LanguageCode=nl` log spam** is normal idle-UI noise driven by Windows REGIONAL FORMAT (not display language). M212 ships only `.int` and `.kor` locale files in `system\`, so any non-English regional format generates this at UI-tick rate. Doesn't indicate a fault.
- **Folder naming is intentional.** `Bingo\` = retail vanilla, `Modded\` = M212. The M212 installer preserves your language; the `.lnk` inside `Modded\` may be in Swedish, that's expected.
- **`IpDrv` networking** is restored from UT99 in M212's engine. M212 hadn't end-to-end tested it in years (per Discord 2026-05-06), but this mod's client/game bridge (`APIPCActor extends IpDrv.TcpLink`) runs over it and works end to end.
- **M212 saves and `User.ini`** live in `Documents\Harry - Coding Evolved\`, separate from the retail install's `Documents\Harry Potter II\`. If you ever reinstall M212 and the option to "delete the documents folder when updating" is checked, your saves go away.
- **Third-party renderers/overlays** (Dxtory, texture upscalers, FPS overlays) crash M212's engine. Disable them.
