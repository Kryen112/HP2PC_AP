"""GhostLink is the client's ghost-players bookkeeping: it batches the mod's
POS samples into HP2Ghost Bounces and turns other slots' Bounces into PEER
frames. These tests pin the wire shapes, the same-map filter, the self-echo
drop, the replay spacing, and the PEERGONE bookkeeping, with a fake clock."""

import unittest

from ..Client import HP2Context
from ..ghost_link import (GHOST_TAG, GhostLink, MAX_REPLAY_DELAY_S,
                          MAX_SAMPLES_PER_BOUNCE, PEER_TIMEOUT_S, SEND_INTERVAL_S,
                          clean_name, parse_sample)

SAMPLE = "-622|-5154|428|0|16384|0|run|42|1|Cast|10|0|1"
POS = "ENTRYHALL_HUB|" + SAMPLE


def fields(**overrides):
    base = [-622, -5154, 428, 0, 16384, 0, "run", 42, 1, "Cast", 10, 0, 1.0]
    for index, value in overrides.items():
        base[int(index[1:])] = value
    return base


def bounce(src=2, level="ENTRYHALL_HUB", name="Ron", samples=None):
    if samples is None:
        samples = [[0.0, *fields()]]
    return {"src": src, "name": name, "lv": level, "s": samples}


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


class TestOutbound(unittest.TestCase):
    def setUp(self) -> None:
        self.clock = _Clock()
        self.link = GhostLink(clock=self.clock)
        self.link.enabled = True

    def test_nothing_is_sent_without_samples_or_when_disabled(self) -> None:
        self.assertIsNone(self.link.bounce_due(1, "Harry"))
        self.link.on_pos(POS)
        self.link.enabled = False
        self.assertIsNone(self.link.bounce_due(1, "Harry"))

    def test_samples_batch_into_one_bounce_with_offsets(self) -> None:
        self.link.on_pos(POS)
        self.clock.now += 0.1
        self.link.on_pos(POS.replace("-622", "-600"))
        data = self.link.bounce_due(1, "Harry")
        self.assertEqual(data["src"], 1)
        self.assertEqual(data["name"], "Harry")
        self.assertEqual(data["lv"], "ENTRYHALL_HUB")
        self.assertEqual(len(data["s"]), 2)
        self.assertEqual(data["s"][0][0], 0.0)
        self.assertAlmostEqual(data["s"][1][0], 0.1)
        self.assertEqual(data["s"][1][1], -600)
        self.assertIsNone(self.link.bounce_due(1, "Harry"))

    def test_send_interval_is_honoured(self) -> None:
        self.link.on_pos(POS)
        self.assertIsNotNone(self.link.bounce_due(1, "Harry"))
        self.link.on_pos(POS)
        self.clock.now += SEND_INTERVAL_S / 2
        self.assertIsNone(self.link.bounce_due(1, "Harry"))
        self.clock.now += SEND_INTERVAL_S
        self.assertIsNotNone(self.link.bounce_due(1, "Harry"))

    def test_malformed_pos_is_ignored(self) -> None:
        self.assertEqual(self.link.on_pos("ENTRYHALL_HUB|1|2"), [])
        self.assertEqual(self.link.on_pos("bad map!|" + SAMPLE), [])
        self.assertIsNone(self.link.bounce_due(1, "Harry"))

    def test_disabled_link_keeps_no_samples(self) -> None:
        # The mod sends POS whenever the bridge is up, whatever the slot chose.
        self.link.enabled = False
        for _ in range(50):
            self.link.on_pos(POS)
        self.link.enabled = True
        self.assertIsNone(self.link.bounce_due(1, "Harry"))

    def test_stalled_pump_keeps_only_the_newest_window(self) -> None:
        for index in range(100):
            self.link.on_pos(POS.replace("-622", str(-index)))
            self.clock.now += 0.1
        data = self.link.bounce_due(1, "Harry")
        self.assertEqual(len(data["s"]), MAX_SAMPLES_PER_BOUNCE)
        self.assertEqual(data["s"][0][0], 0.0)
        self.assertEqual(data["s"][-1][1], -99)

    def test_map_change_drops_stale_samples(self) -> None:
        self.link.on_pos(POS)
        self.link.on_pos("GRANDSTAIRCASE_HUB|" + SAMPLE)
        data = self.link.bounce_due(1, "Harry")
        self.assertEqual(data["lv"], "GRANDSTAIRCASE_HUB")
        self.assertEqual(len(data["s"]), 1)


class TestInbound(unittest.TestCase):
    def setUp(self) -> None:
        self.clock = _Clock()
        self.link = GhostLink(clock=self.clock)
        self.link.enabled = True
        self.link.set_level("ENTRYHALL_HUB")

    def test_same_map_peer_becomes_peer_lines(self) -> None:
        lines = self.link.on_bounced(bounce(), my_slot=1)
        self.assertEqual(lines, [(0.0, "PEER 2|Ron|-622|-5154|428|0|16384|0|run|42|1|Cast|10|0|1.00")])
        self.assertTrue(self.link.peers[2].visible)

    def test_own_echo_and_garbage_are_dropped(self) -> None:
        self.assertEqual(self.link.on_bounced(bounce(src=1), my_slot=1), [])
        self.assertEqual(self.link.on_bounced("nope", my_slot=1), [])
        self.assertEqual(self.link.on_bounced(bounce(src=True), my_slot=1), [])
        self.assertEqual(self.link.on_bounced({"src": 2, "lv": 5, "s": []}, my_slot=1), [])
        self.assertEqual(self.link.on_bounced(bounce(samples=[["x", *fields()]]), my_slot=1), [])
        self.assertEqual(self.link.peers[2].visible, False)

    def test_other_map_peer_is_tracked_but_not_drawn(self) -> None:
        self.assertEqual(self.link.on_bounced(bounce(level="GROUNDS_HUB"), my_slot=1), [])
        self.assertIn(2, self.link.peers)
        self.assertFalse(self.link.peers[2].visible)

    def test_peer_leaving_our_map_sends_peergone_once(self) -> None:
        self.link.on_bounced(bounce(), my_slot=1)
        self.assertEqual(self.link.on_bounced(bounce(level="GROUNDS_HUB"), my_slot=1),
                         [(0.0, "PEERGONE 2")])
        self.assertEqual(self.link.on_bounced(bounce(level="GROUNDS_HUB"), my_slot=1), [])

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
        self.assertEqual(len(lines[0][1].split("|")), 15)

    def test_silent_peer_expires_with_peergone(self) -> None:
        self.link.on_bounced(bounce(), my_slot=1)
        self.clock.now += PEER_TIMEOUT_S / 2
        self.assertEqual(self.link.sweep(), [])
        self.clock.now += PEER_TIMEOUT_S
        self.assertEqual(self.link.sweep(), ["PEERGONE 2"])
        self.assertNotIn(2, self.link.peers)

    def test_expiry_of_a_never_drawn_peer_is_silent(self) -> None:
        self.link.on_bounced(bounce(level="GROUNDS_HUB"), my_slot=1)
        self.clock.now += PEER_TIMEOUT_S * 2
        self.assertEqual(self.link.sweep(), [])

    def test_forget_all_and_reset_visible(self) -> None:
        self.link.on_bounced(bounce(), my_slot=1)
        self.link.on_bounced(bounce(src=3, name="Hermione"), my_slot=1)
        self.link.reset_visible()
        self.assertEqual(self.link.forget_all(), [])
        self.link.on_bounced(bounce(), my_slot=1)
        self.assertEqual(self.link.forget_all(), ["PEERGONE 2"])
        self.assertEqual(self.link.peers, {})

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

    def test_immediate_peer_line_reaches_the_game(self) -> None:
        writer = _Writer()
        self.ctx.game_writer = writer
        self.ctx._handle_ghost_bounce({"tags": [GHOST_TAG], "data": bounce()})
        self.assertEqual(len(writer.lines), 1)
        self.assertTrue(writer.lines[0].startswith("PEER 2|Ron|"))
        self.assertTrue(writer.lines[0].endswith("\n"))

    def test_other_tags_and_disabled_ghosts_write_nothing(self) -> None:
        writer = _Writer()
        self.ctx.game_writer = writer
        self.ctx._handle_ghost_bounce({"tags": ["TrapLink"], "data": bounce()})
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
