"""The mod ships the open-castle bean-room ledger as a chunked
BEANSTATE_BEGIN / BEANSTATE <chunk> ... / BEANSTATE_END envelope because the full
line outgrows its per-line TcpLink transmit cap (an over-length frame loses its
terminator and swallows the next message, which is how an Entry Hall secret's
CHECK_LOCID once went missing). These tests drive the client's real dispatch and
handlers to prove the chunks rejoin byte-for-byte and a partial snapshot is never
committed.
"""

import asyncio
import unittest

from ..Client import HP2Context

# The mod splits at BEANSTATE_CHUNK_CHARS (550) with fixed raw-character slices.
# Mirror that here; the client rejoins verbatim regardless of where boundaries
# land, so the exact size is not load-bearing (test_boundary_splits_mid_token
# exercises a split through the middle of a token).
CHUNK_SIZE = 550


def mod_chunks(payload: str, size: int = CHUNK_SIZE) -> list[str]:
    chunks: list[str] = []
    remaining = payload
    while len(remaining) > size:
        chunks.append(remaining[:size])
        remaining = remaining[size:]
    chunks.append(remaining)
    return chunks


def envelope(payload: str) -> list[str]:
    return (["BEANSTATE_BEGIN"]
            + ["BEANSTATE " + chunk for chunk in mod_chunks(payload)]
            + ["BEANSTATE_END"])


class TestBeanstateChunking(unittest.TestCase):
    def setUp(self) -> None:
        # Bypass CommonContext.__init__ (needs a server address / event loop);
        # the handlers only touch the fields set here. beanroom_key None makes
        # _persist_beanroom a no-op so no AP write is attempted.
        self.ctx = HP2Context.__new__(HP2Context)
        self.ctx._beanstate_accum = ""
        self.ctx.beanroom_state = ""
        self.ctx.beanroom_key = None

    def feed(self, lines: list[str]) -> None:
        async def run() -> None:
            for line in lines:
                await self.ctx._handle_game_line(line)
        asyncio.run(run())

    def test_single_chunk_roundtrip(self) -> None:
        self.feed(envelope("1,2,3,4,5"))
        self.assertEqual(self.ctx.beanroom_state, "1,2,3,4,5")

    def test_multi_chunk_roundtrip(self) -> None:
        # Comma-joined list well over the chunk size, so it splits across several
        # BEANSTATE lines (the real ledger that triggered the bug was ~1088 chars).
        payload = ",".join(str(n) for n in range(500))
        self.assertGreater(len(payload), CHUNK_SIZE)
        self.feed(envelope(payload))
        self.assertEqual(self.ctx.beanroom_state, payload)

    def test_boundary_splits_mid_token(self) -> None:
        # A boundary that lands inside a number must still rejoin exactly, which
        # is why the client concatenates verbatim rather than on commas.
        payload = "123456789," * 200
        self.feed(envelope(payload))
        self.assertEqual(self.ctx.beanroom_state, payload)

    def test_empty_payload(self) -> None:
        self.ctx.beanroom_state = "stale"
        self.feed(envelope(""))
        self.assertEqual(self.ctx.beanroom_state, "")

    def test_begin_resets_accumulator(self) -> None:
        # A fresh snapshot replaces the previous one; chunks never accrete across
        # envelopes.
        self.feed(envelope("first,snapshot"))
        self.feed(envelope("second"))
        self.assertEqual(self.ctx.beanroom_state, "second")

    def test_incomplete_snapshot_not_committed(self) -> None:
        # BEGIN + chunks with no END (mid-send disconnect) leaves the last good
        # value intact instead of persisting a truncated ledger.
        self.feed(envelope("good,value"))
        self.feed(["BEANSTATE_BEGIN", "BEANSTATE partial,chunk,only"])
        self.assertEqual(self.ctx.beanroom_state, "good,value")

    def test_blank_line_is_ignored(self) -> None:
        # The newline-led framing produces empty lines between messages; handling
        # one must be a harmless no-op.
        self.feed([""])
        self.assertEqual(self.ctx.beanroom_state, "")


if __name__ == "__main__":
    unittest.main()
