"""Borderless fullscreen for the game's window.

The game's own fullscreen switches the display mode, which modern Windows
rejects mid-game. The game runs windowed instead: before launch the client
sets the windowed resolution to the monitor's size (see windowed_size), and
once the game runs it hides the window's frame and centers the picture on the
monitor.

The renderer rebuilds its drawing surfaces whenever the window changes size or
style, and a rebuilt renderer draws see-through textures solid, shows objects
through walls, or crashes. So the frame is hidden without touching either: the
compositor stops drawing the frame, a window region clips the window to the
area the game draws in, and the window moves so that area is centered.

Windows only: pure ctypes, no game files.
"""

from __future__ import annotations

import ctypes
from ctypes import wintypes

MONITOR_DEFAULTTONEAREST = 2
SWP_NOSIZE = 0x0001
SWP_NOZORDER = 0x0004
SWP_NOACTIVATE = 0x0010
SWP_NOOWNERZORDER = 0x0200
SIMPLEREGION = 2
DWMWA_NCRENDERING_POLICY = 2
DWMNCRP_USEWINDOWSTYLE = 0
DWMNCRP_DISABLED = 1
DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = -4
SM_CXSCREEN = 0
SM_CYSCREEN = 1
DEFAULT_DPI = 96

# The widest windowed resolution the engine opens; it replaces a wider one
# with its own choice.
MAX_WINDOW_WIDTH = 2048


class _MonitorInfo(ctypes.Structure):
    _fields_ = [("cbSize", wintypes.DWORD), ("rcMonitor", wintypes.RECT),
                ("rcWork", wintypes.RECT), ("dwFlags", wintypes.DWORD)]


def centered_rect(width: int, height: int, monitor: tuple) -> tuple:
    """A width by height rectangle centered on the monitor rectangle, its
    top-left corner kept on the monitor when it is the larger of the two.
    Rectangles are (left, top, right, bottom)."""
    left, top, right, bottom = monitor
    x = left + max(0, (right - left - width) // 2)
    y = top + max(0, (bottom - top - height) // 2)
    return x, y, x + width, y + height


def placement(window: tuple, client_origin: tuple, client_size: tuple, monitor: tuple) -> "tuple[tuple, tuple]":
    """Where a framed window goes to show only its drawing area, centered on
    the monitor: the clip region in window coordinates, and the window's new
    top-left corner."""
    offset_x, offset_y = client_origin[0] - window[0], client_origin[1] - window[1]
    width, height = client_size
    target = centered_rect(width, height, monitor)
    region = (offset_x, offset_y, offset_x + width, offset_y + height)
    return region, (target[0] - offset_x, target[1] - offset_y)


def windowed_size(width: int, height: int) -> "tuple[int, int]":
    """The windowed resolution for a monitor of that size: the monitor's own
    size, scaled down to the engine's widest when the monitor is wider, keeping
    the monitor's shape."""
    if width <= MAX_WINDOW_WIDTH:
        return width, height
    return MAX_WINDOW_WIDTH, round(height * MAX_WINDOW_WIDTH / width)


def game_pixels(width: int, height: int, dpi: int) -> "tuple[int, int]":
    """A size in physical pixels as the game sees it: the game predates display
    scaling, so on a scaled display Windows hands it scaled-down pixels."""
    if dpi <= DEFAULT_DPI:
        return width, height
    return round(width * DEFAULT_DPI / dpi), round(height * DEFAULT_DPI / dpi)


def primary_monitor_size() -> "tuple[int, int] | None":
    """The primary monitor's size in the game's pixels, or None when Windows
    cannot say."""
    user32 = _user32()
    previous_context = _enter_dpi_context(user32, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)
    try:
        width, height = user32.GetSystemMetrics(SM_CXSCREEN), user32.GetSystemMetrics(SM_CYSCREEN)
        try:
            dpi = user32.GetDpiForSystem()
        except AttributeError:
            dpi = DEFAULT_DPI
    finally:
        _leave_dpi_context(user32, previous_context)
    return game_pixels(width, height, dpi) if width > 0 and height > 0 else None


def _enter_dpi_context(user32, context):
    """Switch this thread to a DPI awareness context; returns the one to go
    back to, or None on a Windows without per-thread contexts."""
    try:
        return user32.SetThreadDpiAwarenessContext(context)
    except AttributeError:
        return None


def _leave_dpi_context(user32, previous_context) -> None:
    if previous_context:
        user32.SetThreadDpiAwarenessContext(previous_context)


def _user32():
    """A private user32 handle, so the argument types set here never leak into
    other ctypes users."""
    user32 = ctypes.WinDLL("user32")
    user32.GetWindowRect.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.RECT)]
    user32.GetClientRect.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.RECT)]
    user32.ClientToScreen.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.POINT)]
    user32.GetSystemMetrics.argtypes = [ctypes.c_int]
    user32.MonitorFromWindow.argtypes = [wintypes.HWND, wintypes.DWORD]
    user32.MonitorFromWindow.restype = wintypes.HMONITOR
    user32.GetMonitorInfoW.argtypes = [wintypes.HMONITOR, ctypes.POINTER(_MonitorInfo)]
    user32.SetWindowPos.argtypes = [wintypes.HWND, wintypes.HWND, ctypes.c_int, ctypes.c_int,
                                    ctypes.c_int, ctypes.c_int, wintypes.UINT]
    user32.GetWindowRgn.argtypes = [wintypes.HWND, wintypes.HRGN]
    user32.SetWindowRgn.argtypes = [wintypes.HWND, wintypes.HRGN, wintypes.BOOL]
    user32.GetClassNameW.argtypes = [wintypes.HWND, ctypes.c_wchar_p, ctypes.c_int]
    user32.IsWindow.argtypes = [wintypes.HWND]
    user32.IsIconic.argtypes = [wintypes.HWND]
    try:
        user32.SetThreadDpiAwarenessContext.argtypes = [ctypes.c_void_p]
        user32.SetThreadDpiAwarenessContext.restype = ctypes.c_void_p
        user32.GetWindowDpiAwarenessContext.argtypes = [wintypes.HWND]
        user32.GetWindowDpiAwarenessContext.restype = ctypes.c_void_p
    except AttributeError:
        pass
    return user32


def _gdi32():
    gdi32 = ctypes.WinDLL("gdi32")
    gdi32.CreateRectRgn.argtypes = [ctypes.c_int] * 4
    gdi32.CreateRectRgn.restype = wintypes.HRGN
    gdi32.GetRgnBox.argtypes = [wintypes.HRGN, ctypes.POINTER(wintypes.RECT)]
    gdi32.DeleteObject.argtypes = [wintypes.HGDIOBJ]
    return gdi32


def _dwmapi():
    dwmapi = ctypes.WinDLL("dwmapi")
    dwmapi.DwmSetWindowAttribute.argtypes = [wintypes.HWND, wintypes.DWORD, ctypes.c_void_p, wintypes.DWORD]
    dwmapi.DwmSetWindowAttribute.restype = ctypes.c_long
    return dwmapi


def _set_frame_drawing(hwnd, policy: int) -> None:
    """Who draws the window's frame: the compositor (DWMNCRP_USEWINDOWSTYLE)
    or the classic frame that respects a window region (DWMNCRP_DISABLED). A
    Windows without a compositor keeps the classic frame anyway."""
    value = ctypes.c_int(policy)
    try:
        _dwmapi().DwmSetWindowAttribute(hwnd, DWMWA_NCRENDERING_POLICY, ctypes.byref(value), ctypes.sizeof(value))
    except OSError:
        pass


def _as_tuple(rect: wintypes.RECT) -> tuple:
    return rect.left, rect.top, rect.right, rect.bottom


def _region_box(user32, gdi32, hwnd) -> "tuple | None":
    """The window's clip region when it is one rectangle, else None."""
    region = gdi32.CreateRectRgn(0, 0, 0, 0)
    try:
        if user32.GetWindowRgn(hwnd, region) != SIMPLEREGION:
            return None
        box = wintypes.RECT()
        gdi32.GetRgnBox(region, ctypes.byref(box))
        return _as_tuple(box)
    finally:
        gdi32.DeleteObject(region)


CHANGED = "changed"
UNCHANGED = "unchanged"
GONE = "gone"
REFUSED = "refused"


def make_borderless(hwnd: int, class_suffix: str) -> str:
    """Hide the window's frame and center the area the game draws in on its
    monitor, without changing the window's size or style. Returns CHANGED when
    the window changed, UNCHANGED when it already was borderless or is
    minimized, GONE when no window with that class is behind the handle any
    more, and REFUSED when Windows would not change it (a game running as
    administrator refuses a client that is not)."""
    user32, gdi32 = _user32(), _gdi32()
    # The game's own pixels, so the clip matches the area it draws in on a
    # scaled display.
    try:
        context = user32.GetWindowDpiAwarenessContext(hwnd) or DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2
    except AttributeError:
        context = DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2
    previous_context = _enter_dpi_context(user32, context)
    try:
        name = ctypes.create_unicode_buffer(256)
        if not user32.IsWindow(hwnd) or not user32.GetClassNameW(hwnd, name, 256) \
                or not name.value.endswith(class_suffix):
            return GONE
        if user32.IsIconic(hwnd):
            return UNCHANGED
        info = _MonitorInfo()
        info.cbSize = ctypes.sizeof(_MonitorInfo)
        monitor_handle = user32.MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST)
        window = wintypes.RECT()
        client = wintypes.RECT()
        origin = wintypes.POINT(0, 0)
        # Reads fail only when the window closed after the check above.
        if not monitor_handle or not user32.GetMonitorInfoW(monitor_handle, ctypes.byref(info)) \
                or not user32.GetWindowRect(hwnd, ctypes.byref(window)) \
                or not user32.GetClientRect(hwnd, ctypes.byref(client)) \
                or not user32.ClientToScreen(hwnd, ctypes.byref(origin)):
            return GONE
        region, corner = placement(_as_tuple(window), (origin.x, origin.y),
                                   (client.right - client.left, client.bottom - client.top),
                                   _as_tuple(info.rcMonitor))
        if _region_box(user32, gdi32, hwnd) == region and (window.left, window.top) == corner:
            return UNCHANGED
        clip = gdi32.CreateRectRgn(*region)
        # Out of drawing resources: a missing region would clear the clip, not
        # set it, so this round changes nothing and the next one tries again.
        if not clip:
            return UNCHANGED
        # The compositor draws the frame over any region; its classic frame
        # respects the region.
        _set_frame_drawing(hwnd, DWMNCRP_DISABLED)
        if not user32.SetWindowRgn(hwnd, clip, True):
            gdi32.DeleteObject(clip)
            _set_frame_drawing(hwnd, DWMNCRP_USEWINDOWSTYLE)
            return REFUSED if user32.IsWindow(hwnd) else GONE
        if not user32.SetWindowPos(hwnd, None, corner[0], corner[1], 0, 0,
                                   SWP_NOSIZE | SWP_NOZORDER | SWP_NOOWNERZORDER | SWP_NOACTIVATE):
            # Back to the normal framed window rather than a clipped one off center.
            user32.SetWindowRgn(hwnd, None, True)
            _set_frame_drawing(hwnd, DWMNCRP_USEWINDOWSTYLE)
            return REFUSED if user32.IsWindow(hwnd) else GONE
        return CHANGED
    finally:
        _leave_dpi_context(user32, previous_context)
