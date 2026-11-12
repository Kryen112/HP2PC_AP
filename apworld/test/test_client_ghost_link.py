"""GhostLink is the client's ghost-players bookkeeping: presence beacons on
the HP2Ghost tag, greetings and once-a-second sample batches sent only to the
slots on our map, and other slots' Bounces turned into PEER frames. These tests
pin the wire shapes, the network budget (no positions without an audience, no
repeated sample), the same-map filter, the self-echo drop, the replay spacing,
the local keepalive and the PEERGONE bookkeeping, with a fake clock."""

import unittest

from ..Client import HP2Context
from ..ghost_link import (BEACON_INTERVAL_S, GHOST_TAG, KEEPALIVE_S, KIND_BEACON, KIND_HELLO,
                          KIND_MOVE, MAX_REPLAY_DELAY_S, MAX_SAMPLES_PER_BOUNCE, PEER_TIMEOUT_S,
                          SEND_INTERVAL_S, GhostLink, clean_name, is_ghost_bounce, is_repeat,
                          parse_sample)

SAMPLE = "-622|-5154|428|0|16384|0|run|42|1|1|Cast|10|0|1|HPModels.skharryMesh|HPModels.WandMesh"
POS = "ENTRYHALL_HUB|" + SAMPLE


def fields(**overrides):
    base = [-622, -5154, 428, 0, 16384, 0, "run", 42, 1, 1, "Cast", 10, 0, 1.0,
            "HPModels.skharryMesh", "HPModels.WandMesh"]
    for index, value in overrides.items():
        base[int(index[1:])] = value
    return base


def pos(**overrides) -> str:
    return "ENTRYHALL_HUB|" + "|".join(str(int(v)) if isinstance(v, float) else str(v)
                                       for v in fields(**overrides))


def bounce(src=2, level="ENTRYHALL_HUB", name="Ron", samples=None, kind=KIND_MOVE):
    if samples is None:
        samples = [[0.0, *fields()]]
    return {"tag": GHOST_TAG, "k": kind, "src": src, "name": name, "lv": level, "s": samples}


def beacon(src=2, level="ENTRYHALL_HUB", name="Ron"):
    return {"tag": GHOST_TAG, "k": KIND_BEACON, "src": src, "name": name, "lv": level}


def kinds(packets):
    return [packet["data"]["k"] for packet in packets]


class _Clock:
    def __init__(self) -> None:
        self.now = 100.0

    def __call__(self) -> float:
        return self.now


class TestParsing(unittest.TestCase):
    def test_sample_round_trips_typed(self) -> None:
        parsed = parse_sample(SAMPLE.split("|"))
        self.assertEqual(parsed, fields())

    def test_bad_field_counts_and_types_are_rejected(self) -> None:
        self.assertIsNone(parse_sample(SAMPLE.split("|")[:-1]))
        self.assertIsNone(parse_sample(SAMPLE.replace("-622", "x").split("|")))
        self.assertIsNone(parse_sample(SAMPLE.replace("run", "ru n").split("|")))
        self.assertIsNone(parse_sample(SAMPLE.replace("|1", "|0", 1)[:-1] + "999"))
        self.assertIsNone(parse_sample([True, *fields()[1:]]))

    def test_name_is_made_safe_for_the_bar_separated_frame(self) -> None:
        self.assertEqual(clean_name("Ron|Weasley"), "RonWeasley")
        self.assertEqual(clean_name("  "), "?")
        self.assertEqual(clean_name(None), "?")
        self.assertEqual(len(clean_name("x" * 40)), 16)

    def test_heartbeat_sample_is_a_repeat(self) -> None:
        self.assertFalse(is_repeat(None, fields()))
        self.assertTrue(is_repeat(fields(), fields()))
        # An animation frame running on shows nothing new.
        self.assertTrue(is_repeat(fields(), fields(f7=60, f11=20)))
        # A one-shot restarting, a move or a new sequence is new.
        self.assertFalse(is_repeat(fields(f7=60), fields(f7=5)))
        self.assertFalse(is_repeat(fields(), fields(f0=-600)))
        self.assertFalse(is_repeat(fields(), fields(f6="walk")))

    def test_ghost_bounces_are_recognised_by_tag_or_data(self) -> None:
        self.assertTrue(is_ghost_bounce({"tags": [GHOST_TAG], "data": {}}))
        self.assertTrue(is_ghost_bounce({"slots": [1], "data": bounce()}))
        self.assertFalse(is_ghost_bounce({"tags": ["TrapLink"], "data": {"tag": "TrapLink"}}))
        self.assertFalse(is_ghost_bounce({"slots": [1], "data": "nope"}))


class TestOutbound(unittest.TestCase):
    def setUp(self) -> None:
        self.clock = _Clock()
        self.link = GhostLink(clock=self.clock)
        self.link.enabled = True

    def join(self, src=2) -> None:
        """A peer on our map, already greeted, so only samples flow."""
        self.link.on_bounced(bounce(src=src, samples=[]), my_slot=1)
        self.assertEqual(kinds(self.link.outbound(1, "Harry")), [KIND_HELLO])

    def flush_beacon(self) -> None:
        self.link.on_pos(POS)
        self.link.outbound(1, "Harry")
        self.clock.now += SEND_INTERVAL_S

    def test_disabled_link_sends_nothing(self) -> None:
        self.link.enabled = False
        self.link.on_pos(POS)
        self.assertEqual(self.link.outbound(1, "Harry"), [])

    def test_beacon_goes_to_the_tag_without_samples(self) -> None:
        self.link.on_pos(POS)
        packets = self.link.outbound(1, "Harry")
        self.assertEqual(len(packets), 1)
        self.assertEqual(packets[0]["tags"], [GHOST_TAG])
        self.assertEqual(packets[0]["data"], {"tag": GHOST_TAG, "k": KIND_BEACON, "src": 1,
                                              "name": "Harry", "lv": "ENTRYHALL_HUB", "new": True})

    def test_alone_on_a_map_only_beacons_go_out(self) -> None:
        self.flush_beacon()
        for index in range(200):
            self.link.on_pos(pos(f0=-index))
            self.clock.now += 0.1
            for packet in self.link.outbound(1, "Harry"):
                self.assertEqual(packet["data"]["k"], KIND_BEACON)
                self.assertNotIn("s", packet["data"])

    def test_beacon_repeats_on_its_interval_and_on_a_map_change(self) -> None:
        self.flush_beacon()
        self.assertEqual(self.link.outbound(1, "Harry"), [])
        self.clock.now += BEACON_INTERVAL_S
        self.assertEqual(kinds(self.link.outbound(1, "Harry")), [KIND_BEACON])
        self.link.on_pos("GRANDSTAIRCASE_HUB|" + SAMPLE)
        packets = self.link.outbound(1, "Harry")
        self.assertEqual(kinds(packets), [KIND_BEACON])
        self.assertEqual(packets[0]["data"]["lv"], "GRANDSTAIRCASE_HUB")

    def test_samples_go_once_a_second_to_the_slots_on_our_map(self) -> None:
        self.flush_beacon()
        self.join(src=2)
        self.join(src=3)
        self.link.on_bounced(beacon(src=4, level="GROUNDS_HUB"), my_slot=1)
        self.link.on_pos(pos(f0=-600))
        self.clock.now += 0.1
        self.link.on_pos(pos(f0=-590))
        packets = self.link.outbound(1, "Harry")
        self.assertEqual(len(packets), 1)
        self.assertEqual(packets[0]["slots"], [2, 3])
        self.assertNotIn("tags", packets[0])
        data = packets[0]["data"]
        self.assertEqual((data["tag"], data["k"], data["lv"]), (GHOST_TAG, KIND_MOVE, "ENTRYHALL_HUB"))
        self.assertEqual([sample[0] for sample in data["s"]], [0.0, 0.1])
        self.assertEqual(data["s"][1][1], -590)
        self.link.on_pos(pos(f0=-580))
        self.clock.now += SEND_INTERVAL_S / 2
        self.assertEqual(self.link.outbound(1, "Harry"), [])
        self.clock.now += SEND_INTERVAL_S / 2
        self.assertEqual(kinds(self.link.outbound(1, "Harry")), [KIND_MOVE])

    def test_a_still_harry_never_resends_his_position(self) -> None:
        self.flush_beacon()
        self.join()
        for _ in range(100):
            self.link.on_pos(POS)
            self.clock.now += 0.2
            self.assertNotIn(KIND_MOVE, kinds(self.link.outbound(1, "Harry")))

    def test_a_restarted_one_shot_is_sent_again(self) -> None:
        self.flush_beacon()
        self.join()
        self.link.on_pos(pos(f7=5))
        self.assertEqual(kinds(self.link.outbound(1, "Harry")), [KIND_MOVE])

    def test_newcomer_is_greeted_with_the_last_sample_when_standing_still(self) -> None:
        self.flush_beacon()
        self.link.on_bounced(beacon(src=2), my_slot=1)
        packets = self.link.outbound(1, "Harry")
        self.assertEqual(kinds(packets), [KIND_HELLO])
        self.assertEqual(packets[0]["slots"], [2])
        self.assertEqual(packets[0]["data"]["s"], [[0.0, *fields()]])
        self.assertEqual(self.link.outbound(1, "Harry"), [])

    def test_newcomer_of_a_moving_harry_gets_the_next_batch_instead(self) -> None:
        self.flush_beacon()
        self.link.on_bounced(beacon(src=2), my_slot=1)
        self.link.on_pos(pos(f0=-600))
        packets = self.link.outbound(1, "Harry")
        self.assertEqual(kinds(packets), [KIND_HELLO, KIND_MOVE])
        self.assertNotIn("s", packets[0]["data"])
        self.assertEqual(packets[1]["slots"], [2])

    def test_a_greeting_from_a_stranger_is_answered_once(self) -> None:
        self.flush_beacon()
        self.link.on_bounced(bounce(kind=KIND_HELLO), my_slot=1)
        self.assertEqual(kinds(self.link.outbound(1, "Harry")), [KIND_HELLO])
        self.link.on_bounced(bounce(kind=KIND_HELLO), my_slot=1)
        self.link.on_bounced(beacon(src=2), my_slot=1)
        self.assertEqual(self.link.outbound(1, "Harry"), [])

    def test_a_fresh_beacon_from_a_known_peer_is_greeted(self) -> None:
        self.flush_beacon()
        self.link.on_bounced(beacon(src=2), my_slot=1)
        self.link.outbound(1, "Harry")
        self.link.on_bounced({**beacon(src=2), "new": True}, my_slot=1)
        self.assertEqual(kinds(self.link.outbound(1, "Harry")), [KIND_HELLO])

    def test_the_same_one_shot_cast_twice_is_sent_twice(self) -> None:
        self.flush_beacon()
        self.join()
        self.link.on_pos(pos(f6="cast", f7=5))
        for frame in range(10, 70, 10):
            self.link.on_pos(pos(f6="cast", f7=frame))
        self.link.on_pos(pos(f6="cast", f7=5))
        samples = self.link.outbound(1, "Harry")[0]["data"]["s"]
        self.assertEqual([sample[8] for sample in samples], [5, 5])

    def test_mesh_tokens_travel_as_is(self) -> None:
        self.flush_beacon()
        self.join()
        self.link.on_pos(POS.replace("HPModels.skharryMesh", "HPModels.skGoyleMesh")
                         .replace("HPModels.WandMesh", "None"))
        data = self.link.outbound(1, "Harry")[0]["data"]
        self.assertEqual(data["s"][0][-2:], ["HPModels.skGoyleMesh", "None"])

    def test_malformed_pos_is_ignored(self) -> None:
        self.assertEqual(self.link.on_pos("ENTRYHALL_HUB|1|2"), [])
        self.assertEqual(self.link.on_pos("bad map!|" + SAMPLE), [])
        self.assertIsNone(self.link.level)

    def test_stalled_pump_keeps_only_the_newest_window(self) -> None:
        self.flush_beacon()
        self.join()
        for index in range(100):
            self.link.on_pos(pos(f0=-index))
            self.clock.now += 0.1
        packets = self.link.outbound(1, "Harry")
        data = packets[kinds(packets).index(KIND_MOVE)]["data"]
        self.assertEqual(len(data["s"]), MAX_SAMPLES_PER_BOUNCE)
        self.assertEqual(data["s"][0][0], 0.0)
        self.assertEqual(data["s"][-1][1], -99)

    def test_farewell_and_a_lost_game_tell_everyone_we_left(self) -> None:
        self.flush_beacon()
        self.assertIsNone(self.link.farewell(1, "Harry")["data"]["lv"])
        self.link.set_level(None)
        packets = self.link.outbound(1, "Harry")
        self.assertEqual(kinds(packets), [KIND_BEACON])
        self.assertIsNone(packets[0]["data"]["lv"])
        self.clock.now += BEACON_INTERVAL_S * 2
        self.assertEqual(self.link.outbound(1, "Harry"), [])

    def test_announce_rebeacons_after_a_reconnect(self) -> None:
        self.flush_beacon()
        self.link.announce()
        self.assertEqual(kinds(self.link.outbound(1, "Harry")), [KIND_BEACON])


class TestInbound(unittest.TestCase):
    def setUp(self) -> None:
        self.clock = _Clock()
        self.link = GhostLink(clock=self.clock)
        self.link.enabled = True
        self.link.set_level("ENTRYHALL_HUB")

    def test_same_map_peer_becomes_peer_lines(self) -> None:
        lines = self.link.on_bounced(bounce(), my_slot=1)
        self.assertEqual(lines, [(0.0, "PEER 2|Ron|-622|-5154|428|0|16384|0|run|42|1|1|Cast|10|0|1.00"
                                       "|HPModels.skharryMesh|HPModels.WandMesh")])
        self.assertTrue(self.link.peers[2].visible)

    def test_beacon_tracks_a_peer_without_drawing_it(self) -> None:
        self.assertEqual(self.link.on_bounced(beacon(), my_slot=1), [])
        self.assertEqual(self.link.audience(), [2])
        self.assertFalse(self.link.peers[2].visible)

    def test_own_echo_and_garbage_are_dropped(self) -> None:
        self.assertEqual(self.link.on_bounced(bounce(src=1), my_slot=1), [])
        self.assertEqual(self.link.on_bounced("nope", my_slot=1), [])
        self.assertEqual(self.link.on_bounced(bounce(src=True), my_slot=1), [])
        self.assertEqual(self.link.on_bounced({"src": 2, "lv": 5, "s": []}, my_slot=1), [])
        self.assertEqual(self.link.on_bounced({"src": 2, "lv": "ENTRYHALL_HUB", "s": 5}, my_slot=1), [])
        self.assertEqual(self.link.on_bounced(bounce(samples=[["x", *fields()]]), my_slot=1), [])
        self.assertEqual(self.link.peers[2].visible, False)

    def test_other_map_peer_is_tracked_but_not_drawn(self) -> None:
        self.assertEqual(self.link.on_bounced(bounce(level="GROUNDS_HUB"), my_slot=1), [])
        self.assertIn(2, self.link.peers)
        self.assertFalse(self.link.peers[2].visible)
        self.assertEqual(self.link.audience(), [])

    def test_peer_leaving_our_map_sends_peergone_once(self) -> None:
        self.link.on_bounced(bounce(), my_slot=1)
        self.assertEqual(self.link.on_bounced(beacon(level="GROUNDS_HUB"), my_slot=1),
                         [(0.0, "PEERGONE 2")])
        self.assertEqual(self.link.on_bounced(beacon(level="GROUNDS_HUB"), my_slot=1), [])

    def test_farewell_beacon_drops_the_peer(self) -> None:
        self.link.on_bounced(bounce(), my_slot=1)
        self.assertEqual(self.link.on_bounced(beacon(level=None), my_slot=1), [(0.0, "PEERGONE 2")])
        self.assertNotIn(2, self.link.peers)
        self.assertEqual(self.link.on_bounced(beacon(level=None), my_slot=1), [])

    def test_our_own_map_change_hides_peers_left_behind(self) -> None:
        self.link.on_bounced(bounce(), my_slot=1)
        self.assertEqual(self.link.set_level("GROUNDS_HUB"), ["PEERGONE 2"])
        self.assertEqual(self.link.set_level("GROUNDS_HUB"), [])
        # Arriving on the peer's map draws them again on their next Bounce.
        self.assertEqual(self.link.set_level("ENTRYHALL_HUB"), [])
        self.assertEqual(len(self.link.on_bounced(bounce(), my_slot=1)), 1)

    def test_replay_offsets_are_kept_and_clamped(self) -> None:
        samples = [[0.0, *fields()], [0.3, *fields(f0=-600)], [99.0, *fields(f0=-500)], [-1.0, *fields()]]
        lines = self.link.on_bounced(bounce(samples=samples), my_slot=1)
        self.assertEqual([delay for delay, _ in lines], [0.0, 0.3, MAX_REPLAY_DELAY_S, 0.0])
        self.assertIn("|-600|", lines[1][1])

    def test_name_with_bar_cannot_break_the_frame(self) -> None:
        lines = self.link.on_bounced(bounce(name="Ro|n"), my_slot=1)
        self.assertEqual(lines[0][1].split("|")[1], "Ron")
        self.assertEqual(len(lines[0][1].split("|")), 18)

    def test_still_peer_is_kept_alive_locally(self) -> None:
        lines = self.link.on_bounced(bounce(samples=[[0.0, *fields()], [0.5, *fields(f0=-600)]]), my_slot=1)
        self.clock.now += 0.5 + KEEPALIVE_S / 2
        self.assertEqual(self.link.keepalive_lines(), [])
        self.clock.now += KEEPALIVE_S / 2
        self.assertEqual(self.link.keepalive_lines(), [lines[-1][1]])
        self.assertEqual(self.link.keepalive_lines(), [])
        self.clock.now += KEEPALIVE_S
        self.assertEqual(self.link.keepalive_lines(), [lines[-1][1]])
        self.link.set_level("GROUNDS_HUB")
        self.clock.now += KEEPALIVE_S
        self.assertEqual(self.link.keepalive_lines(), [])

    def test_silent_peer_expires_with_peergone(self) -> None:
        self.link.on_bounced(bounce(), my_slot=1)
        self.clock.now += PEER_TIMEOUT_S / 2
        self.assertEqual(self.link.sweep(), [])
        # A beacon alone keeps a standing peer.
        self.link.on_bounced(beacon(), my_slot=1)
        self.clock.now += PEER_TIMEOUT_S / 2 + 1
        self.assertEqual(self.link.sweep(), [])
        self.clock.now += PEER_TIMEOUT_S
        self.assertEqual(self.link.sweep(), ["PEERGONE 2"])
        self.assertNotIn(2, self.link.peers)

    def test_timeout_outlasts_the_beacon_interval(self) -> None:
        self.assertGreater(PEER_TIMEOUT_S, BEACON_INTERVAL_S * 2)
        self.assertLessEqual(BEACON_INTERVAL_S, 60)

    def test_expiry_of_a_never_drawn_peer_is_silent(self) -> None:
        self.link.on_bounced(bounce(level="GROUNDS_HUB"), my_slot=1)
        self.clock.now += PEER_TIMEOUT_S * 2
        self.assertEqual(self.link.sweep(), [])

    def test_forget_all(self) -> None:
        self.link.on_bounced(bounce(), my_slot=1)
        self.link.on_bounced(beacon(src=3, name="Hermione"), my_slot=1)
        self.assertEqual(self.link.forget_all(), ["PEERGONE 2"])
        self.assertEqual(self.link.peers, {})

    def test_game_restart_forgets_drawn_ghosts_and_reannounces(self) -> None:
        self.link.on_bounced(bounce(), my_slot=1)
        self.link.outbound(1, "Harry")
        self.link.game_restarted()
        self.assertFalse(self.link.peers[2].visible)
        self.assertEqual(self.link.keepalive_lines(self.clock.now + KEEPALIVE_S * 2), [])
        self.assertEqual(self.link.forget_all(), [])
        self.link.on_pos(POS)
        self.assertEqual(kinds(self.link.outbound(1, "Harry")), [KIND_BEACON])

    def test_disabled_link_draws_nothing(self) -> None:
        self.link.enabled = False
        self.assertEqual(self.link.on_bounced(bounce(), my_slot=1), [])

    def test_delayed_replay_is_dropped_once_the_peer_or_map_moved_on(self) -> None:
        self.link.on_bounced(bounce(), my_slot=1)
        self.assertTrue(self.link.should_replay(2, "ENTRYHALL_HUB"))
        self.assertFalse(self.link.should_replay(3, "ENTRYHALL_HUB"))
        self.link.set_level("GROUNDS_HUB")
        self.assertFalse(self.link.should_replay(2, "ENTRYHALL_HUB"))
        self.link.set_level("ENTRYHALL_HUB")
        self.link.on_bounced(bounce(), my_slot=1)
        self.clock.now += PEER_TIMEOUT_S * 2
        self.link.sweep()
        self.assertFalse(self.link.should_replay(2, "ENTRYHALL_HUB"))


# The mod drops a ghost after this long without a PEER frame.
MOD_PEER_TIMEOUT_S = 4.0


class _Room:
    """GhostLinks routed like the 0.6.7 server routes a Bounce: to every tagged
    client OR every listed slot. `drawn[slot]` is what that slot's game shows."""

    def __init__(self, clock: _Clock, slots) -> None:
        self.clock = clock
        self.links = {}
        self.online = set()
        # slot -> peer -> (time written, PEER frame)
        self.frames = {}
        for slot in slots:
            self.connect(slot)

    @property
    def drawn(self) -> dict:
        return {slot: {peer: line for peer, (stamp, line) in peers.items()
                       if self.clock.now - stamp < MOD_PEER_TIMEOUT_S}
                for slot, peers in self.frames.items()}

    def connect(self, slot: int) -> None:
        link = self.links.get(slot) or GhostLink(clock=self.clock)
        link.enabled = True
        link.announce()
        self.links[slot] = link
        self.online.add(slot)
        self.frames.setdefault(slot, {})

    def disconnect(self, slot: int) -> None:
        self.online.discard(slot)
        for line in self.links[slot].forget_all():
            self.write(slot, line)

    def ghosts_off(self, slot: int) -> None:
        link = self.links[slot]
        self.route(slot, link.farewell(slot, f"P{slot}"))
        link.enabled = False
        for line in link.forget_all():
            self.write(slot, line)

    def restart_game(self, slot: int, level: str) -> None:
        self.links[slot].game_restarted()
        self.frames[slot].clear()
        self.links[slot].on_pos(level + "|" + SAMPLE)

    def write(self, slot: int, line: str) -> None:
        word, body = line.split(" ", 1)
        if word == "PEERGONE":
            self.frames[slot].pop(int(body), None)
        else:
            self.frames[slot][int(body.split("|")[0])] = (self.clock.now, line)

    def route(self, sender: int, packet: dict) -> None:
        targets = [slot for slot in sorted(self.online)
                   if slot in packet.get("slots", []) or GHOST_TAG in packet.get("tags", [])]
        if packet["data"]["k"] == KIND_MOVE:
            for slot in targets:
                assert self.links[slot].level == packet["data"]["lv"], "positions left the map"
        for slot in targets:
            for _, line in self.links[slot].on_bounced(packet["data"], my_slot=slot):
                self.write(slot, line)

    def run(self, seconds: float, levels: dict) -> None:
        """Every slot in `levels` stands still on its map, the mod sampling at 10 Hz."""
        for tick in range(int(seconds * 10)):
            self.clock.now += 0.1
            for slot, level in levels.items():
                for line in self.links[slot].on_pos(level + "|" + SAMPLE):
                    self.write(slot, line)
            if tick % 2:
                continue
            for slot in sorted(self.online):
                link = self.links[slot]
                for line in link.sweep() + link.keepalive_lines():
                    self.write(slot, line)
                for packet in link.outbound(slot, f"P{slot}"):
                    self.route(slot, packet)


class TestTwoPlayers(unittest.TestCase):
    HALL = "ENTRYHALL_HUB"
    GROUNDS = "GROUNDS_HUB"

    def setUp(self) -> None:
        self.clock = _Clock()

    def assertSeeEachOther(self, room: _Room, first: int = 1, second: int = 2) -> None:
        self.assertIn(second, room.drawn[first])
        self.assertIn(first, room.drawn[second])

    def test_both_standing_still_see_each_other(self) -> None:
        room = _Room(self.clock, [1, 2])
        room.run(3, {1: self.HALL, 2: self.HALL})
        self.assertSeeEachOther(room)

    def test_late_joiner_standing_still_either_way_round(self) -> None:
        for first, second in ((1, 2), (2, 1)):
            room = _Room(self.clock, [first])
            room.run(20, {first: self.HALL})
            room.connect(second)
            room.run(3, {1: self.HALL, 2: self.HALL})
            self.assertSeeEachOther(room)

    def test_still_players_stay_drawn_without_sending_positions(self) -> None:
        room = _Room(self.clock, [1, 2])
        room.run(3, {1: self.HALL, 2: self.HALL})
        moves = []
        original = room.route
        room.route = lambda sender, packet: (moves.append(packet) if packet["data"]["k"] == KIND_MOVE
                                             else None, original(sender, packet))
        room.run(60, {1: self.HALL, 2: self.HALL})
        self.assertEqual(moves, [])
        self.assertSeeEachOther(room)

    def test_map_changes_in_either_order(self) -> None:
        room = _Room(self.clock, [1, 2])
        room.run(3, {1: self.HALL, 2: self.GROUNDS})
        self.assertEqual(room.drawn, {1: {}, 2: {}})
        room.run(3, {1: self.GROUNDS, 2: self.GROUNDS})
        self.assertSeeEachOther(room)
        room.run(3, {1: self.GROUNDS, 2: self.HALL})
        self.assertEqual(room.drawn, {1: {}, 2: {}})
        room.run(3, {1: self.HALL, 2: self.HALL})
        self.assertSeeEachOther(room)

    def test_game_restart_on_the_same_map(self) -> None:
        room = _Room(self.clock, [1, 2])
        room.run(3, {1: self.HALL, 2: self.HALL})
        room.restart_game(1, self.HALL)
        room.run(3, {1: self.HALL, 2: self.HALL})
        self.assertSeeEachOther(room)

    def test_server_reconnect_short_and_long(self) -> None:
        for outage in (PEER_TIMEOUT_S / 2, PEER_TIMEOUT_S * 2):
            room = _Room(self.clock, [1, 2])
            room.run(3, {1: self.HALL, 2: self.HALL})
            room.disconnect(1)
            room.run(outage, {1: self.HALL, 2: self.HALL})
            room.connect(1)
            room.run(3, {1: self.HALL, 2: self.HALL})
            self.assertSeeEachOther(room)

    def test_ghosts_off_then_on(self) -> None:
        room = _Room(self.clock, [1, 2])
        room.run(3, {1: self.HALL, 2: self.HALL})
        room.ghosts_off(1)
        self.assertEqual(room.drawn[2], {})
        room.run(3, {1: self.HALL, 2: self.HALL})
        self.assertEqual(room.drawn, {1: {}, 2: {}})
        room.connect(1)
        room.run(3, {1: self.HALL, 2: self.HALL})
        self.assertSeeEachOther(room)


class _Writer:
    def __init__(self) -> None:
        self.lines: list = []

    def is_closing(self) -> bool:
        return False

    def write(self, data: bytes) -> None:
        self.lines.append(data.decode("utf-8"))


class _Ctx(HP2Context):
    """Context with only the ghost state, so no event loop or server is needed."""

    def __init__(self) -> None:
        self.game_writer = None
        self.pending_grants: list = []
        self.slot = 1
        self.ghost_players_enabled = True
        self.ghosts = GhostLink()
        self.ghosts.enabled = True
        self.ghosts.set_level("ENTRYHALL_HUB")


class TestClientPlumbing(unittest.TestCase):
    def setUp(self) -> None:
        self.ctx = _Ctx()

    def test_ghost_lines_are_never_queued_for_an_offline_game(self) -> None:
        self.ctx._write_ghost_line("PEERGONE 2")
        self.assertEqual(self.ctx.pending_grants, [])

    def test_slot_routed_peer_line_reaches_the_game(self) -> None:
        writer = _Writer()
        self.ctx.game_writer = writer
        self.ctx._handle_ghost_bounce({"slots": [1], "data": bounce()})
        self.assertEqual(len(writer.lines), 1)
        self.assertTrue(writer.lines[0].startswith("PEER 2|Ron|"))
        self.assertTrue(writer.lines[0].endswith("\n"))

    def test_other_tags_and_disabled_ghosts_write_nothing(self) -> None:
        writer = _Writer()
        self.ctx.game_writer = writer
        self.ctx._handle_ghost_bounce({"tags": ["TrapLink"], "data": {**bounce(), "tag": "TrapLink"}})
        self.ctx.ghost_players_enabled = False
        self.ctx._handle_ghost_bounce({"tags": [GHOST_TAG], "data": bounce()})
        self.assertEqual(writer.lines, [])

    def test_late_replay_checks_the_map_first(self) -> None:
        writer = _Writer()
        self.ctx.game_writer = writer
        self.ctx.ghosts.on_bounced(bounce(), my_slot=1)
        self.ctx._replay_ghost_line("PEER 2|Ron|x", 2, "GROUNDS_HUB")
        self.assertEqual(writer.lines, [])
        self.ctx._replay_ghost_line("PEER 2|Ron|x", 2, "ENTRYHALL_HUB")
        self.assertEqual(writer.lines, ["PEER 2|Ron|x\n"])
