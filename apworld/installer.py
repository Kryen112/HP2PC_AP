"""Installs the HPArchipelago mod into a game install, from the client.

The packaged apworld carries one canonical compiled ``HPArchipelago.u`` under
``data/mod`` (staged and verified against its source-hash manifest by
build_apworld.py). ``deploy`` copies that package into the install's
``system`` folder and patches the config in place, backed up once first:

- ``[Engine.Engine]``: ``DefaultGame=`` points at the mod's GameInfo, the
  engine's one working entry point (ServerActors and ?Mutator= are ignored),
  and ``Console=`` at the mod's console, which carries the client link's
  inbound entry point.
- ``[HPArchipelago.APIPCActor]``: ``ChannelDir=`` names the folder the game
  and the client share (see game_link.py).

Both go into the install's ``system\\Default.ini``, which the first game launch
copies into the per-user ``Documents\\Harry Potter II\\Game.ini``, and into that
Game.ini when it already exists. Game.ini carries the player's own settings, so
it is patched in place, never replaced.

On Linux the game runs inside a Wine or Proton prefix, so its Documents folder
is the prefix's ``drive_c/users/<user>/Documents``, found from the install
path, and ``ChannelDir=`` carries the Windows form of that path (``C:\\users\\...``)
while the client reads the same folder through the prefix.

The ini files are ANSI. Reads detect a BOM anyway so an unexpectedly
re-encoded config stays editable. Idempotent: a second deploy writes nothing.

Standalone by design: no Archipelago imports, so the deploy contract tests
run against a plain temp directory.
"""
from __future__ import annotations

import os
import re
import shutil
import sys
from pathlib import Path, PureWindowsPath
from typing import Optional, Union

MOD_PACKAGE = "HPArchipelago"
MOD_PACKAGE_DATA = Path(__file__).parent / "data" / "mod" / f"{MOD_PACKAGE}.u"
BACKUP_DIR_NAME = "_archipelago_backup"
USER_INI_DIR_NAME = "Harry Potter II"
CHANNEL_DIR_NAME = "AP"

SECTION_HEADER = re.compile(r"^\s*\[.+\]\s*$")

ENGINE_SECTION = "[Engine.Engine]"
ENGINE_SETTINGS = (
    ("DefaultGame=", f"DefaultGame={MOD_PACKAGE}.APGameInfo"),
    ("Console=", f"Console={MOD_PACKAGE}.APConsole"),
)
LINK_SECTION = f"[{MOD_PACKAGE}.APIPCActor]"
CHANNEL_DIR_KEY = "ChannelDir="

# The game runs `exec "<ChannelDir>\in.txt"`, and the engine reads that file
# name into a short fixed buffer, so a long folder path is shortened.
MAX_CHANNEL_PATH_CHARS = 52


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


def _set_in_section(lines: "list[str]", section: str, key: str,
                    replacement: str) -> "list[str]":
    """The lines with the key's line inside the section replaced, added at the
    section's end when the section lacks it, and the section appended at the
    end of the file when the file lacks it."""
    out: "list[str]" = []
    in_section = False
    section_seen = False
    placed = False
    for existing in lines:
        if SECTION_HEADER.match(existing):
            if in_section and not placed:
                while out and not out[-1].strip():
                    out.pop()
                out.extend([replacement, ""])
                placed = True
            in_section = existing.strip().lower() == section.lower()
            section_seen = section_seen or in_section
        if in_section and existing.startswith(key):
            if not placed:
                out.append(replacement)
                placed = True
            continue
        out.append(existing)
    if not placed:
        if in_section:
            while out and not out[-1].strip():
                out.pop()
            out.append(replacement)
        else:
            if out and out[-1].strip():
                out.append("")
            out.extend([section, replacement])
    return out


def _wired_lines(lines: "list[str]", channel: str) -> "list[str]":
    """The ini lines pointed at the mod and the channel folder."""
    out = lines
    for key, replacement in ENGINE_SETTINGS:
        out = _set_in_section(out, ENGINE_SECTION, key, replacement)
    return _set_in_section(out, LINK_SECTION, CHANNEL_DIR_KEY, CHANNEL_DIR_KEY + channel)


def _wire_ini(path: Path, channel: str) -> bool:
    """Point the ini at the mod and the channel folder. Returns whether the
    file changed."""
    lines = _read_ini_lines(path)
    out = _wired_lines(lines, channel)
    if out == lines:
        return False
    _write_ini_lines(path, out)
    return True


def _ini_is_wired(path: Path, channel: str) -> bool:
    lines = _read_ini_lines(path)
    return _wired_lines(lines, channel) == lines


def _on_windows() -> bool:
    return sys.platform.startswith("win")


def wine_prefix(install_dir: Union[str, Path]) -> Optional[Path]:
    """The Wine or Proton prefix an install lives in (the folder holding
    ``drive_c``), or None when it is not inside one."""
    install_dir = Path(install_dir)
    drive_c = next((parent for parent in [install_dir, *install_dir.parents]
                    if parent.name.lower() == "drive_c"), None)
    return drive_c.parent if drive_c is not None else None


def _prefix_documents(install_dir: Union[str, Path]) -> Path:
    """The Documents folder of the Wine or Proton prefix the install lives in:
    ``drive_c/users/<user>/Documents`` (``My Documents`` in older prefixes).
    The user that already has a Harry Potter II folder wins, then the only
    user, then Proton's ``steamuser``. Raises ValueError when the install is
    not inside a prefix or the prefix has no user to pick."""
    prefix = wine_prefix(install_dir)
    if prefix is None:
        raise ValueError(
            f"{install_dir} is not inside a Wine or Proton prefix (no drive_c folder above it)")
    drive_c = next((entry for entry in prefix.iterdir() if entry.name.lower() == "drive_c"), None)
    if drive_c is None:
        raise ValueError(f"{prefix} has no drive_c folder")
    users_dir = drive_c / "users"
    users = sorted(entry for entry in users_dir.iterdir()
                   if entry.is_dir() and entry.name.lower() != "public") if users_dir.is_dir() else []

    def documents_of(user: Path) -> Path:
        for name in ("Documents", "My Documents"):
            if (user / name).is_dir():
                return user / name
        return user / "Documents"

    for user in users:
        if (documents_of(user) / USER_INI_DIR_NAME).is_dir():
            return documents_of(user)
    if len(users) == 1:
        return documents_of(users[0])
    for user in users:
        if user.name == "steamuser":
            return documents_of(user)
    raise ValueError(
        f"cannot tell which user in {users_dir} runs the game; launch the game once "
        f"so it creates its Documents\\{USER_INI_DIR_NAME} folder, then try again")


def _user_ini_dir(install_dir: Optional[Union[str, Path]] = None) -> Path:
    """The per-user config dir holding Game.ini and the saves. The engine
    resolves it through the Windows Documents folder, so honor a relocated
    (e.g. OneDrive) Documents via the shell folders registry key, with a
    plain home Documents fallback. Off Windows it is inside the install's
    prefix, so the install is required there."""
    if not _on_windows():
        if install_dir is None:
            raise ValueError("the game's Documents folder is found from its install folder")
        return _prefix_documents(install_dir) / USER_INI_DIR_NAME
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


def channel_dir(install_dir: Optional[Union[str, Path]] = None) -> Path:
    """The folder the game and the client share, as the client reaches it."""
    return _user_ini_dir(install_dir) / CHANNEL_DIR_NAME


def _game_side_path(channel: Path) -> str:
    """The channel folder as the game is handed it: on Windows the path itself
    (shortened when too long); inside a prefix the Windows form under C:."""
    if _on_windows():
        return _short_path(channel)
    parts = channel.parts
    drive_c_at = max(index for index, part in enumerate(parts) if part.lower() == "drive_c")
    return str(PureWindowsPath("C:\\", *parts[drive_c_at + 1:]))


def _short_path(path: Path) -> str:
    """The path as the engine is handed it: the Windows 8.3 short form when the
    long one is too long for the engine's file name buffer and the volume has
    short names."""
    text = str(path)
    if len(text) <= MAX_CHANNEL_PATH_CHARS:
        return text
    try:
        import ctypes
        buffer = ctypes.create_unicode_buffer(1024)
        if ctypes.windll.kernel32.GetShortPathNameW(text, buffer, len(buffer)):
            return buffer.value
    except (ImportError, AttributeError, OSError):
        pass
    return text


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

    # Resolved first: a prefix the folder cannot be found in fails before
    # anything is written.
    channel = channel_dir(install_dir)

    log: "list[str]" = []
    target = system_dir / f"{MOD_PACKAGE}.u"
    if not target.is_file() or target.read_bytes() != module_bytes:
        target.write_bytes(module_bytes)
        log.append("Copied the compiled mod package.")

    channel.mkdir(parents=True, exist_ok=True)
    channel_text = _game_side_path(channel)
    if len(channel_text) > MAX_CHANNEL_PATH_CHARS:
        log.append(
            f"WARNING: the game link folder {channel_text} is longer than the game "
            f"can open ({MAX_CHANNEL_PATH_CHARS} characters) and this drive has no "
            f"short names for it, so the game may not hear the client.")

    _backup_once(install_dir / BACKUP_DIR_NAME, default_ini)
    if _wire_ini(default_ini, channel_text):
        log.append("Pointed Default.ini at the mod.")

    game_ini = _user_ini_dir(install_dir) / "Game.ini"
    if game_ini.is_file():
        _backup_once(game_ini.parent / BACKUP_DIR_NAME, game_ini)
        if _wire_ini(game_ini, channel_text):
            log.append("Pointed the per-user Game.ini at the mod.")
    return log


WINDOW_SECTION = "[WinDrv.WindowsClient]"


def set_windowed_size(install_dir: Path, width: int, height: int) -> bool:
    """Make the game start windowed at width by height: in the per-user
    Game.ini, or in Default.ini before the first launch creates Game.ini.
    Returns whether a file changed."""
    install_dir = Path(install_dir)
    game_ini = _user_ini_dir(install_dir) / "Game.ini"
    if game_ini.is_file():
        target, backup_dir = game_ini, game_ini.parent / BACKUP_DIR_NAME
    else:
        target, backup_dir = install_dir / "system" / "Default.ini", install_dir / BACKUP_DIR_NAME
    if not target.is_file():
        raise FileNotFoundError(f"{target} not found; is this a Harry Potter 2 install?")
    lines = _read_ini_lines(target)
    out = lines
    for key, value in (("WindowedViewportX=", width), ("WindowedViewportY=", height),
                       ("StartupFullscreen=", "False")):
        out = _set_in_section(out, WINDOW_SECTION, key, f"{key}{value}")
    if out == lines:
        return False
    _backup_once(backup_dir, target)
    _write_ini_lines(target, out)
    return True


def mod_is_current(install_dir: Path) -> bool:
    """Whether the install already runs this apworld's package, byte for byte,
    with Default.ini and an existing per-user Game.ini wired to it. An apworld
    packaged without a mod counts as current, so it can never trigger an
    install loop."""
    module_bytes = _packaged_module_bytes()
    if module_bytes is None:
        return True
    system_dir = Path(install_dir) / "system"
    try:
        channel = _game_side_path(channel_dir(install_dir))
        if (system_dir / f"{MOD_PACKAGE}.u").read_bytes() != module_bytes:
            return False
        if not _ini_is_wired(system_dir / "Default.ini", channel):
            return False
        game_ini = _user_ini_dir(install_dir) / "Game.ini"
        return not game_ini.is_file() or _ini_is_wired(game_ini, channel)
    except (OSError, ValueError):
        return False
