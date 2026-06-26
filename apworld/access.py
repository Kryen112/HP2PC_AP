from typing import Callable

from BaseClasses import CollectionState

_BRONZE_CARD_NAMES: list[str] = [
    "Bronze Card - Agrippa",
    "Bronze Card - Alderton",
    "Bronze Card - Barbary",
    "Bronze Card - Barkwith",
    "Bronze Card - Belby",
    "Bronze Card - Blane",
    "Bronze Card - Bloxam",
    "Bronze Card - Bonham",
    "Bronze Card - Catchlove",
    "Bronze Card - Elphick",
    "Bronze Card - Ethelred",
    "Bronze Card - Fancourt",
    "Bronze Card - Goshawk",
    "Bronze Card - Graves",
    "Bronze Card - Gunhilda",
    "Bronze Card - Hipworth",
    "Bronze Card - Kegg",
    "Bronze Card - Ketteridge",
    "Bronze Card - Marjoribanks",
    "Bronze Card - Merlin",
    "Bronze Card - Merwyn",
    "Bronze Card - Muldoon",
    "Bronze Card - Ollerton",
    "Bronze Card - Peakes",
    "Bronze Card - Pilliwickle",
    "Bronze Card - Platt",
    "Bronze Card - Plumpton",
    "Bronze Card - Po",
    "Bronze Card - Pokeby",
    "Bronze Card - Sawbridge",
    "Bronze Card - Scamander",
    "Bronze Card - Starkey",
    "Bronze Card - Stroulger",
    "Bronze Card - Stump",
    "Bronze Card - Sweeting",
    "Bronze Card - Sykes",
    "Bronze Card - Thruston",
    "Bronze Card - Toke",
    "Bronze Card - Twonk",
    "Bronze Card - Ulric",
    "Bronze Card - Vablatsky",
    "Bronze Card - Waffling",
    "Bronze Card - Wagtail",
    "Bronze Card - Warbeck",
    "Bronze Card - Wellbeloved",
    "Bronze Card - Wenlock",
    "Bronze Card - Whitehorn",
    "Bronze Card - Wintringham",
    "Bronze Card - Withers",
    "Bronze Card - Woodcroft",
]

_SILVER_CARD_NAMES: list[str] = [
    "Silver Card - Andros",
    "Silver Card - Beamish",
    "Silver Card - Chittock",
    "Silver Card - Circe",
    "Silver Card - Clagg",
    "Silver Card - Cliodne",
    "Silver Card - Cronk",
    "Silver Card - Crumb",
    "Silver Card - Dodderidge",
    "Silver Card - Duke",
    "Silver Card - Fay",
    "Silver Card - Fulbert",
    "Silver Card - Furmage",
    "Silver Card - Gregory",
    "Silver Card - Grunnion",
    "Silver Card - Jones",
    "Silver Card - Lufkin",
    "Silver Card - Maeve",
    "Silver Card - Montmorency",
    "Silver Card - Mopsus",
    "Silver Card - Nutcombe",
    "Silver Card - Oglethorpe",
    "Silver Card - Oldridge",
    "Silver Card - Oliphant",
    "Silver Card - Plunkett",
    "Silver Card - Rastrick",
    "Silver Card - Shimpling",
    "Silver Card - Shingleton",
    "Silver Card - Smethwyck",
    "Silver Card - Stalk",
    "Silver Card - Summerbee",
    "Silver Card - Thurkell",
    "Silver Card - Toothill",
    "Silver Card - Tremlett",
    "Silver Card - Tugwood",
    "Silver Card - Wadcock",
    "Silver Card - Wendelin",
    "Silver Card - Wildsmith",
    "Silver Card - Wright",
    "Silver Card - Youdle",
]


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
