"""Installs the HPArchipelago mod into a game install, from the client.

The packaged apworld carries one canonical compiled ``HPArchipelago.u`` under
``data/mod`` (staged and verified against its source-hash manifest by
build_apworld.py). ``deploy`` copies that package into the install's
``system`` folder and patches the config in place, backed up once first:

- ``system\\Default.ini``: the mod's EditPackages entries land immediately
  after ``EditPackages=M212Share`` (the list's last stock entry; the file
  continues past it with graphics-adapter sections, so appending at end of
  file or end of section would land them in the wrong place), and
  ``[Engine.Engine]`` ``DefaultGame=`` points at the mod's GameInfo, the
  engine's one working entry point (ServerActors and ?Mutator= are ignored).
- The per-user overrides in ``Documents\\Harry - Coding Evolved``: the first
  game launch copies Default.ini's package list into ``HP.ini``, and
  ``Game.ini`` can carry its own ``DefaultGame``; either shadows a patched
  Default.ini back to vanilla. Both are patched in place when they exist,
  never deleted, because they also hold the player's own settings.

The ini files are ANSI; the game log is the UTF-16 file. Reads detect a BOM
anyway so an unexpectedly re-encoded config stays editable. Idempotent: a
second deploy writes nothing.

Standalone by design: no Archipelago imports, so the deploy contract tests
run against a plain temp directory.
"""
from __future__ import annotations

import os
import re
import shutil
from pathlib import Path

MOD_PACKAGE = "HPArchipelago"
MOD_PACKAGE_DATA = Path(__file__).parent / "data" / "mod" / f"{MOD_PACKAGE}.u"
BACKUP_DIR_NAME = "_archipelago_backup"
USER_INI_DIR_NAME = "Harry - Coding Evolved"

SECTION_HEADER = re.compile(r"^\s*\[.+\]\s*$")

EDIT_PACKAGES_ANCHOR = "EditPackages=M212Share"
EDIT_PACKAGES_ADDED = ("EditPackages=IpDrv", f"EditPackages={MOD_PACKAGE}")

ENGINE_SECTION = "[Engine.Engine]"
DEFAULT_GAME_KEY = "DefaultGame="
DEFAULT_GAME_ARCHIPELAGO = f"DefaultGame={MOD_PACKAGE}.APGameInfo"


def _packaged_module_bytes() -> "bytes | None":
    """The canonical compiled package carried by the apworld. Reads the data
    directory directly from a source checkout, or through importlib.resources
    when the world is zipimported from a packaged .apworld."""
    if MOD_PACKAGE_DATA.is_file():
        return MOD_PACKAGE_DATA.read_bytes()
    from importlib import resources
    entry = resources.files(__package__) / "data" / "mod" / f"{MOD_PACKAGE}.u"
    try:
        return entry.read_bytes()
    except (FileNotFoundError, NotADirectoryError):
        return None


def _ini_encoding(path: Path) -> str:
    """The config files are ANSI, but a re-encoded file announces itself with
    a BOM; detecting that keeps it editable. Anything else reads as latin-1,
    which round-trips every byte, so a stray non-ASCII character can never
    corrupt a rewrite."""
    with path.open("rb") as handle:
        head = handle.read(2)
    if head in (b"\xff\xfe", b"\xfe\xff"):
        return "utf-16"
    return "latin-1"


def _read_ini_lines(path: Path) -> "list[str]":
    return path.read_text(encoding=_ini_encoding(path)).splitlines()


def _write_ini_lines(path: Path, lines: "list[str]") -> None:
    encoding = _ini_encoding(path) if path.is_file() else "latin-1"
    # newline="" turns off the text-mode translation that would turn the
    # explicit \r\n into \r\r\n on Windows.
    with path.open("w", encoding=encoding, newline="") as handle:
        handle.write("\r\n".join(lines) + "\r\n")


def _backup_once(backup_dir: Path, path: Path) -> None:
    backup_dir.mkdir(exist_ok=True)
    destination = backup_dir / path.name
    if path.is_file() and not destination.exists():
        shutil.copy2(path, destination)


def _wire_edit_packages(path: Path, require_anchor: bool) -> "bool | None":
    """Place the mod's EditPackages entries immediately after the M212Share
    entry, normalizing any that sit elsewhere. Returns whether the file
    changed, or None when the anchor is missing and not required."""
    lines = _read_ini_lines(path)
    kept = [line for line in lines if line not in EDIT_PACKAGES_ADDED]
    if EDIT_PACKAGES_ANCHOR not in kept:
        if require_anchor:
            raise ValueError(
                f"{EDIT_PACKAGES_ANCHOR} not found in {path.name}; is this an "
                f"M212 install?")
        return None
    anchor = len(kept) - 1 - kept[::-1].index(EDIT_PACKAGES_ANCHOR)
    out = kept[:anchor + 1] + list(EDIT_PACKAGES_ADDED) + kept[anchor + 1:]
    if out == lines:
        return False
    _write_ini_lines(path, out)
    return True


def _set_line_in_section(path: Path, section: str, key: str, replacement: str,
                         require: bool = False) -> "bool | None":
    """Rewrite the key's line inside the section. Returns whether the file
    changed, or None when the section holds no such key and none is required
    (an absent key falls through the override chain, so there is nothing to
    fix)."""
    lines = _read_ini_lines(path)
    out: "list[str]" = []
    in_section = False
    found = False
    changed = False
    for existing in lines:
        if SECTION_HEADER.match(existing):
            in_section = existing.strip().lower() == section.lower()
        if in_section and existing.startswith(key):
            found = True
            if existing != replacement:
                out.append(replacement)
                changed = True
                continue
        out.append(existing)
    if not found:
        if require:
            raise ValueError(f"{key} not found under {section} in {path.name}")
        return None
    if changed:
        _write_ini_lines(path, out)
    return changed


def _user_ini_dir() -> Path:
    """The per-user config dir holding HP.ini and Game.ini. The engine
    resolves it through the Windows Documents folder, so honor a relocated
    (e.g. OneDrive) Documents via the shell folders registry key, with a
    plain home Documents fallback."""
    try:
        import winreg
        with winreg.OpenKey(
                winreg.HKEY_CURRENT_USER,
                r"Software\Microsoft\Windows\CurrentVersion\Explorer"
                r"\User Shell Folders") as key:
            documents = Path(os.path.expandvars(winreg.QueryValueEx(key, "Personal")[0]))
    except (ImportError, OSError):
        documents = Path.home() / "Documents"
    return documents / USER_INI_DIR_NAME


def deploy(install_dir: Path) -> "list[str]":
    """Deploy the compiled mod package into the install and wire the config,
    stock and per-user. Returns log lines."""
    install_dir = Path(install_dir)
    system_dir = install_dir / "system"
    default_ini = system_dir / "Default.ini"
    if not default_ini.is_file():
        raise FileNotFoundError(
            f"{default_ini} not found; is this a Harry Potter 2 install?")
    module_bytes = _packaged_module_bytes()
    if module_bytes is None:
        raise FileNotFoundError(
            "no compiled mod package in the apworld; it was packaged without data/mod")

    log: "list[str]" = []
    target = system_dir / f"{MOD_PACKAGE}.u"
    if not target.is_file() or target.read_bytes() != module_bytes:
        target.write_bytes(module_bytes)
        log.append("Copied the compiled mod package.")

    _backup_once(install_dir / BACKUP_DIR_NAME, default_ini)
    if _wire_edit_packages(default_ini, require_anchor=True):
        log.append("Added the mod to Default.ini's package list.")
    if _set_line_in_section(default_ini, ENGINE_SECTION, DEFAULT_GAME_KEY,
                            DEFAULT_GAME_ARCHIPELAGO, require=True):
        log.append("Pointed Default.ini's DefaultGame at the mod.")

    _wire_user_inis(log)
    return log


def _wire_user_inis(log: "list[str]") -> None:
    """Apply the Default.ini wiring to the per-user override files in place.
    They carry the player's own settings, so they are patched, never
    deleted."""
    user_dir = _user_ini_dir()
    hp_ini = user_dir / "HP.ini"
    if hp_ini.is_file():
        _backup_once(user_dir / BACKUP_DIR_NAME, hp_ini)
        changed = _wire_edit_packages(hp_ini, require_anchor=False)
        if changed:
            log.append("Wired the mod into the per-user HP.ini in place.")
        elif changed is None and any(
                line.startswith("EditPackages=") for line in _read_ini_lines(hp_ini)):
            log.append(
                f"WARNING: {hp_ini} carries a package list this installer does "
                f"not recognize, and it shadows Default.ini; delete that file "
                f"and launch again.")
        if _set_line_in_section(hp_ini, ENGINE_SECTION, DEFAULT_GAME_KEY,
                                DEFAULT_GAME_ARCHIPELAGO):
            log.append("Pointed the per-user HP.ini's DefaultGame at the mod.")
    game_ini = user_dir / "Game.ini"
    if game_ini.is_file():
        _backup_once(user_dir / BACKUP_DIR_NAME, game_ini)
        if _set_line_in_section(game_ini, ENGINE_SECTION, DEFAULT_GAME_KEY,
                                DEFAULT_GAME_ARCHIPELAGO):
            log.append("Pointed the per-user Game.ini's DefaultGame at the mod.")


def mod_is_current(install_dir: Path) -> bool:
    """Whether the install already runs this apworld's package, byte for byte.
    An apworld packaged without a mod counts as current, so it can never
    trigger an install loop."""
    module_bytes = _packaged_module_bytes()
    if module_bytes is None:
        return True
    installed = Path(install_dir) / "system" / f"{MOD_PACKAGE}.u"
    try:
        return installed.read_bytes() == module_bytes
    except OSError:
        return False
