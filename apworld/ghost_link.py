"""Ghost players: share where each Harry Potter 2 slot's Harry is and draw the others.

Presence is cheap and positions are targeted. Every client announces its map
in a small beacon under the HP2Ghost tag on a map change and every five seconds.
Positions only flow between slots on the same map: the mod samples Harry ten
times a second, the client drops repeats, and once a second sends the last
second of samples to just those slots. A slot that sees a newcomer arrive on
its map, or a fresh beacon (a new map, a restarted game, a new connection) from
a slot on it, greets it directly, with its last sample when it is standing
still. A greeting from a slot we did not know is answered once.

Inbound samples become PEER frames for the mod, replayed with the spacing the
sender recorded so the ghost moves smoothly. A standing peer sends nothing, so
its last frame is rewritten to the mod locally to keep the ghost alive. A peer
that leaves the map, says goodbye or goes silent is dropped with a PEERGONE
frame. Pure bookkeeping: the caller owns the clock, the socket and the event
loop.
"""

from __future__ import annotations

import re
import time
from dataclasses import dataclass
from typing import Callable, Optional

GHOST_TAG = "HP2Ghost"
# Bounce kinds, carried in the data so slot-targeted Bounces stay recognisable.
KIND_BEACON = "beacon"
KIND_HELLO = "hello"
KIND_MOVE = "move"
# One position Bounce per this interval, carrying the samples since the last.
SEND_INTERVAL_S = 1.0
# Presence beacons repeat this often on top of every map change.
BEACON_INTERVAL_S = 5.0
# A peer with no beacon or sample for this long is gone.
PEER_TIMEOUT_S = 12.0
# The mod drops a ghost after four seconds without a PEER frame.
KEEPALIVE_S = 2.0
# Longest a replayed sample may lag its batch, so a bad offset cannot park a ghost.
MAX_REPLAY_DELAY_S = 1.0
# Most samples one Bounce may carry; anything past this is ignored.
MAX_SAMPLES_PER_BOUNCE = 20
# A sample after the map name: x y z pitch yaw roll, then the body track
# (sequence, frame, loop, combine), the upper-body track (sequence, frame,
# loop), scale, body mesh, wand mesh.
SAMPLE_FIELD_COUNT = 16
_INT_FIELDS = frozenset((0, 1, 2, 3, 4, 5, 7, 8, 9, 11, 12))
_FRAME_FIELDS = (7, 11)
_SCALE_FIELD = 13
# A frame falling back this far is a restarted one-shot, as the mod judges it.
RESTART_FRAME_DROP = 30
_TOKEN = re.compile(r"^[A-Za-z0-9_.\-]{1,48}$")
_LEVEL = re.compile(r"^[A-Za-z0-9_\-]{1,48}$")
_MAX_NAME_CHARS = 16


def parse_sample(raw: list) -> Optional[list]:
    """Validate one sample's fields (from the mod as strings, from a Bounce as
    JSON values). Returns typed fields, or None for anything malformed."""
    if not isinstance(raw, list) or len(raw) != SAMPLE_FIELD_COUNT:
        return None
    fields: list = []
    for index, value in enumerate(raw):
        if index in _INT_FIELDS:
            if isinstance(value, bool) or isinstance(value, float):
                return None
            try:
                fields.append(int(value))
            except (TypeError, ValueError):
                return None
        elif index == _SCALE_FIELD:
            try:
                scale = float(value)
            except (TypeError, ValueError):
                return None
            if not 0.05 <= scale <= 50.0:
                return None
            fields.append(round(scale, 2))
        else:
            if not isinstance(value, str) or not _TOKEN.match(value):
                return None
            fields.append(value)
    return fields


def is_repeat(kept: Optional[list], fields: list, received: Optional[list] = None) -> bool:
    """Whether `fields` shows nothing the last kept sample did: same pose, and
    animation frames that only ran on since the last sample `received`. The
    mod's heartbeat sample is one; a one-shot cast again is not."""
    if kept is None:
        return False
    received = kept if received is None else received
    for index, value in enumerate(fields):
        if index in _FRAME_FIELDS:
            if value + RESTART_FRAME_DROP < received[index]:
                return False
        elif value != kept[index]:
            return False
    return True


def format_field(value) -> str:
    if isinstance(value, float):
        return f"{value:.2f}"
    return str(value)


def clean_name(name) -> str:
    """A slot name safe for the bar-separated PEER frame."""
    if not isinstance(name, str):
        return "?"
    cleaned = "".join(ch for ch in name if ch.isprintable() and ch != "|").strip()
    return (cleaned or "?")[:_MAX_NAME_CHARS]


def is_ghost_bounce(args: dict) -> bool:
    """A Bounced packet meant for ghosts: tag-routed, or slot-routed with the tag in its data."""
    if GHOST_TAG in (args.get("tags") or []):
        return True
    data = args.get("data")
    return isinstance(data, dict) and data.get("tag") == GHOST_TAG


def peer_lines(src: int, name: str, raw_samples: list) -> list[tuple[float, str]]:
    """One (replay delay, PEER frame) pair per well-formed sample in a Bounce."""
    lines: list[tuple[float, str]] = []
    for entry in raw_samples[:MAX_SAMPLES_PER_BOUNCE]:
        if not isinstance(entry, list) or len(entry) != SAMPLE_FIELD_COUNT + 1:
            continue
        try:
            delay = float(entry[0])
        except (TypeError, ValueError):
            continue
        fields = parse_sample(entry[1:])
        if fields is None:
            continue
        delay = min(max(delay, 0.0), MAX_REPLAY_DELAY_S)
        body = "|".join([str(src), name, *(format_field(v) for v in fields)])
        lines.append((delay, "PEER " + body))
    return lines


@dataclass
class Peer:
    name: str
    level: Optional[str]
    last_seen: float
    # True while the mod has this peer's ghost, so PEERGONE is sent once.
    visible: bool = False
    # The newest PEER frame and when the mod next needs it again.
    last_line: Optional[str] = None
    line_due: float = 0.0


class GhostLink:
    def __init__(self, clock: Callable[[], float] = time.monotonic) -> None:
        self._clock = clock
        self.enabled = False
        # Our map, from the LEVEL frame and from every POS sample.
        self.level: Optional[str] = None
        self._pending: list[tuple[float, list]] = []
        self._latest: Optional[list] = None
        self._received: Optional[list] = None
        self._last_send = float("-inf")
        self._last_beacon = float("-inf")
        self._beacon_due = True
        # The next beacon asks every slot on our map to greet us.
        self._beacon_fresh = True
        # Slots that just arrived on our map and have not heard from us yet.
        self._introduce: set[int] = set()
        self.peers: dict[int, Peer] = {}

    # Outbound: our Harry.

    def on_pos(self, payload: str) -> list[str]:
        """Take one POS payload from the mod. Returns the PEERGONE lines a map
        change reveals, since peers left on the old map stop being drawn."""
        parts = payload.split("|")
        if len(parts) != SAMPLE_FIELD_COUNT + 1 or not _LEVEL.match(parts[0]):
            return []
        fields = parse_sample(parts[1:])
        if fields is None:
            return []
        gone = self.set_level(parts[0])
        if not self.enabled:
            return gone
        repeat = is_repeat(self._latest, fields, self._received)
        self._received = fields
        if repeat:
            return gone
        self._latest = fields
        self._pending.append((self._clock(), fields))
        # A stalled pump must not pile up a backlog: only the newest window is worth sending.
        del self._pending[:-MAX_SAMPLES_PER_BOUNCE]
        return gone

    def set_level(self, level: Optional[str]) -> list[str]:
        if level == self.level:
            return []
        self.level = level
        # Samples from the old map would be labelled with the new one.
        self._pending.clear()
        self._latest = None
        self._received = None
        self._introduce.clear()
        self.announce()
        gone = []
        for slot, peer in self.peers.items():
            if peer.visible and peer.level != level:
                peer.visible = False
                gone.append(f"PEERGONE {slot}")
        return gone

    def announce(self) -> None:
        """Send a fresh beacon on the next pump, so the slots on our map greet us."""
        self._beacon_due = True
        self._beacon_fresh = True

    def audience(self) -> list[int]:
        """The slots on our map, the only ones that get our positions."""
        if self.level is None:
            return []
        return sorted(slot for slot, peer in self.peers.items() if peer.level == self.level)

    def _data(self, kind: str, slot: int, name: str) -> dict:
        return {"tag": GHOST_TAG, "k": kind, "src": slot, "name": clean_name(name), "lv": self.level}

    def outbound(self, slot: int, name: str, now: Optional[float] = None) -> list[dict]:
        """The Bounce packets to send now: a beacon to every ghost slot when one
        is due, a greeting to each newcomer on our map, and the samples since the
        last send to the slots on our map. Each sample is sent once, carrying its
        offset from the first so the receiver replays it with the same spacing."""
        if not self.enabled:
            return []
        now = self._clock() if now is None else now
        packets: list[dict] = []
        if self._beacon_due or (self.level is not None and now - self._last_beacon >= BEACON_INTERVAL_S):
            data = self._data(KIND_BEACON, slot, name)
            if self._beacon_fresh:
                data["new"] = True
            packets.append({"cmd": "Bounce", "tags": [GHOST_TAG], "data": data})
            self._beacon_due = False
            self._beacon_fresh = False
            self._last_beacon = now
        audience = self.audience()
        for target in sorted(self._introduce & set(audience)):
            data = self._data(KIND_HELLO, slot, name)
            # A moving Harry's next batch reaches the newcomer anyway.
            if not self._pending and self._latest is not None:
                data["s"] = [[0.0, *self._latest]]
            packets.append({"cmd": "Bounce", "slots": [target], "data": data})
        # A newcomer that left our map before this pump needs no greeting.
        self._introduce.clear()
        if not audience:
            self._pending.clear()
        elif self._pending and now - self._last_send >= SEND_INTERVAL_S:
            first = self._pending[0][0]
            data = self._data(KIND_MOVE, slot, name)
            data["s"] = [[round(stamp - first, 2), *fields] for stamp, fields in self._pending]
            packets.append({"cmd": "Bounce", "slots": audience, "data": data})
            self._pending.clear()
            self._last_send = now
        return packets

    def farewell(self, slot: int, name: str) -> dict:
        """The beacon that tells every ghost slot we left (ghosts turned off)."""
        data = self._data(KIND_BEACON, slot, name)
        data["lv"] = None
        return {"cmd": "Bounce", "tags": [GHOST_TAG], "data": data}

    # Inbound: other players.

    def on_bounced(self, data, my_slot: Optional[int], now: Optional[float] = None) -> list[tuple[float, str]]:
        """Turn one ghost Bounce into (delay, line) pairs for the mod. Our own
        echo, malformed data and peers on another map produce no PEER lines."""
        if not self.enabled or not isinstance(data, dict):
            return []
        src = data.get("src")
        level = data.get("lv")
        raw_samples = data.get("s", [])
        if isinstance(src, bool) or not isinstance(src, int) or src == my_slot:
            return []
        if level is None:
            peer = self.peers.pop(src, None)
            return [(0.0, f"PEERGONE {src}")] if peer is not None and peer.visible else []
        if not isinstance(level, str) or not isinstance(raw_samples, list):
            return []
        now = self._clock() if now is None else now
        name = clean_name(data.get("name"))
        peer = self.peers.get(src)
        arrived = peer is None or peer.level != level
        if peer is None:
            peer = Peer(name, level, now)
            self.peers[src] = peer
        peer.name = name
        peer.level = level
        peer.last_seen = now
        if level != self.level:
            if peer.visible:
                peer.visible = False
                return [(0.0, f"PEERGONE {src}")]
            return []
        # A greeting from a known slot is the answer to ours: never greet it back.
        if arrived or (data.get("k") == KIND_BEACON and data.get("new") is True):
            self._introduce.add(src)
        lines = peer_lines(src, name, raw_samples)
        if lines:
            peer.visible = True
            peer.last_line = lines[-1][1]
            peer.line_due = now + max(delay for delay, _ in lines) + KEEPALIVE_S
        return lines

    def should_replay(self, src: int, level: Optional[str]) -> bool:
        """Whether a sample scheduled earlier for `src` on `level` is still
        worth drawing: ghosts on, still that map, and the peer still drawn."""
        peer = self.peers.get(src)
        return self.enabled and self.level == level and peer is not None and peer.visible

    def keepalive_lines(self, now: Optional[float] = None) -> list[str]:
        """Each drawn peer's newest PEER frame again once the mod is due one,
        so a peer standing still keeps its ghost without any network traffic."""
        now = self._clock() if now is None else now
        lines = []
        for peer in self.peers.values():
            if peer.visible and peer.last_line is not None and now >= peer.line_due:
                peer.line_due = now + KEEPALIVE_S
                lines.append(peer.last_line)
        return lines

    def sweep(self, now: Optional[float] = None) -> list[str]:
        """Forget peers that went silent. Returns their PEERGONE lines."""
        now = self._clock() if now is None else now
        gone = []
        for slot in [s for s, p in self.peers.items() if now - p.last_seen > PEER_TIMEOUT_S]:
            if self.peers[slot].visible:
                gone.append(f"PEERGONE {slot}")
            del self.peers[slot]
        return gone

    def forget_all(self) -> list[str]:
        """Drop every peer and pending sample, and announce afresh on the next pump."""
        gone = [f"PEERGONE {slot}" for slot, peer in self.peers.items() if peer.visible]
        self.peers.clear()
        self._pending.clear()
        self._latest = None
        self._received = None
        self._introduce.clear()
        self.announce()
        return gone

    def game_restarted(self) -> None:
        """The game reconnected with no ghosts drawn. Our map is unknown until
        its next frame, and announcing it then makes the peers greet us again."""
        self.set_level(None)
        for peer in self.peers.values():
            peer.visible = False
            peer.last_line = None
