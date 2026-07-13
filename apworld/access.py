from typing import Callable

from BaseClasses import CollectionState

from .items import ITEM_GROUPS, PROGRESSIVE_LEVEL_KEY_NAME

# Card-name lists for the count rules below. Derived from ITEM_GROUPS so the
# logic can never desync from the item definitions. has_from_list_unique only
# cares about membership, so order is irrelevant here.
_BRONZE_CARD_NAMES: list[str] = list(ITEM_GROUPS["Cards (Bronze)"])
_SILVER_CARD_NAMES: list[str] = list(ITEM_GROUPS["Cards (Silver)"])


class _Access:
    """A composable access rule. Callable as rule(state, player), and combined
    with & (and) / | (or). The rule tables parenthesise explicitly, so & / |
    precedence never matters."""

    __slots__ = ("_test",)

    def __init__(self, test: "Callable[[CollectionState, int], bool]"):
        self._test = test

    def __call__(self, state: CollectionState, player: int) -> bool:
        return self._test(state, player)

    def __and__(self, other: "_Access") -> "_Access":
        return _Access(lambda state, player: self(state, player) and other(state, player))

    def __or__(self, other: "_Access") -> "_Access":
        return _Access(lambda state, player: self(state, player) or other(state, player))


def _item(name: str) -> _Access:
    return _Access(lambda state, player: state.has(name, player))


def _bronze_cards(count: int) -> _Access:
    return _Access(lambda state, player: state.has_from_list_unique(_BRONZE_CARD_NAMES, player, count))


def _silver_cards(count: int) -> _Access:
    return _Access(lambda state, player: state.has_from_list_unique(_SILVER_CARD_NAMES, player, count))


def _progressive_level_keys(count: int) -> _Access:
    return _Access(lambda state, player: state.has(PROGRESSIVE_LEVEL_KEY_NAME, player, count))


never = _Access(lambda state, player: False)
always = _Access(lambda state, player: True)

# Spells
alohomora = _item("Alohomora")
diffindo = _item("Diffindo")
flipendo = _item("Flipendo")
lumos = _item("Lumos")
rictusempra = _item("Rictusempra")
skurge = _item("Skurge")
spongify = _item("Spongify")
# Logic flags
running = _item("Running")
# Blocker keys
chamber_of_secrets_key = _item("Chamber of Secrets Key")
spongify_challenge_key = _item("Spongify Challenge Key")
skurge_challenge_key = _item("Skurge Challenge Key")
rictusempra_challenge_key = _item("Rictusempra Challenge Key")
diffindo_challenge_key = _item("Diffindo Challenge Key")
boomslang_level_key = _item("Boomslang Level Key")
whomping_willow_key = _item("Whomping Willow Key")
forbidden_forest_key = _item("Forbidden Forest Key")
slytherin_common_room_key = _item("Slytherin Common Room Key")
goyle_level_key = _item("Goyle Level Key")
bicorn_level_key = _item("Bicorn Level Key")
duelling_key = _item("Duelling Key")
quidditch_key = _item("Quidditch Key")
gryffindor_challenge_key = _item("Gryffindor Challenge Key")

# Vanilla story-chain key requirement through each level, in story order. Each
# step passes on either form the seed uses: the named keys (precollected when
# vanilla_gate_levels is off) or enough Progressive Level Key copies (the pool
# form when vanilla_gate_levels is on). Open castle rules keep the bare named
# keys since its regions are standalone-gated, never chained.
keys_through_bicorn = bicorn_level_key | _progressive_level_keys(1)
keys_through_boomslang = (
    bicorn_level_key & boomslang_level_key
) | _progressive_level_keys(2)
keys_through_goyle = (
    bicorn_level_key & boomslang_level_key & goyle_level_key
) | _progressive_level_keys(3)
keys_through_slytherin_common_room = (
    bicorn_level_key & boomslang_level_key & goyle_level_key & slytherin_common_room_key
) | _progressive_level_keys(4)
keys_through_forbidden_forest = (
    bicorn_level_key & boomslang_level_key & goyle_level_key & slytherin_common_room_key
    & forbidden_forest_key
) | _progressive_level_keys(5)
