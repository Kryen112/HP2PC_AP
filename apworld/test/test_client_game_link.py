"""FileGameLink is the client's end of the file channel to the game. These
tests pin the inbound wire shape (session, sequence, fragment flags), the
acknowledgement trim, the PEER coalescing, the outbound batch order and
decoding, the connect / disconnect / resume transitions of the poll loop, and
the client's connect handlers, against a temp folder standing in for the
channel directory."""

import asyncio
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from .. import Client, game_link
from ..Client import HP2Context
from ..game_link import FRAGMENT_CHARS, MAX_LINES_PER_FILE, FileGameLink


def write_batch(folder: Path, session: str, index: int, lines: "list[str]") -> None:
    text = "".join(line + "\n" for line in lines)
    (folder / f"out_{session}_{index}.log").write_bytes(b"\xff\xfe" + text.encode("utf-16-le"))


class LinkCase(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.folder = Path(self._tmp.name)
        self.link = FileGameLink(self.folder, session="abcd")

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def inbound(self) -> "list[str]":
        return (self.folder / "in.txt").read_text(encoding="latin-1").splitlines()


class TestInbound(LinkCase):
    def test_line_is_numbered_under_the_session(self) -> None:
        self.link.queue_line("GRANT 3 Lumos")
        self.assertEqual(self.link.inbound_text(), "APIn abcd 1 =GRANT 3 Lumos\r\n")

    def test_long_line_ships_as_fragments(self) -> None:
        line = "CHECKED " + "1234567," * 60
        self.link.queue_line(line)
        rows = self.link.inbound_text().splitlines()
        self.assertEqual(len(rows), -(-len(line) // FRAGMENT_CHARS))
        flags = [row.split(" ", 3)[3][0] for row in rows]
        self.assertEqual(flags, ["+"] * (len(rows) - 1) + ["="])
        self.assertEqual("".join(row.split(" ", 3)[3][1:] for row in rows), line)

    def test_write_matches_the_stream_writer_call(self) -> None:
        self.link.write(b"TOAST hello\nDEATHLINK\n")
        self.assertEqual(self.link.inbound_text(),
                         "APIn abcd 1 =TOAST hello\r\nAPIn abcd 2 =DEATHLINK\r\n")

    def test_acknowledge_drops_taken_lines(self) -> None:
        for name in ("A", "B", "C"):
            self.link.queue_line("TOAST " + name)
        self.link.acknowledge(2)
        self.assertEqual(self.link.inbound_text(), "APIn abcd 3 =TOAST C\r\n")

    def test_file_is_capped(self) -> None:
        for n in range(MAX_LINES_PER_FILE + 5):
            self.link.queue_line(f"TOAST {n}")
        self.assertEqual(len(self.link.inbound_text().splitlines()), MAX_LINES_PER_FILE)

    def test_newer_peer_replaces_an_unsent_one(self) -> None:
        self.link.queue_line("PEER 2 old")
        self.link.queue_line("PEER 3 other")
        self.link.queue_line("PEER 2 new")
        self.assertEqual(self.link.inbound_text(),
                         "APIn abcd 2 =PEER 3 other\r\nAPIn abcd 3 =PEER 2 new\r\n")

    def test_write_inbound_writes_the_file(self) -> None:
        self.link.queue_line("PING")
        self.link.write_inbound()
        self.assertEqual(self.inbound(), ["APIn abcd 1 =PING"])

    def test_connection_state_reads_as_a_writer(self) -> None:
        self.assertTrue(self.link.is_closing())
        self.link.connected = True
        self.assertFalse(self.link.is_closing())


class TestOutbound(LinkCase):
    def test_batches_are_read_in_order_and_deleted(self) -> None:
        write_batch(self.folder, "111", 10, ["CHECK 5"])
        write_batch(self.folder, "111", 9, ["HELLO"])
        self.assertEqual(self.link.read_outbound(),
                         [("111", ["HELLO"]), ("111", ["CHECK 5"])])
        self.assertEqual(list(self.folder.iterdir()), [])

    def test_unfinished_batch_is_left_alone(self) -> None:
        (self.folder / "out_111_1.tmp").write_bytes(b"")
        self.assertEqual(self.link.read_outbound(), [])
        self.assertTrue((self.folder / "out_111_1.tmp").exists())

    def test_clear_channel_removes_a_previous_session(self) -> None:
        write_batch(self.folder, "111", 1, ["HELLO"])
        (self.folder / "in.txt").write_text("APIn old 1 =PING\r\n")
        (self.folder / "keep.txt").write_text("")
        self.link.clear_channel()
        self.assertEqual([p.name for p in self.folder.iterdir()], ["keep.txt"])


class TestRunLoop(LinkCase):
    def run_loop(self, steps) -> "list[tuple]":
        events: "list[tuple]" = []

        async def on_connect(link):
            events.append(("connect", link.game_session))

        async def on_line(line):
            events.append(("line", line))

        async def on_disconnect(link):
            events.append(("disconnect", link.game_session))

        async def scenario():
            task = asyncio.create_task(self.link.run(on_connect, on_line, on_disconnect))
            for step in steps:
                await asyncio.sleep(0.05)
                step()
                await asyncio.sleep(0.05)
            task.cancel()
            try:
                await task
            except asyncio.CancelledError:
                pass

        with mock.patch.object(game_link, "POLL_SECONDS", 0.01):
            asyncio.run(scenario())
        return events

    def test_first_batch_connects_and_delivers_lines(self) -> None:
        events = self.run_loop([lambda: write_batch(self.folder, "111", 1, ["HELLO", "ALIVE"])])
        self.assertEqual(events, [("connect", "111"), ("line", "HELLO")])
        self.assertTrue(self.link.connected)

    def test_inack_trims_the_inbound_file(self) -> None:
        def step():
            self.link.queue_line("TOAST hi")
            write_batch(self.folder, "111", 1, [f"INACK abcd {self.link._next_seq - 1}"])
        self.run_loop([step])
        self.assertEqual(self.link._pending, [])

    def test_inack_for_another_session_is_ignored(self) -> None:
        def step():
            self.link.queue_line("TOAST hi")
            write_batch(self.folder, "111", 1, ["INACK other 99"])
        self.run_loop([step])
        self.assertTrue(any(p[1] == "=TOAST hi" for p in self.link._pending))

    def test_new_game_session_reconnects(self) -> None:
        events = self.run_loop([
            lambda: write_batch(self.folder, "111", 1, ["HELLO"]),
            lambda: write_batch(self.folder, "222", 1, ["HELLO"]),
        ])
        self.assertEqual(events, [("connect", "111"), ("line", "HELLO"),
                                  ("disconnect", "111"), ("connect", "222"), ("line", "HELLO")])

    def test_silent_game_times_out(self) -> None:
        with mock.patch.object(game_link, "GAME_TIMEOUT_SECONDS", 0.02):
            events = self.run_loop([lambda: write_batch(self.folder, "111", 1, ["HELLO"]),
                                    lambda: None])
        self.assertEqual(events[-1], ("disconnect", "111"))
        self.assertFalse(self.link.connected)

    def test_loop_pings(self) -> None:
        self.run_loop([lambda: None])
        self.assertIn("APIn abcd 1 =PING", self.inbound())

    def test_ping_waits_for_an_empty_backlog(self) -> None:
        self.link.queue_line("TOAST waiting")
        with mock.patch.object(game_link, "PING_SECONDS", 0.0):
            self.run_loop([lambda: None])
        self.assertEqual([p[1] for p in self.link._pending], ["=TOAST waiting"])

    def test_new_game_session_drops_unsent_lines(self) -> None:
        def step():
            self.link.queue_line("DEATHLINK")
            write_batch(self.folder, "222", 1, ["HELLO"])
        self.run_loop([lambda: write_batch(self.folder, "111", 1, ["HELLO"]), step])
        self.assertFalse(any(p[1] == "=DEATHLINK" for p in self.link._pending))

    def test_resume_after_timeout_requests_hello(self) -> None:
        backlog_at_connect = []

        async def on_connect(link):
            backlog_at_connect.append([p[1] for p in link._pending])

        async def noop(*_):
            pass

        async def scenario():
            task = asyncio.create_task(self.link.run(on_connect, noop, noop))
            await asyncio.sleep(0.05)
            write_batch(self.folder, "111", 1, ["HELLO"])
            await asyncio.sleep(0.1)
            write_batch(self.folder, "111", 2, ["ALIVE"])
            await asyncio.sleep(0.05)
            task.cancel()
            try:
                await task
            except asyncio.CancelledError:
                pass

        with mock.patch.object(game_link, "POLL_SECONDS", 0.01), \
                mock.patch.object(game_link, "GAME_TIMEOUT_SECONDS", 0.03):
            asyncio.run(scenario())
        self.assertEqual(len(backlog_at_connect), 2)
        self.assertNotIn("=HELLOREQ", backlog_at_connect[0])
        self.assertIn("=HELLOREQ", backlog_at_connect[1])


class _WiringCtx(HP2Context):
    """Context with only the game-link state the connect handlers touch."""

    def __init__(self) -> None:
        self.game_writer = None
        self.sent_this_session = {99}
        self.pending_grants = ["GRANT 4 Lumos", "GRANT 5 Flipendo"]


class TestClientWiring(LinkCase):
    def test_connect_resets_the_session_and_drains_queued_grants(self) -> None:
        ctx = _WiringCtx()
        asyncio.run(ctx._on_game_connected(self.link))
        self.assertIs(ctx.game_writer, self.link)
        self.assertEqual(ctx.sent_this_session, {4, 5})
        self.assertEqual(ctx.pending_grants, [])
        self.assertEqual(self.link.inbound_text(),
                         "APIn abcd 1 =GRANT 4 Lumos\r\nAPIn abcd 2 =GRANT 5 Flipendo\r\n")

    def test_disconnect_clears_only_its_own_link(self) -> None:
        ctx = _WiringCtx()
        newer = FileGameLink(self.folder, session="newer")
        ctx.game_writer = newer
        asyncio.run(ctx._on_game_disconnected(self.link))
        self.assertIs(ctx.game_writer, newer)
        asyncio.run(ctx._on_game_disconnected(newer))
        self.assertIsNone(ctx.game_writer)

    def test_unusable_link_folder_is_reported(self) -> None:
        blocker = self.folder / "file"
        blocker.write_text("")
        ctx = _WiringCtx()
        with mock.patch.object(Client.installer, "channel_dir", return_value=blocker / "AP"):
            with self.assertLogs("Client", level="ERROR") as logs:
                asyncio.run(ctx.run_game_link())
        self.assertIn("Could not create the game link folder", logs.output[0])


class TestLoopRobustness(LinkCase):
    def test_failing_line_handler_does_not_stop_the_link(self) -> None:
        seen = []

        async def on_line(line):
            seen.append(line)
            raise ValueError("bad line")

        async def noop(_link):
            pass

        async def scenario():
            task = asyncio.create_task(self.link.run(noop, on_line, noop))
            await asyncio.sleep(0.05)
            write_batch(self.folder, "111", 1, ["CHECK x"])
            await asyncio.sleep(0.05)
            write_batch(self.folder, "111", 2, ["CHECK y"])
            await asyncio.sleep(0.05)
            task.cancel()
            try:
                await task
            except asyncio.CancelledError:
                pass

        with mock.patch.object(game_link, "POLL_SECONDS", 0.01), self.assertLogs("HP2Client", level="ERROR"):
            asyncio.run(scenario())
        self.assertEqual(seen, ["CHECK x", "CHECK y"])


if __name__ == "__main__":
    unittest.main()
