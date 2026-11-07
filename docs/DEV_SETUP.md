# DEV_SETUP - HP2PC_AP

How this dev machine is configured and the daily build/run loop. Update whenever a pinned version, path, or step changes.

---

## System requirements

- **OS:** Windows 10 or 11.
- **An optical drive and the game disc.** The game's SafeDisc check reads the disc on every launch, dev launches included.
- **SafeDiscShim** (<https://github.com/RibShark/SafeDiscShim/releases>), so the disc check works on modern Windows. Windows 11 Smart App Control can block it; turn Smart App Control off if the game will not start.

## Pinned versions

| Component | Version | Notes |
| --- | --- | --- |
| **Python** | **3.12.x** (currently 3.12.10) | AP 0.6.4 dropped 3.10. 3.12 is the safe middle of AP's supported range (3.11 / 3.12 / 3.13). |
| **Archipelago framework** | **0.6.7** (release tag) | Released 2026-04-01. Pinned to a tag, **not `main`**. `main` breaks. Bump deliberately, not by drift. |
| **HP2** | engine build 433, script packages v79 | The KnowWonder 2002 disc release. Language does not matter (this machine's disc installed in Dutch). |
| **UScript kit (AdamJD)** | 2023 build | `UCC.exe` plus a kit `Editor.dll`. The game ships neither. Download it from the Google Drive folder listed on the HarryPotterUnrealWiki's Main-Resources page. Dev machine only, never shipped. |
| **SafeDiscShim** | 0.9.0 | Beta builds log next to `Game.exe`; set `SAFEDISCSHIM_LOGLEVEL=none` to silence them. |

## Installed paths (this PC)

| What | Where |
| --- | --- |
| Reference install (installed from the disc, never modified) | `D:\HP2\` |
| Dev install (a copy of the reference; build and play target) | `C:\Games\HP2-Dev\` |
| `UCC.exe` (from the kit) | `C:\Games\HP2-Dev\system\UCC.exe` |
| Kit and stock editor DLLs | `C:\Games\HP2-Dev\system\Editor.dll.kit`, `Editor.dll.stock` (the build swaps them) |
| Mod source mirror the compiler reads | `C:\Games\HP2-Dev\HPArchipelago\` |
| Build log | `C:\Games\HP2-Dev\build\ucc_make.txt` |
| Exported stock class defaults (reference only) | `C:\Games\HP2-Dev\StockExport\` |
| Per-user game data (`Game.ini`, `Game.log`, saves) | `C:\Users\<you>\Documents\Harry Potter II\` |
| Game-to-client link folder | `C:\Users\<you>\Documents\Harry Potter II\AP\` |
| Python 3.12 | `C:\Users\<you>\AppData\Local\Programs\Python\Python312\python.exe` (use `py -3.12` to invoke) |
| HP2PC_AP repo | `C:\Users\<you>\Documents\Archipelago-play\Harry Potter 2 PC\HP2PC_AP\` |
| Decompiled stock UScript (reference) | `C:\Users\<you>\Documents\Archipelago-play\Harry Potter 2 PC\HP2UScriptDecompile\` (a community decompile that differs from the shipped game in places, for example `HPHud.propArray` is a fixed `[20]` array in the game) |

Every install of the game on the machine shares `Documents\Harry Potter II\` (one `Game.ini`, one save folder). Back up a save slot before a test that might overwrite it.

The frozen Archipelago install's `host.yaml` points `install_folder` at the dev install, so the client deploys there and auto-launch starts it.

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

> **Don't use `mklink /J` from PowerShell.** `mklink` is a `cmd.exe` builtin; PowerShell strips the quotes around its args before cmd sees them, so a path with spaces silently truncates at the first space, producing a broken junction that points at a non-existent directory and a misleading `excluding harry_potter_2_pc ... no __init__.py` warning during seed gen. The `New-Item` form above doesn't have this problem.

If you ever need to recreate the junction (e.g., it got broken), `cmd /c rmdir <junction-path>` removes it safely without touching the target, then re-run the `New-Item` command.

To bump the AP framework version, do a controlled `git fetch && git checkout <tag>` in `Archipelago-play\Archipelago\`. Test that other AP projects still work, then test HP2PC_AP.

## Player files (AP slot YAMLs)

Generate from the AP checkout (`py -3.12 Generate.py --player_files_path <folder>`) or with the frozen install's `ArchipelagoGenerate.exe`, pointing at a folder of slot YAMLs. A minimal solo test slot:

```yaml
name: HP2_Test
game: Harry Potter 2 PC
Harry Potter 2 PC:
  game_mode: vanilla
  start_inventory:
    Overcompensation Trap: 1
```

`start_inventory` is the quickest way to see an item or trap in game: it arrives as soon as the game connects. Each classroom check (`Learned <spell>`) requires its own spell in logic, so no plando is needed to avoid the classroom softlock.

Host the seed with `ArchipelagoServer.exe <seed zip>` (or `MultiServer.py` in the checkout) and connect the client to `localhost:38281`.

## One-time toolchain prep

1. Install the game from the disc into the reference folder (`D:\HP2\`) and install SafeDiscShim. Launch it once from the disc to confirm it starts, then never modify that folder again.
2. Copy the whole reference folder to the dev install (`C:\Games\HP2-Dev\`). A folder outside `Program Files` means no build or deploy step needs elevation.
3. From the AdamJD kit, put `UCC.exe` into `C:\Games\HP2-Dev\system\`. Rename the stock `Editor.dll` there to `Editor.dll.stock` and put the kit's `Editor.dll` beside it as `Editor.dll.kit`. The build swaps the kit DLL in for `UCC make` and the stock one back afterwards, so the game always runs the stock DLL.
4. If the game crashes when a level starts in fullscreen (`DDERR_SURFACELOST` on this machine, stock game too), set `StartupFullscreen=False` under `[WinDrv.WindowsClient]` in `Documents\Harry Potter II\Game.ini`.

No `EditPackages` editing by hand: the build script writes a private `System.ini` for UCC (the stock `default.ini` plus `EditPackages=HPArchipelago` after `HGame`), and the client's installer writes the runtime wiring (`DefaultGame=`, `Console=`, `ChannelDir=`).

## Build loop (UScript mod)

The machine-local `..\scripts\build_mod.ps1` (outside the repo; holds this machine's absolute paths, no elevation needed) runs the compile:

1. Edit UScript source under `mod/HPArchipelago/Classes/*.uc` in the repo.
2. Run the build:

   ```powershell
   powershell -ExecutionPolicy Bypass -File "..\scripts\build_mod.ps1"
   ```

   It mirrors `mod\HPArchipelago` to `C:\Games\HP2-Dev\HPArchipelago`, writes `System.ini`, deletes the old `HPArchipelago.u` (an incremental make keeps classes whose `.uc` was removed), swaps in the kit `Editor.dll`, runs `UCC.exe make ini=System.ini`, then restores the stock `Editor.dll` and every stock `.u` that `make` resaved (it rewrites `Core.u` among others) from the reference install. It ends with `BUILT HPArchipelago.u version=79 size=...` or `NOT BUILT`; the full log is `C:\Games\HP2-Dev\build\ucc_make.txt`.
3. Record the build as the canonical shipped package:

   ```powershell
   py -3.12 scripts/capture_mod.py 'C:\Games\HP2-Dev\System\HPArchipelago.u'
   ```

   This copies the package to `mod/Compiled/HPArchipelago.u` (the one `.u` in git) and writes the `HPArchipelago.u.sources` sha256 manifest next to it. It refuses to record a package whose mirrored source under `C:\Games\HP2-Dev\HPArchipelago\` differs from the repo's `mod/HPArchipelago/`, so a stale build can never become canonical.
4. Rebuild the apworld (`py -3.12 build_apworld.py`): it re-verifies the manifest, stages the package into `apworld/data/mod/`, zips, and installs to `custom_worlds`. The client deploys the staged package into player installs on connect (`apworld/installer.py`). Skipping capture + rebuild after a build leaves a stale apworld whose auto-install overwrites the fresh build on the next client connect.

Textures are imported from 8-bit palettized BMP (the kit's `Editor.dll` has no PNG importer). `scripts/png_to_bmp.py` converts the PNG sources, putting magenta at palette index 0 for chroma-keyed textures.

Every model and texture in `mod/HPArchipelago` is the project's own: none is extracted from the game. `tools/gen_wand_mesh.py` and `tools/gen_ghost_glasses.py` draw the giant wand and the ghost players' glasses from plain shapes; rerun them (then `png_to_bmp.py`) after changing either. Anything the mod shows from the game itself (card skins, spell glyphs, the silver key icon) is loaded by name from the player's install at runtime.

## Run loop

Connect the HP2 PC Client to a seed; with `install_folder` pointing at the dev install it deploys the mod and launches `C:\Games\HP2-Dev\system\Game.exe`. The disc check takes about half a minute, then pick New Game or Load Game in the main menu. Or start `Game.exe` yourself once the client is connected.

Logs:

- `Documents\Harry Potter II\Game.log`, current run, plain ANSI text. Only the current run is kept; copy it before relaunching if you need it.
- `C:\Games\HP2-Dev\system\Game.exe_SafeDiscShim.log`, the disc check.

To search the game log from PowerShell:

```powershell
Select-String -LiteralPath "$env:USERPROFILE\Documents\Harry Potter II\Game.log" -Pattern 'Archipelago'
```

Debug mode (the stock developer console keys, including the free camera on Delete) is `bDebugMode=True` under `[HGame.baseConsole]` in `Game.ini`. It is a global setting of the base console class, so the copies under `[HGame.HPConsole]` and `[HPArchipelago.APConsole]` do not apply.

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

This requires the apworld junction (see **Archipelago framework** section) so `worlds.harry_potter_2_pc` resolves to the repo's `apworld/` directory.

Alternative: `ArchipelagoLauncher.exe "HP2 PC Client"` runs the launcher entry point directly (Kivy GUI), same path users take.

### The game link

The game's engine has no networking, so the game and the client talk through files in `Documents\Harry Potter II\AP\` (`apworld/game_link.py`, `mod/HPArchipelago/Classes/APIPCActor.uc`):

- **Game to client:** the mod buffers lines and writes each batch as one closed `out_<session>_<n>.log` (a `StatLogFile` opened, written and closed in one go; UTF-16). The client reads only finished `.log` files.
- **Client to game:** the client rewrites `in.txt` (atomically, latin-1) with every `APIn <session> <seq> <+|=><fragment>` line the game has not acknowledged yet (200-character fragments), and the mod runs `exec "<ChannelDir>\in.txt"` every tick, which dispatches each line to `APConsole.APIn` and skips sequence numbers it already handled. The game acknowledges with `INACK <session> <seq>`, which lets the client drop those lines from the file.
- Both sides send keepalives; a link with no traffic for about 6 seconds counts as down, and each side buffers its outbound lines until it comes back.

## Fresh-PC bootstrap

If you clone this repo on a new Windows machine, do these in order:

1. Install Python 3.12 from python.org (or `winget install Python.Python.3.12`). The pinned 3.12 must be present even if a newer Python is installed. AP 0.6.7 supports 3.11/3.12/3.13, and 3.14+ is too new.
2. Clone HP2PC_AP and `Archipelago` (at the pinned tag) side by side.
3. Run the **One-time toolchain prep** section above.
4. Create the apworld junction (**Archipelago framework** section above).
5. Create the AP player files (**Player files** section above).
6. Read `../README.md` for the project overview and feature set.

## Known gotchas

Compiler (the AdamJD kit `UCC`, v79):

- **`var` declarations must come before every function** in a class; a `var` after a function fails with "'Var' is not allowed here".
- **No dynamic arrays** ("Array mismatch in array index"). Use fixed arrays.
- **A context expression cannot read a variable larger than 255 bytes** ("Variable is too large"), for example `class'X'.default.BigArray[i]` from another class. Add a static accessor on the owning class instead.
- **Some APIs seen in community examples do not exist in the game:** no `harry.iGameState` (use `ConvertGameStateToNumber()`), no `HGameButton`, `Material`, `AT_Center` or `CreateAlignedControl`. `menuBook` lives on `HPConsole`, not on the HUD.

Runtime:

- **A very long `Log()` line crashes the game** (an access violation jumping to `0x7f7f7f7f`; seen at about 2300 characters). Clip every payload you log with `APCsvCodec.LogClip` (200 characters).
- **A save refuses to write if a saved actor points outside the level** ("Graph is linked to external private object ..."): a reference into the Transient package (the console, UWindow pages) or into the Entry map. Mark such fields `transient`; the mod's console class is declared `transient` because stock actors keep a reference to the console.
- **A save-loaded level stays resident after travel** (it is named `Save0`). A singleton found through a class-default pointer can therefore be a leftover in `Save0`; the lazy `GetInstance(ctx)` helpers only accept an instance in the caller's level.
- **Never hold a `StatLogFile` open.** An open one locks the file against readers and leaks across level travel (its `Destroyed` never fires). Open, write, close per batch.
- **`ucc make` resaves stock packages** (`Core.u` and others). The build script restores them from the reference install; never run a build that skips that step against an install you play from.
- **`[Engine.GameEngine] ServerActors=` and `?Mutator=` are ignored.** Runtime hooks go through the `GameInfo` subclass named by `DefaultGame=HPArchipelago.APGameInfo`.
- **File encodings:** `Game.ini`, `User.ini` and `Default.ini` are ANSI with no BOM, and so is `Game.log`. The link's `out_*.log` batches are UTF-16 (written by `StatLogFile`).
- **The game runs as `Game.exe`** in the install's `system` folder; SafeDisc adds a short-lived `~e*.tmp` helper in `%TEMP%`. The main menu is a plain dialog (class `#32770`, localized title), and the engine window class ends in `WWindowsViewportWindow`.
- **The renderer does not survive a window resize.** Resizing past 2048 pixels wide crashes it, and smaller resizes break occlusion. The client sets the window size in `Game.ini` before launch and only clips and moves the window afterwards (`apworld/borderless.py`).
- **A force-closed game leaves `Documents\Harry Potter II\Running.ini` behind.** On the next start the engine treats the last run as a crash, runs its render-device detection (`Detected.log`) and can come up fullscreen at 640x480, where a level load can crash. Close the game normally, or delete `Running.ini` after killing it.
- **Third-party renderers and overlays** (texture upscalers, FPS overlays) can crash the engine. Disable them when chasing a crash.
