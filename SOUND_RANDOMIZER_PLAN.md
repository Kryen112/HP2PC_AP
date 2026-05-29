# Sound randomizer (HP2 AP)

## Context

The mod already has a music randomizer: it rewrites `NewMusicTrigger.Song` strings at
runtime, per AP seed. The user wants the same idea for sound effects: randomize all
non-music SFX. Exploration showed sound is the opposite of music in this engine, so the
mechanism has to be completely different.

Why music's approach cannot work for SFX:
- SFX are compiled `Sound'HPSounds.Group.Name'` **object references**, not filename strings.
- ~67% of the 523 `PlaySound` call sites pass an inline `Sound'...'` literal hardcoded at
  the call site, and `PlaySound` is native. Those references cannot be intercepted or
  rewritten from UScript at runtime. There is no `NewSoundTrigger` actor to iterate.
- The only lever that affects an inline literal is changing what the name resolves to
  **inside the package**, which is fixed once the package is loaded.

Decision (chosen by user): per-seed **binary patch** of the SFX package. This is pure-Python
byte manipulation in the apworld/client. No UScript, no C/C++, so it stays inside the
project's avoid-native-code line. Notably this feature needs **zero mod changes**.

Target file: `<install>/system/HPSounds.u` (a UE1 code package that embeds the ~1,114 Sound
objects via `#exec Audio Import` in `HPSounds/Classes/PackSounds.uc`). There is no
`HPSounds.uax`; `AllDialog.uax` is voices only and is out of scope for v1.

## Locked decisions

- **Mechanism**: per-seed binary patch of `HPSounds.u`. Repoint each `USound` export to a
  different one's audio data so every `Sound'HPSounds.Group.Name'` reference (inline literals
  included) resolves to a shuffled waveform. Object names never change.
- **Scope v1**: SFX only (`HPSounds.u`). Dialogue (`AllDialog.uax`) is a planned Phase 5
  follow-up, committed separately after v1 lands.
- **Shuffle key is `(group, name)`, not name**: basenames collide across groups
  (`HAR_foot_wood3` appears in 9 groups, `spiral_up_elevator` in 2), so the table, the
  permutation, and the export lookup all key on `(group, name)`. The tripwire asserts
  `(group, name)` uniqueness, not name uniqueness.
- **Shuffle rules**: bijection within buckets keyed on **duration-band only**; shuffle
  broadly across all 28 groups inside each bucket.
  - No loop-class split. Looping is a property of the call site in this engine
    (`AmbientSound` actors loop, `PlaySound()` plays once), not of the `USound` object, so a
    shuffled sound can land on an `AmbientSound` and loop. We accept that: a looped sound can
    be funny, and anything genuinely annoying gets blacklisted during playtest rather than
    pre-classified now.
  - Duration bands keep a short sound short. Thresholds (measured from a WAV-header scan of
    all 1,114 sounds, median 1.50s): **short `<= 3s` (855 sounds)**, **medium `> 3s and
    < 10s` (193)**, **long `>= 10s` (66, up to 62.9s, mostly `AMB_*` ambiences)**. A short
    footstep can only become another short sound, so rapid `SLOT_None` sounds
    (`harry.uc:2581`) cannot pile a multi-second clip into noise.
- **Blacklist (first-class)**: `sound_pool.py` carries a blacklist that starts empty. A
  blacklisted sound is identity-mapped: excluded from the shuffle and its data left
  untouched, so it always resolves to itself. This is the playtest lever for sounds that turn
  out annoying (a looped ambience, a feedback cue the mod relies on). Grown by editing the
  list, same as the music pools.
- **Permutation source**: per-slot `sound_seed` rolled from `self.random` at generation,
  shipped in slot_data (mirrors `music_seed`). The client recomputes the permutation from the
  seed plus its local `sound_pool.py`. Deterministic and reproducible.
- **Install path**: AP `settings.Group` with one `UserFolderPath` per game mode in host.yaml
  (`vanilla_install_folder`, `open_castle_install_folder`), since a player may run separate
  vanilla and open castle installs. No default and `required = False` (never ship a real
  machine's path, and skip AP's auto-browse, which would not fire anyway since an empty value
  resolves to the existing AP folder). Instead, when a sound seed is on and the mode's install
  is unset or wrong, the client pops a folder picker once, validates it contains
  `system/HPSounds.u`, and persists the choice to host.yaml via `get_settings().save()` so the
  player picks once per mode. Read offline, so restore works without a server. The client
  patches the install matching the seed's `game_mode`; it has no install knowledge over its TCP
  link to the mod, so this is how it learns the path.
- **Apply trigger**: AP `Connected` (the path comes from host.yaml, so applying is
  game-independent). Connecting the client **before** launching the game means the patched
  package is loaded on first launch: zero restarts. If the game is already up, the running
  process already loaded the package, so the patch lands on the next launch: one restart,
  with a `TOAST` over the existing IPC line opportunistically.
- **Patched-state marker (sentinel trailer)**: option A leaves file size and object names
  unchanged, so neither detects a patched file. Append a sentinel trailer carrying
  `(patch-format version, table-hash, sound_seed)`. On connect:
  - trailer matches current `(format, table-hash, sound_seed)`: already patched, write
    nothing (idempotent).
  - trailer present but `table-hash` or `sound_seed` differs (apworld upgraded, or different
    seed): re-patch from `.orig`.
  - no trailer: file is pristine original (see backup integrity).
- **Wire payload**: `sound_seed` only. The table stays in the apworld. Two machines get the
  identical shuffle only when they run the **same apworld version**; SFX are local cosmetic
  effects, so version-dependent shuffles are acceptable (same tradeoff as `music_pool.py`).
- **Reversibility** (off-ramp): client restores from `.orig` whenever it connects to a
  non-sound seed, AND there is a standalone "restore original sounds" client command (sweeping
  every configured install) plus a documented manual `.orig` copy, so the player can revert
  without going back through AP.
  Restore is symmetric with apply: the running game already loaded the patched package, so a
  restore only takes effect on the next launch. The install stays patched between sessions
  until something restores it; we accept that and make the off-ramp obvious rather than
  auto-cleaning on exit.
- **Backup integrity**: a file with **no trailer is pristine original and authoritative**.
  - `.orig` is taken or refreshed from any no-trailer working file. This auto-handles a game
    reinstall: the fresh original file has no trailer, so it becomes the new `.orig`.
  - `.orig` is only ever written from a verified no-trailer file. A trailer-bearing (patched)
    file can never become the backup.
  - Patching always reads from `.orig`, never from an already-patched working file, so a
    patched state can never compound.

## Phase 0: package-format spike (go/no-go, do first)

The linchpin. UE1 `USound` data is very likely a `TLazyArray<BYTE>` with an **absolute**
SkipOffset, so naively swapping each export's `(serialOffset, serialSize)` will misread the
lazy header and corrupt loading. Resolve this before building anything else.

1. Write a Python reader for the UE1 package format: header (magic `0x9E2A83C1`, version,
   name/import/export counts+offsets), name table, import table, export table. Consult
   `M212 HP2 Editor_Engine Info and FAQs.md` for the M212 package version specifics.
2. Enumerate `USound` exports in `HPSounds.u`; dump name, group (outer), serial offset/size.
3. **Reconcile names**: diff the generated `PackSounds.uc` name+group list against this actual
   export-table dump. They must agree before the table can drive a patch.
4. Round-trip test: re-serialize unchanged -> byte-identical file. Then identity-permutation
   patch -> game still loads and plays the original sounds. (User runs the game; confirm.)
5. **Trailer tolerance**: confirm UE1 ignores bytes appended after the package payload (load
   a file with a sentinel trailer; game still loads). If it does not tolerate trailing bytes,
   fall back to detecting patched state by hashing against a bundled known-original signature
   instead of an appended trailer.
6. Determine the repoint mechanics:
   - **A (preferred, simplest)**: rewrite only export `(offset,size)` fields, plus fix the
     lazy-array SkipOffset inside each repointed blob if present. File size unchanged, tiny
     edit.
   - **B (fallback)**: full package rewrite, recomputing every export offset and lazy
     SkipOffset for a permuted data layout. More code, fully robust.
7. **Go/no-go**: if neither A nor B is tractable, per-seed SFX rando is blocked; the only
   fallback is a static UCC recompile of `HPSounds.u` with shuffled `#exec` imports (loses
   per-seed, needs UCC+wavs at build), which contradicts the chosen design. Bring back to user.

### Phase 0 result: GO (verified in-game 2026-05-29)

Spike lives in `tools/ue1_package.py` (reader) + `tools/phase0_spike.py` (driver). Findings:
- UE1 package **version 79**, 1114 USound exports, reconciling exactly with `PackSounds.uc`.
- **Mechanic A, even simpler than expected**: rewrite each USound export's
  `(serial_offset, serial_size)` to the permutation target's; leave all audio bytes in place.
  No data movement and **no SkipOffset fixup**. Each block is self-contained (the bytes after
  the format name are constant per format, not a per-object absolute offset), regions never
  overlap, and identity-permutation reproduces the file byte-for-byte. A permutation also
  preserves file size exactly, which is why size cannot flag a patched file (hence the trailer).
- **Trailer tolerated**: the engine loads a package with a sentinel trailer appended, so the
  trailer marker stands and the original-signature fallback is unnecessary.
- A full shuffle loads and plays in-game; object names never change.
- **Live install differs from the repo copy** (see Risks): tooling must target the live file.

## Phase 1: sound classification table

Build `apworld/sound_pool.py` (analogous to `apworld/music_pool.py`), a frozen table of every
SFX as `(group, name) -> duration_band`, plus a blacklist of `(group, name)` pairs that are
identity-mapped. Ship it in the apworld so the client recomputes the permutation from just the
`sound_seed`.

Generate it with a new `tools/gen_sound_pool.py` (analogous to the existing `tools/`
generators) that reads:
- `HP2UScriptDecompile/HPSounds/Classes/PackSounds.uc` -> authoritative name+group list (the
  `#exec Audio Import File=... Group=...` lines; Name defaults to wav basename).
- `HP2UScriptDecompile/HPSounds/Sounds/**/*.wav` -> per-wav duration (parse WAV header) for the
  duration band. The generator parses WAV headers once at generation time; the client never
  touches WAVs.

Import-time tripwires like `music_pool.py`: non-empty buckets, every `(group, name)` unique,
blacklist entries all present in the table.

## Phase 2: option + slot_data

In `apworld/__init__.py`:
- Add `class SoundRandomizer(Toggle)` with a docstring matching `MusicRandomizer`'s style
  (pure runtime, no fill/logic impact, deterministic per seed).
- Add `sound_randomizer` to `HP2Options`.
- In `fill_slot_data`, when on, add `sound_randomizer: True` and
  `sound_seed: self.random.randint(0, 2**31 - 1)` (suppressed when off), mirroring the music
  block. No pools on the wire: the client has `sound_pool.py`.

## Phase 3: client patcher

New `apworld/sound_patch.py` (pure Python, importable by `Client.py`):
- `compute_permutation(sound_seed)`: import `sound_pool.py`, seeded Fisher-Yates shuffle of
  each duration-band bucket over its `(group, name)` keys, identity-map every blacklist entry,
  return `(group, name) -> (group, name)` mapping.
- `apply_patch(install_path, permutation)`: locate `system/HPSounds.u`; ensure a pristine
  `.orig` exists (take it from a no-trailer working file); parse export table; map
  `(group, name)` -> exports; rewrite per Phase 0's chosen mechanic; append the sentinel
  trailer `(format, table-hash, sound_seed)`; write atomically (temp + replace). Always patch
  from `.orig`. Keys absent from the package are left untouched (defensive).
- `restore_original(install_path)`: copy `.orig` back over `HPSounds.u`. No-op if `.orig`
  absent (install was never patched).
- `read_trailer(path)` / `table_hash()`: helpers for the idempotency and version-skew checks.
- Backup integrity per the locked decision: `.orig` written only from a verified no-trailer
  file, never from a patched file.
- Expose a standalone restore entry point (a client command) that calls `restore_original`
  without connecting to a seed.

Install path: read from AP `settings.Group` (host.yaml), one `UserFolderPath` per game mode,
no default. The client picks the field matching the seed's `game_mode`, prompting once via a
folder picker (and saving to host.yaml) when it is unset/wrong; the standalone restore sweeps
every configured install. Both read it offline.

## Phase 4: wire into Client + UX + docs

In `apworld/Client.py`:
- New context fields `sound_randomizer_enabled` / `sound_seed`, parsed from slot_data on
  Connected (mirror the music block at `Client.py:576`).
- On Connected: resolve the install path for the seed's game mode from host.yaml settings,
  prompting once via a folder picker (and persisting it) if unset. If enabled,
  `compute_permutation` + `apply_patch`. The trailer makes this idempotent: if the file
  already carries the matching trailer, nothing is written and no restart is prompted. If a
  change was written, surface a message keyed on game state. Connected-before-launch means the
  next launch is already patched (no extra restart); game-already-up means "Restart Harry
  Potter to hear it" in the client log and a `TOAST` over IPC. If off (or key absent),
  `restore_original` and prompt the same restart-once only if it changed anything. Guard on a
  configured install path; warn clearly if unset.

Docs (`docs/PLAYER_SETUP.md`): add the `sound_randomizer` option row, the per-mode install-path
(host.yaml `vanilla_install_folder` / `open_castle_install_folder`, no default) config step, the
connect-before-launch note (and the one restart if the game was already running), and a "revert
to the original sounds" section (off-seed
auto-restore, the restore command, and the manual `HPSounds.u.orig` copy).

## Phase 5 (separate later commit): dialogue randomizer

After v1 is committed. Same binary-patch machinery applied to `AllDialog.uax`. Dialogue is
loaded by string via `DynamicLoadObject("AllDialog." $ id, class'Sound')` (`baseDialog.uc:34`),
so a runtime per-seed swap may also be viable there; evaluate both when we get to it. Expect
subtitle/lip-sync mismatch as the inherent cost. Its own option + table + commit.

## Critical files

- `apworld/__init__.py` - option + `fill_slot_data` (pattern: existing `MusicRandomizer` /
  music block).
- `apworld/Client.py` - slot_data parse + apply-on-connect, install path from settings
  (pattern: music block ~`:576`, HELLO re-arm ~`:1069`).
- `apworld/sound_pool.py` (new) - frozen `(group, name) -> duration_band` table + blacklist
  (pattern: `apworld/music_pool.py`).
- `apworld/sound_patch.py` (new) - package reader + permutation + patch/backup/restore +
  sentinel trailer.
- `tools/gen_sound_pool.py` (new) - builds `sound_pool.py` from `PackSounds.uc` + wav headers.
- `docs/PLAYER_SETUP.md` - option row, install-path config, connect-before-launch note.
- Inputs (read-only): `system/HPSounds.u` (patch target), `HP2UScriptDecompile/HPSounds/...`
  (names, wavs), `M212 HP2 Editor_Engine Info and FAQs.md` (package format).

## Risks

- **Package format (highest)**: lazy-array absolute offsets may block the simple repoint.
  Phase 0 is the explicit go/no-go gate before any feature code.
- **Trailer tolerance**: if UE1 rejects trailing bytes, patched-state detection falls back to
  a bundled original signature hash. Phase 0 step 5 settles this.
- **File locked by the running game (Windows)**: an atomic temp + replace can fail if the game
  holds `HPSounds.u` open. The client must handle replace failure gracefully (report it and
  ask the player to close the game) rather than leaving a half-written package.
- **Non-stock / multi-build install (confirmed real)**: the live Bingo install
  (`C:\Program Files (x86)\Harry Potter 2\Bingo\system\HPSounds.u`, ~149 MB) is a different,
  larger build than the repo copy (~44 MB). Both expose the same 1114 sounds reconciling with
  `PackSounds.uc`, but offsets and sizes differ, so patch artifacts are not interchangeable
  across builds. Because mechanic A permutes only that file's own export pointers and moves no
  data, it is build-agnostic by construction (it reads the install's real export table at apply
  time, whatever the build). The generator can take durations from the standalone decompile
  wavs (duration is intrinsic and survives re-encoding), so it does not need to parse the live
  package; only apply-time patching touches the install file.
- **Install path discovery**: client gains a "write into the game install" capability; needs
  the configured host.yaml path and careful atomic writes + backup so a failed patch never
  bricks the package.
- **Install left patched between sessions**: accepted tradeoff (no auto-clean on exit). Relies
  on a pristine `.orig` and an obvious restore off-ramp; restore also needs one restart.
- **Table drift**: `sound_pool.py` changes shift permutations across apworld versions (same
  tradeoff as `music_pool.py`); acceptable, and the trailer's table-hash triggers a clean
  re-patch on upgrade.

## Verification

1. Phase 0 round-trip: identity patch -> byte-identical / game loads original sounds (user-run);
   trailer-bearing file still loads (or signature fallback chosen).
2. Generator: `sound_randomizer` on/off seeds generate cleanly (fuzzer); `Generate.py` needs
   `< NUL`.
3. In-game (user-run): connect a sound-on seed, confirm SFX are shuffled but not broken;
   confirm two machines on the same seed **and same apworld version** get the identical
   shuffle.
4. Reversibility (user-run): after a randomized session, connect an off seed (or run the
   restore command) and confirm a restart returns the original SFX byte-for-byte; confirm switching
   between two different sound seeds re-patches from pristine (no compounding); confirm an
   apworld upgrade (table-hash change) re-patches cleanly; confirm the manual `.orig` copy
   works.
5. Determinism: same `sound_seed` + same apworld version -> identical patched bytes.
