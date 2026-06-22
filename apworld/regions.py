"""Auto-generated. Do not edit by hand; regenerate from data/logic_vanilla.yaml + data/logic_open_castle.yaml."""

from typing import Callable

from BaseClasses import CollectionState

START_REGION: str = 'Menu'

REGION_NAMES: list[str] = ['BeanRewardRoom', 'BicornLevel', 'BoomslangLevel', 'CastleExterior', 'ChamberOfSecrets', 'DiffindoChallenge', 'DuellingClub', 'DumbledoreStudy', 'EntryHall', 'ForbiddenForest', 'GoldCardRoom', 'GoyleLevel', 'GrandStaircase', 'GryffindorChallenge', 'Menu', 'Quidditch', 'RictusempraChallenge', 'SkurgeChallenge', 'SlytherinCommon', 'SpongifyChallenge', 'WhompingWillow']

# Silver card item names. Referenced by the Gold Card Room gate in both
# modes via has_from_list_unique (open castle needs 20, vanilla all of
# them; the in-game CardLockTrigger wires Lock1+Lock2). Sourced from
# items.yaml.cards_silver at gen time so it can never drift.
_SILVER_CARD_NAMES: list[str] = ['Silver Card - Andros', 'Silver Card - Beamish', 'Silver Card - Chittock', 'Silver Card - Circe', 'Silver Card - Clagg', 'Silver Card - Cliodne', 'Silver Card - Cronk', 'Silver Card - Crumb', 'Silver Card - Dodderidge', 'Silver Card - Duke', 'Silver Card - Fay', 'Silver Card - Fulbert', 'Silver Card - Furmage', 'Silver Card - Gregory', 'Silver Card - Grunnion', 'Silver Card - Jones', 'Silver Card - Lufkin', 'Silver Card - Maeve', 'Silver Card - Montmorency', 'Silver Card - Mopsus', 'Silver Card - Nutcombe', 'Silver Card - Oglethorpe', 'Silver Card - Oldridge', 'Silver Card - Oliphant', 'Silver Card - Plunkett', 'Silver Card - Rastrick', 'Silver Card - Shimpling', 'Silver Card - Shingleton', 'Silver Card - Smethwyck', 'Silver Card - Stalk', 'Silver Card - Summerbee', 'Silver Card - Thurkell', 'Silver Card - Toothill', 'Silver Card - Tremlett', 'Silver Card - Tugwood', 'Silver Card - Wadcock', 'Silver Card - Wendelin', 'Silver Card - Wildsmith', 'Silver Card - Wright', 'Silver Card - Youdle']

# region_name -> rule(state, player) -> bool. Mode-dependent: HP2World
# selects vanilla or open castle at gen time via self.options.game_mode.
REGION_ENTRY_RULES_VANILLA: dict[str, Callable[[CollectionState, int], bool]] = {
    'BeanRewardRoom': lambda state, player: False,
    'BicornLevel': lambda state, player: state.has('Lumos', player)  and  state.has('Flipendo', player)  and  state.has('Alohomora', player)  and  state.has('Rictusempra', player)  and  state.has('Skurge', player)  and  state.has('Bicorn Level Key', player),
    'BoomslangLevel': lambda state, player: state.has('Lumos', player)  and  state.has('Flipendo', player)  and  state.has('Alohomora', player)  and  state.has('Rictusempra', player)  and  state.has('Skurge', player)  and  state.has('Diffindo', player)  and  state.has('Bicorn Level Key', player)  and  state.has('Boomslang Level Key', player),
    'CastleExterior': lambda state, player: state.has('Lumos', player)  and  state.has('Flipendo', player),
    'ChamberOfSecrets': lambda state, player: state.has('Lumos', player)  and  state.has('Flipendo', player)  and  state.has('Alohomora', player)  and  state.has('Rictusempra', player)  and  state.has('Skurge', player)  and  state.has('Diffindo', player)  and  state.has('Spongify', player)  and  state.has('Bicorn Level Key', player)  and  state.has('Boomslang Level Key', player)  and  state.has('Goyle Level Key', player)  and  state.has('Slytherin Common Room Key', player)  and  state.has('Forbidden Forest Key', player)  and  state.has('Chamber of Secrets Key', player),
    'DiffindoChallenge': lambda state, player: state.has('Lumos', player)  and  state.has('Flipendo', player)  and  state.has('Diffindo', player),
    'DuellingClub': lambda state, player: state.has('Lumos', player)  and  state.has('Flipendo', player)  and  state.has('Alohomora', player)  and  state.has('Rictusempra', player)  and  state.has('Skurge', player)  and  state.has('Bicorn Level Key', player)  and  state.has('Duelling Key', player),
    'DumbledoreStudy': lambda state, player: state.has('Lumos', player)  and  state.has('Flipendo', player)  and  state.has('Alohomora', player)  and  state.has('Rictusempra', player)  and  state.has('Skurge', player)  and  state.has('Diffindo', player)  and  state.has('Bicorn Level Key', player)  and  state.has('Boomslang Level Key', player),
    'EntryHall': lambda state, player: state.has('Lumos', player)  and  state.has('Flipendo', player),
    'ForbiddenForest': lambda state, player: state.has('Lumos', player)  and  state.has('Flipendo', player)  and  state.has('Alohomora', player)  and  state.has('Rictusempra', player)  and  state.has('Skurge', player)  and  state.has('Diffindo', player)  and  state.has('Spongify', player)  and  state.has('Bicorn Level Key', player)  and  state.has('Boomslang Level Key', player)  and  state.has('Goyle Level Key', player)  and  state.has('Slytherin Common Room Key', player)  and  state.has('Forbidden Forest Key', player),
    'GoldCardRoom': lambda state, player: state.has('Lumos', player)  and  state.has('Flipendo', player)  and  state.has_from_list_unique(_SILVER_CARD_NAMES, player, 40),
    'GoyleLevel': lambda state, player: state.has('Lumos', player)  and  state.has('Flipendo', player)  and  state.has('Alohomora', player)  and  state.has('Rictusempra', player)  and  state.has('Skurge', player)  and  state.has('Diffindo', player)  and  state.has('Bicorn Level Key', player)  and  state.has('Boomslang Level Key', player)  and  state.has('Goyle Level Key', player),
    'GrandStaircase': lambda state, player: state.has('Lumos', player)  and  state.has('Flipendo', player),
    'GryffindorChallenge': lambda state, player: False,
    'Quidditch': lambda state, player: state.has('Lumos', player)  and  state.has('Flipendo', player)  and  state.has('Rictusempra', player)  and  state.has('Quidditch Key', player),
    'RictusempraChallenge': lambda state, player: state.has('Lumos', player)  and  state.has('Flipendo', player)  and  state.has('Rictusempra', player),
    'SkurgeChallenge': lambda state, player: state.has('Lumos', player)  and  state.has('Flipendo', player)  and  state.has('Rictusempra', player)  and  state.has('Skurge', player),
    'SlytherinCommon': lambda state, player: state.has('Lumos', player)  and  state.has('Flipendo', player)  and  state.has('Alohomora', player)  and  state.has('Rictusempra', player)  and  state.has('Skurge', player)  and  state.has('Diffindo', player)  and  state.has('Bicorn Level Key', player)  and  state.has('Boomslang Level Key', player)  and  state.has('Goyle Level Key', player)  and  state.has('Slytherin Common Room Key', player),
    'SpongifyChallenge': lambda state, player: state.has('Lumos', player)  and  state.has('Flipendo', player)  and  state.has('Alohomora', player)  and  state.has('Rictusempra', player)  and  state.has('Skurge', player)  and  state.has('Diffindo', player)  and  state.has('Spongify', player)  and  state.has('Bicorn Level Key', player)  and  state.has('Boomslang Level Key', player)  and  state.has('Goyle Level Key', player)  and  state.has('Slytherin Common Room Key', player),
    'WhompingWillow': lambda state, player: True,
}

REGION_ENTRY_RULES_OPEN_CASTLE: dict[str, Callable[[CollectionState, int], bool]] = {
    'BeanRewardRoom': lambda state, player: True,
    'BicornLevel': lambda state, player: state.has('Bicorn Level Key', player)  and  state.has('Skurge', player),
    'BoomslangLevel': lambda state, player: state.has('Boomslang Level Key', player)  and  state.has('Diffindo', player),
    'CastleExterior': lambda state, player: True,
    'ChamberOfSecrets': lambda state, player: state.has('Chamber of Secrets Key', player)  and  state.has('Alohomora', player),
    'DiffindoChallenge': lambda state, player: state.has('Diffindo Challenge Key', player)  and  state.has('Diffindo', player),
    'DuellingClub': lambda state, player: state.has('Duelling Key', player),
    'DumbledoreStudy': lambda state, player: state.has('Alohomora', player),
    'EntryHall': lambda state, player: True,
    'ForbiddenForest': lambda state, player: state.has('Forbidden Forest Key', player),
    'GoldCardRoom': lambda state, player: state.has_from_list_unique(_SILVER_CARD_NAMES, player, 20),
    'GoyleLevel': lambda state, player: state.has('Goyle Level Key', player),
    'GrandStaircase': lambda state, player: True,
    'GryffindorChallenge': lambda state, player: state.has('Gryffindor Challenge Key', player),
    'Quidditch': lambda state, player: state.has('Quidditch Key', player),
    'RictusempraChallenge': lambda state, player: state.has('Rictusempra Challenge Key', player),
    'SkurgeChallenge': lambda state, player: state.has('Skurge Challenge Key', player)  and  state.has('Skurge', player),
    'SlytherinCommon': lambda state, player: state.has('Slytherin Common Room Key', player),
    'SpongifyChallenge': lambda state, player: state.has('Spongify Challenge Key', player),
    'WhompingWillow': lambda state, player: state.has('Whomping Willow Key', player)  and  state.has('Spongify', player),
}
