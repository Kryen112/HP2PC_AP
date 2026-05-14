"""Auto-generated. Do not edit by hand; regenerate from data/logic_vanilla.yaml + data/logic_bingo.yaml."""

from typing import Callable

from BaseClasses import CollectionState

START_REGION: str = 'Menu'

REGION_NAMES: list[str] = ['BicornLevel', 'BoomslangLevel', 'CastleExterior', 'ChamberOfSecrets', 'DiffindoChallenge', 'DuelingClub', 'DumbledoreStudy', 'ForbiddenForest', 'GoldCardRoom', 'GoyleLevel', 'Hogwarts', 'Menu', 'Quidditch', 'RictusempraChallenge', 'SkurgeChallenge', 'SlytherinCommon', 'SpongifyChallenge', 'WhompingWillow']

# region_name -> rule(state, player) -> bool. Mode-dependent: HP2World
# selects vanilla or bingo at gen time via self.options.game_mode.
REGION_ENTRY_RULES_VANILLA: dict[str, Callable[[CollectionState, int], bool]] = {
    'BicornLevel': lambda state, player: state.has('Lumos', player)  and  state.has('Flipendo', player)  and  state.has('Alohomora', player)  and  state.has('Rictusempra', player)  and  state.has('Skurge', player)  and  state.has('Bicorn Level Key', player),
    'BoomslangLevel': lambda state, player: state.has('Lumos', player)  and  state.has('Flipendo', player)  and  state.has('Alohomora', player)  and  state.has('Rictusempra', player)  and  state.has('Skurge', player)  and  state.has('Diffindo', player)  and  state.has('Boomslang Level Key', player),
    'CastleExterior': lambda state, player: True,
    'ChamberOfSecrets': lambda state, player: state.has('Lumos', player)  and  state.has('Flipendo', player)  and  state.has('Alohomora', player)  and  state.has('Rictusempra', player)  and  state.has('Skurge', player)  and  state.has('Diffindo', player)  and  state.has('Spongify', player)  and  state.has('Chamber of Secrets Key', player),
    'DiffindoChallenge': lambda state, player: state.has('Lumos', player)  and  state.has('Flipendo', player)  and  state.has('Alohomora', player)  and  state.has('Rictusempra', player)  and  state.has('Skurge', player)  and  state.has('Diffindo', player)  and  state.has('Diffindo Challenge Key', player),
    'DuelingClub': lambda state, player: state.has('Lumos', player)  and  state.has('Flipendo', player)  and  state.has('Rictusempra', player)  and  state.has('Skurge', player)  and  state.has('Duelling Key', player),
    'DumbledoreStudy': lambda state, player: state.has('Lumos', player)  and  state.has('Flipendo', player)  and  state.has('Alohomora', player)  and  state.has('Rictusempra', player)  and  state.has('Skurge', player)  and  state.has('Diffindo', player),
    'ForbiddenForest': lambda state, player: state.has('Lumos', player)  and  state.has('Flipendo', player)  and  state.has('Alohomora', player)  and  state.has('Rictusempra', player)  and  state.has('Skurge', player)  and  state.has('Diffindo', player)  and  state.has('Spongify', player)  and  state.has('Forbidden Forest Key', player),
    'GoldCardRoom': lambda state, player: True,
    'GoyleLevel': lambda state, player: state.has('Lumos', player)  and  state.has('Flipendo', player)  and  state.has('Alohomora', player)  and  state.has('Rictusempra', player)  and  state.has('Skurge', player)  and  state.has('Diffindo', player)  and  state.has('Goyle Level Key', player),
    'Hogwarts': lambda state, player: True,
    'Quidditch': lambda state, player: state.has('Lumos', player)  and  state.has('Flipendo', player)  and  state.has('Rictusempra', player)  and  state.has('Quidditch Key', player),
    'RictusempraChallenge': lambda state, player: state.has('Lumos', player)  and  state.has('Flipendo', player)  and  state.has('Alohomora', player)  and  state.has('Rictusempra', player)  and  state.has('Rictusempra Challenge Key', player),
    'SkurgeChallenge': lambda state, player: state.has('Lumos', player)  and  state.has('Flipendo', player)  and  state.has('Rictusempra', player)  and  state.has('Skurge', player)  and  state.has('Skurge Challenge Key', player),
    'SlytherinCommon': lambda state, player: state.has('Lumos', player)  and  state.has('Flipendo', player)  and  state.has('Alohomora', player)  and  state.has('Rictusempra', player)  and  state.has('Skurge', player)  and  state.has('Diffindo', player)  and  state.has('Slytherin Common Room Key', player),
    'SpongifyChallenge': lambda state, player: state.has('Lumos', player)  and  state.has('Flipendo', player)  and  state.has('Alohomora', player)  and  state.has('Rictusempra', player)  and  state.has('Skurge', player)  and  state.has('Diffindo', player)  and  state.has('Spongify', player)  and  state.has('Spongify Challenge Key', player),
    'WhompingWillow': lambda state, player: state.has('Whomping Willow Key', player),
}

REGION_ENTRY_RULES_BINGO: dict[str, Callable[[CollectionState, int], bool]] = {
    'BicornLevel': lambda state, player: state.has('Lumos', player)  and  state.has('Flipendo', player)  and  state.has('Alohomora', player)  and  state.has('Rictusempra', player)  and  state.has('Skurge', player)  and  state.has('Bicorn Level Key', player),
    'BoomslangLevel': lambda state, player: state.has('Lumos', player)  and  state.has('Flipendo', player)  and  state.has('Alohomora', player)  and  state.has('Rictusempra', player)  and  state.has('Skurge', player)  and  state.has('Diffindo', player)  and  state.has('Boomslang Level Key', player),
    'CastleExterior': lambda state, player: True,
    'ChamberOfSecrets': lambda state, player: state.has('Lumos', player)  and  state.has('Flipendo', player)  and  state.has('Alohomora', player)  and  state.has('Rictusempra', player)  and  state.has('Skurge', player)  and  state.has('Diffindo', player)  and  state.has('Spongify', player)  and  state.has('Chamber of Secrets Key', player),
    'DiffindoChallenge': lambda state, player: state.has('Lumos', player)  and  state.has('Flipendo', player)  and  state.has('Alohomora', player)  and  state.has('Rictusempra', player)  and  state.has('Skurge', player)  and  state.has('Diffindo', player)  and  state.has('Diffindo Challenge Key', player),
    'DuelingClub': lambda state, player: state.has('Lumos', player)  and  state.has('Flipendo', player)  and  state.has('Rictusempra', player)  and  state.has('Skurge', player)  and  state.has('Duelling Key', player),
    'DumbledoreStudy': lambda state, player: state.has('Lumos', player)  and  state.has('Flipendo', player)  and  state.has('Alohomora', player)  and  state.has('Rictusempra', player)  and  state.has('Skurge', player)  and  state.has('Diffindo', player),
    'ForbiddenForest': lambda state, player: state.has('Lumos', player)  and  state.has('Flipendo', player)  and  state.has('Alohomora', player)  and  state.has('Rictusempra', player)  and  state.has('Skurge', player)  and  state.has('Diffindo', player)  and  state.has('Spongify', player)  and  state.has('Forbidden Forest Key', player),
    'GoldCardRoom': lambda state, player: True,
    'GoyleLevel': lambda state, player: state.has('Lumos', player)  and  state.has('Flipendo', player)  and  state.has('Alohomora', player)  and  state.has('Rictusempra', player)  and  state.has('Skurge', player)  and  state.has('Diffindo', player)  and  state.has('Goyle Level Key', player),
    'Hogwarts': lambda state, player: True,
    'Quidditch': lambda state, player: state.has('Lumos', player)  and  state.has('Flipendo', player)  and  state.has('Rictusempra', player)  and  state.has('Quidditch Key', player),
    'RictusempraChallenge': lambda state, player: state.has('Lumos', player)  and  state.has('Flipendo', player)  and  state.has('Alohomora', player)  and  state.has('Rictusempra', player)  and  state.has('Rictusempra Challenge Key', player),
    'SkurgeChallenge': lambda state, player: state.has('Lumos', player)  and  state.has('Flipendo', player)  and  state.has('Rictusempra', player)  and  state.has('Skurge', player)  and  state.has('Skurge Challenge Key', player),
    'SlytherinCommon': lambda state, player: state.has('Lumos', player)  and  state.has('Flipendo', player)  and  state.has('Alohomora', player)  and  state.has('Rictusempra', player)  and  state.has('Skurge', player)  and  state.has('Diffindo', player)  and  state.has('Slytherin Common Room Key', player),
    'SpongifyChallenge': lambda state, player: state.has('Lumos', player)  and  state.has('Flipendo', player)  and  state.has('Alohomora', player)  and  state.has('Rictusempra', player)  and  state.has('Skurge', player)  and  state.has('Diffindo', player)  and  state.has('Spongify', player)  and  state.has('Spongify Challenge Key', player),
    'WhompingWillow': lambda state, player: state.has('Whomping Willow Key', player),
}
