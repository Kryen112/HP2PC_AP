"""The dialogue randomizer must leave blacklisted feedback cues alone.

These exercise the pure shuffle function, not world generation, so they subclass
unittest.TestCase rather than the WorldTestBase. The Peeves trap-toast cackle
lives in AllDialog (the randomized package), so without the blacklist the trap
would play a random voice line instead of a laugh.
"""

import unittest

from ..dialogue_patch import ALL_ACTORS, WITHIN_ACTOR, compute_permutation, table_hash
from ..dialogue_pool import ACTORS, BLACKLIST

_MODES = (WITHIN_ACTOR, ALL_ACTORS)
_SEEDS = (0, 1, 42, 999, 123456)
_PEEVES_CACKLES = {f"PC_PVS_happy0{i}fx" for i in range(1, 7)}


class TestDialogueBlacklist(unittest.TestCase):
    def test_peeves_cackles_are_blacklisted(self) -> None:
        # The mod loads these ids by name (APGameInfo.GetGrantSoundForItem), so the
        # blacklist must cover all six takes.
        self.assertTrue(_PEEVES_CACKLES <= BLACKLIST,
                        f"missing cackles: {_PEEVES_CACKLES - BLACKLIST}")

    def test_blacklist_identity_maps(self) -> None:
        # A blacklisted id always shuffles to itself, so its audio is never moved.
        for mode in _MODES:
            for seed in _SEEDS:
                perm = compute_permutation(seed, mode)
                for name in BLACKLIST:
                    with self.subTest(mode=mode, seed=seed, name=name):
                        self.assertEqual(perm[name], name)

    def test_blacklist_never_a_target(self) -> None:
        # No other line is repointed onto a blacklisted slot, so the cackle audio is
        # never reused as someone else's voice.
        blocked = {n.lower() for n in BLACKLIST}
        for mode in _MODES:
            for seed in _SEEDS:
                perm = compute_permutation(seed, mode)
                for src, dst in perm.items():
                    if src == dst:
                        continue
                    with self.subTest(mode=mode, seed=seed, src=src):
                        self.assertNotIn(dst.lower(), blocked)

    def test_permutation_is_a_bijection(self) -> None:
        # Excluding the blacklist from the shuffle must not drop or duplicate any
        # line: the mapping stays a permutation of the full keyset.
        for mode in _MODES:
            for seed in _SEEDS:
                perm = compute_permutation(seed, mode)
                with self.subTest(mode=mode, seed=seed):
                    self.assertEqual(sorted(perm), sorted(perm.values()))

    def test_within_actor_keeps_lines_in_their_bucket(self) -> None:
        for seed in _SEEDS:
            perm = compute_permutation(seed, WITHIN_ACTOR)
            for actor, names in ACTORS.items():
                bucket = set(names)
                for name in names:
                    with self.subTest(seed=seed, actor=actor, name=name):
                        self.assertIn(perm[name], bucket)

    def test_table_hash_is_deterministic(self) -> None:
        self.assertEqual(table_hash(), table_hash())
        self.assertEqual(len(table_hash()), 16)


if __name__ == "__main__":
    unittest.main()
