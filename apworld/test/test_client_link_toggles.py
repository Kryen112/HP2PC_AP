"""RingLink, TrapLink and DeathLink are opt-in per seed, but a player may flip
any of them mid-run with /ringlink, /traplink or /deathlink. None of the three
is an item or a location, so an override cannot affect solvability. These tests
drive the real context and command-processor methods to pin the override
precedence (a player's choice beats slot_data on every Connected, so a
reconnect does not silently revert it), the argument parsing, and the
synchronous live flags that gate an outbound death, bean delta or trap."""

import unittest
from unittest import mock

from ..Client import _LINK_KINDS, HP2CommandProcessor, HP2Context

ALL_ON = {"ring_link": 1, "trap_link": 1, "death_link": 1}
ALL_OFF = {"ring_link": 0, "trap_link": 0, "death_link": 0}


class _Ctx(HP2Context):
    """Context with the link state initialised and the tag work recorded rather
    than dispatched, so no event loop or server connection is needed."""

    def __init__(self) -> None:
        self.link_seed_state = {kind: False for kind in _LINK_KINDS}
        self.link_overrides = {kind: None for kind in _LINK_KINDS}
        self.link_seed_known = False
        self.ring_link_enabled = False
        self.trap_link_enabled = False
        self.death_link_enabled = False
        self.applied: list = []

    def apply_link_state(self, kind: str, enabled: bool) -> None:
        # Records the dispatch and keeps the live flag in step, so link_live
        # reads back what the real method would have set.
        self.applied.append((kind, enabled))
        setattr(self, _LINK_KINDS[kind].state_attr, enabled)


class _Processor(HP2CommandProcessor):
    def __init__(self, ctx: _Ctx) -> None:
        self.ctx = ctx
        self.lines: list = []

    def output(self, text: str) -> None:
        self.lines.append(text)


class TestLinkOverridePrecedence(unittest.TestCase):
    def setUp(self) -> None:
        self.ctx = _Ctx()

    def test_no_override_follows_the_seed(self) -> None:
        self.assertEqual(self.ctx.refresh_links(ALL_ON),
                         {"ring": True, "trap": True, "death": True})
        self.assertEqual(self.ctx.refresh_links(ALL_OFF),
                         {"ring": False, "trap": False, "death": False})
        for kind in _LINK_KINDS:
            self.assertIsNone(self.ctx.link_overrides[kind])

    def test_missing_slot_data_key_reads_as_off(self) -> None:
        # An older seed's slot_data omits a key entirely.
        self.assertEqual(self.ctx.refresh_links({}),
                         {"ring": False, "trap": False, "death": False})

    def test_override_on_beats_a_seed_that_rolled_off(self) -> None:
        for kind in _LINK_KINDS:
            self.ctx.link_overrides[kind] = True
        self.assertEqual(self.ctx.refresh_links(ALL_OFF),
                         {"ring": True, "trap": True, "death": True})

    def test_override_off_beats_a_seed_that_rolled_on(self) -> None:
        for kind in _LINK_KINDS:
            self.ctx.link_overrides[kind] = False
        self.assertEqual(self.ctx.refresh_links(ALL_ON),
                         {"ring": False, "trap": False, "death": False})

    def test_reconnect_does_not_revert_an_override(self) -> None:
        # Re-reading slot_data on every Connected must not stomp a choice the
        # player already made.
        self.ctx.refresh_links(ALL_ON)
        for kind in _LINK_KINDS:
            self.ctx.link_overrides[kind] = False
        for _ in range(3):
            self.assertEqual(self.ctx.refresh_links(ALL_ON),
                             {"ring": False, "trap": False, "death": False})

    def test_reconnect_reapplies_even_when_nothing_changed(self) -> None:
        # refresh_links deliberately does not take the no-op skip _set_link has:
        # every Connected re-rolls ring_source and re-tags, which is what keeps
        # a reconnect routable for Bounced packets.
        self.ctx.refresh_links(ALL_ON)
        self.ctx.refresh_links(ALL_ON)
        self.assertEqual(len(self.ctx.applied), 2 * len(_LINK_KINDS))

    def test_seed_state_is_recorded_even_while_overridden(self) -> None:
        for kind in _LINK_KINDS:
            self.ctx.link_overrides[kind] = False
        self.ctx.refresh_links(ALL_ON)
        for kind in _LINK_KINDS:
            self.assertTrue(self.ctx.link_seed_state[kind])
            self.assertFalse(self.ctx.link_wanted(kind))

    def test_every_link_is_applied_once_per_connected(self) -> None:
        self.ctx.refresh_links(ALL_ON)
        self.assertEqual(sorted(kind for kind, _ in self.ctx.applied),
                         sorted(_LINK_KINDS))


class TestLinkCommands(unittest.TestCase):
    def setUp(self) -> None:
        self.ctx = _Ctx()
        self.processor = _Processor(self.ctx)

    def run_command(self, kind: str, arg: str = "") -> None:
        {"ring": self.processor._cmd_ringlink,
         "trap": self.processor._cmd_traplink,
         "death": self.processor._cmd_deathlink}[kind](arg)

    def test_on_and_off_set_the_override(self) -> None:
        for kind in _LINK_KINDS:
            self.run_command(kind, "on")
            self.assertIs(self.ctx.link_overrides[kind], True)
            self.assertTrue(self.ctx.link_wanted(kind))
            self.run_command(kind, "off")
            self.assertIs(self.ctx.link_overrides[kind], False)
            self.assertFalse(self.ctx.link_wanted(kind))

    def test_argument_spellings_and_case(self) -> None:
        for arg in ("ON", " on ", "true", "1"):
            self.ctx.link_overrides["ring"] = None
            self.run_command("ring", arg)
            self.assertIs(self.ctx.link_overrides["ring"], True, arg)
        for arg in ("Off", "false", "0"):
            self.ctx.link_overrides["ring"] = None
            self.run_command("ring", arg)
            self.assertIs(self.ctx.link_overrides["ring"], False, arg)

    def test_bare_command_flips_the_effective_state(self) -> None:
        self.ctx.refresh_links(ALL_ON)
        self.run_command("death", "")
        self.assertFalse(self.ctx.link_wanted("death"))
        self.run_command("death", "")
        self.assertTrue(self.ctx.link_wanted("death"))

    def test_bare_command_flips_on_a_seed_that_rolled_off(self) -> None:
        self.ctx.refresh_links(ALL_OFF)
        self.run_command("trap", "")
        self.assertIs(self.ctx.link_overrides["trap"], True)

    def test_seed_argument_drops_the_override(self) -> None:
        self.ctx.refresh_links(ALL_ON)
        self.run_command("ring", "off")
        self.assertFalse(self.ctx.link_wanted("ring"))
        self.run_command("ring", "seed")
        self.assertIsNone(self.ctx.link_overrides["ring"])
        self.assertTrue(self.ctx.link_wanted("ring"))
        self.assertEqual(self.ctx.applied[-1], ("ring", True))

    def test_unparseable_argument_changes_nothing(self) -> None:
        self.ctx.refresh_links(ALL_ON)
        before = len(self.ctx.applied)
        self.run_command("ring", "yes please")
        self.assertIsNone(self.ctx.link_overrides["ring"])
        self.assertEqual(len(self.ctx.applied), before)
        self.assertIn("Usage: /ringlink", self.processor.lines[-1])

    def test_link_commands_take_raw_text(self) -> None:
        # The processor splits an argument on whitespace unless the command is
        # marked raw, so a multi-word argument has to arrive whole to reach the
        # usage message instead of raising on an unexpected second positional.
        for command in (HP2CommandProcessor._cmd_ringlink,
                        HP2CommandProcessor._cmd_traplink,
                        HP2CommandProcessor._cmd_deathlink):
            self.assertTrue(getattr(command, "raw_text", False), command.__name__)

    def test_redundant_command_does_not_reapply(self) -> None:
        # Re-enabling a live RingLink would re-roll ring_source, unfiltering an
        # in-flight echo of this slot's own Bounce.
        self.ctx.refresh_links(ALL_ON)
        before = len(self.ctx.applied)
        self.run_command("ring", "on")
        self.run_command("ring", "seed")
        self.assertEqual(len(self.ctx.applied), before)
        self.assertTrue(self.ctx.link_live("ring"))

    def test_a_real_change_still_reapplies(self) -> None:
        self.ctx.refresh_links(ALL_ON)
        before = len(self.ctx.applied)
        self.run_command("ring", "off")
        self.assertEqual(len(self.ctx.applied), before + 1)
        self.assertFalse(self.ctx.link_live("ring"))

    def test_before_connecting_no_seed_setting_is_quoted(self) -> None:
        # link_seed_state is all False before the first Connected, so claiming
        # "the seed rolled off" there would be a guess.
        self.assertFalse(self.ctx.link_seed_known)
        self.run_command("death", "on")
        self.assertNotIn("the seed rolled", self.processor.lines[-1])
        self.assertIn("whatever the seed rolls", self.processor.lines[-1])
        self.run_command("death", "seed")
        self.assertNotIn("the seed rolled", self.processor.lines[-1])

    def test_command_applies_the_new_state_immediately(self) -> None:
        self.run_command("trap", "on")
        self.assertEqual(self.ctx.applied[-1], ("trap", True))
        self.run_command("trap", "off")
        self.assertEqual(self.ctx.applied[-1], ("trap", False))

    def test_output_names_the_link_and_the_seed_setting(self) -> None:
        self.ctx.refresh_links(ALL_ON)
        self.run_command("death", "off")
        self.assertIn("DeathLink is now off", self.processor.lines[-1])
        self.assertIn("the seed rolled on", self.processor.lines[-1])

    def test_commands_work_before_any_seed_is_connected(self) -> None:
        # No Connected yet: the override still lands and wins once slot_data
        # arrives, so a player can set a link up front.
        self.run_command("ring", "on")
        self.assertIs(self.ctx.refresh_links(ALL_OFF)["ring"], True)


class TestApplyLinkState(unittest.TestCase):
    """The real apply_link_state, with the tag task captured rather than run."""

    def setUp(self) -> None:
        self.ctx = HP2Context.__new__(HP2Context)
        for spec in _LINK_KINDS.values():
            setattr(self.ctx, spec.state_attr, False)

    def apply(self, kind: str, enabled: bool) -> str:
        coroutines: list = []
        with mock.patch("asyncio.create_task", side_effect=coroutines.append):
            self.ctx.apply_link_state(kind, enabled)
        self.assertEqual(len(coroutines), 1)
        name = coroutines[0].__qualname__
        coroutines[0].close()
        return name

    def test_flag_flips_before_the_task_is_dispatched(self) -> None:
        # An outbound death, bean delta or trap broadcast in that same turn is
        # gated on the new state, so a disable cannot leak one more send.
        for kind, spec in _LINK_KINDS.items():
            self.apply(kind, True)
            self.assertTrue(getattr(self.ctx, spec.state_attr), kind)
            self.apply(kind, False)
            self.assertFalse(getattr(self.ctx, spec.state_attr), kind)

    def test_each_kind_dispatches_its_own_coroutine(self) -> None:
        self.assertEqual(self.apply("ring", True), "HP2Context._enable_ring_link")
        self.assertEqual(self.apply("ring", False), "HP2Context._disable_ring_link")
        self.assertEqual(self.apply("trap", True), "HP2Context._enable_trap_link")
        self.assertEqual(self.apply("trap", False), "HP2Context._disable_trap_link")
        for enabled in (True, False):
            self.assertEqual(self.apply("death", enabled),
                             "CommonContext.update_death_link")


class TestDisableLogsOnlyWhenTagged(unittest.IsolatedAsyncioTestCase):
    """The ring and trap disable log lines are unconditional, so the absent-tag
    early return is the only thing keeping a link-off seed from reporting a
    teardown that never happened on every Connected."""

    def make_ctx(self, tagged: bool) -> HP2Context:
        ctx = HP2Context.__new__(HP2Context)
        ctx.ring_link_enabled = tagged
        ctx.trap_link_enabled = tagged
        ctx.ring_source = 1234 if tagged else None
        ctx.server = None
        ctx.tags = {"AP", "RingLink", "TrapLink"} if tagged else {"AP"}
        return ctx

    async def test_tagged_disable_drops_the_tag_and_logs_once(self) -> None:
        ctx = self.make_ctx(tagged=True)
        with self.assertLogs("HP2Client", level="INFO") as caught:
            await ctx._disable_ring_link()
            await ctx._disable_trap_link()
        self.assertNotIn("RingLink", ctx.tags)
        self.assertNotIn("TrapLink", ctx.tags)
        self.assertIsNone(ctx.ring_source)
        self.assertEqual(len(caught.output), 2)
        for kind, line in zip(("ring", "trap"), caught.output):
            self.assertIn(_LINK_KINDS[kind].noun, line)

    async def test_untagged_disable_is_silent(self) -> None:
        ctx = self.make_ctx(tagged=False)
        with self.assertNoLogs("HP2Client", level="INFO"):
            await ctx._disable_ring_link()
            await ctx._disable_trap_link()
        self.assertFalse(ctx.ring_link_enabled)
        self.assertFalse(ctx.trap_link_enabled)


if __name__ == "__main__":
    unittest.main()
