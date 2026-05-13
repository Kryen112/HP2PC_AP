"""Auto-generated. Do not edit by hand; regenerate from data/logic.yaml."""

from typing import Callable

from BaseClasses import CollectionState

# Per-location additional rules. Location is reachable iff its region's
# entry rule passes AND this rule passes. Locations not listed here have no
# extra requirement (the region's entry rule alone gates reachability).
LOCATION_RULES: dict[str, Callable[[CollectionState, int], bool]] = {
    'Castle Exterior - Card Marjoribanks': lambda state, player: state.has('Alohomora', player)  and  state.has('Rictusempra', player)  and  state.has('Skurge', player),
    'Castle Exterior - Card Oglethorpe': lambda state, player: state.has('Alohomora', player)  and  state.has('Spongify', player)  and  state.has('Diffindo', player),
    'Castle Exterior - Card Plunkett': lambda state, player: state.has('Alohomora', player)  and  state.has('Diffindo', player),
    'Castle Exterior - Card Pokeby': lambda state, player: state.has('Alohomora', player)  and  state.has('Rictusempra', player)  and  state.has('Skurge', player),
    'Castle Exterior - Card Sykes': lambda state, player: state.has('Spongify', player),
    'Castle Exterior - Card Twonk': lambda state, player: state.has('Alohomora', player)  and  state.has('Diffindo', player),
    'Castle Exterior - Card Wadcock': lambda state, player: state.has('Alohomora', player),
    'Castle Exterior - Card Youdle': lambda state, player: state.has('Alohomora', player)  and  state.has('Rictusempra', player)  and  state.has('Skurge', player),
    'Castle Exterior - Nimbus 2001': lambda state, player: state.has('Rictusempra', player),
    'Castle Exterior - Quidditch Armour': lambda state, player: state.has('Rictusempra', player),
    'Hogwarts - Card Alderton': lambda state, player: state.has('Alohomora', player)  and  state.has('Spongify', player),
    'Hogwarts - Card Andros': lambda state, player: state.has('Alohomora', player),
    'Hogwarts - Card Barkwith': lambda state, player: state.has('Alohomora', player)  and  state.has('Rictusempra', player),
    'Hogwarts - Card Blane': lambda state, player: state.has('Alohomora', player)  and  state.has('Rictusempra', player)  and  state.has('Skurge', player),
    'Hogwarts - Card Bonham': lambda state, player: state.has('Alohomora', player),
    'Hogwarts - Card Dodderidge': lambda state, player: state.has('Alohomora', player),
    'Hogwarts - Card Ethelred': lambda state, player: state.has('Alohomora', player),
    'Hogwarts - Card Gunhilda': lambda state, player: state.has('Alohomora', player)  and  state.has('Rictusempra', player),
    'Hogwarts - Card Hipworth': lambda state, player: state.has('Alohomora', player),
    'Hogwarts - Card Jones': lambda state, player: state.has('Alohomora', player)  and  state.has('Diffindo', player),
    'Hogwarts - Card Lufkin': lambda state, player: state.has('Alohomora', player)  and  state.has('Skurge', player)  and  state.has('Diffindo', player)  and  state.has('Spongify', player),
    'Hogwarts - Card Maeve': lambda state, player: state.has('Alohomora', player),
    'Hogwarts - Card Montmorency': lambda state, player: state.has('Alohomora', player)  and  state.has('Skurge', player)  and  state.has('Rictusempra', player),
    'Hogwarts - Card Mopsus': lambda state, player: state.has('Alohomora', player)  and  state.has('Skurge', player)  and  state.has('Diffindo', player),
    'Hogwarts - Card Oldridge': lambda state, player: state.has('Spongify', player),
    'Hogwarts - Card Sawbridge': lambda state, player: state.has('Alohomora', player),
    'Hogwarts - Card Shingleton': lambda state, player: state.has('Alohomora', player)  and  state.has('Skurge', player)  and  state.has('Rictusempra', player),
    'Hogwarts - Card Toothill': lambda state, player: state.has('Spongify', player),
    'Hogwarts - Card Vablatsky': lambda state, player: state.has('Alohomora', player)  and  state.has('Rictusempra', player)  and  state.has('Skurge', player),
    'Hogwarts - Card Wendelin': lambda state, player: state.has('Alohomora', player)  and  state.has('Skurge', player)  and  state.has('Diffindo', player)  and  state.has('Rictusempra', player),
    'Hogwarts - Card Wright': lambda state, player: state.has('Alohomora', player)  and  state.has('Diffindo', player),
    'Learned Diffindo': lambda state, player: state.has('Alohomora', player)  and  state.has('Rictusempra', player)  and  state.has('Skurge', player)  and  state.has('Diffindo', player),
    'Learned Rictusempra': lambda state, player: state.has('Rictusempra', player),
    'Learned Skurge': lambda state, player: state.has('Rictusempra', player)  and  state.has('Skurge', player),
    'Learned Spongify': lambda state, player: state.has('Alohomora', player)  and  state.has('Rictusempra', player)  and  state.has('Skurge', player)  and  state.has('Diffindo', player),
    'Skurge Challenge - Card Belby': lambda state, player: state.has('Alohomora', player),
    'Skurge Challenge - Card Catchlove': lambda state, player: state.has('Alohomora', player),
    'Skurge Challenge - Card Fulbert': lambda state, player: state.has('Alohomora', player),
    'Skurge Challenge - Card Kegg': lambda state, player: state.has('Alohomora', player),
    'Skurge Challenge - Card Wenlock': lambda state, player: state.has('Alohomora', player),
}

# goal_name -> direct item/logic rule for victory generation.
# Runtime completion still comes from the game-side GOAL_COMPLETE signal.
GOAL_RULES: dict[str, Callable[[CollectionState, int], bool]] = {
    'basilisk': lambda state, player: state.has('Flipendo', player)  and  state.has('Lumos', player)  and  state.has('Alohomora', player)  and  state.has('Diffindo', player)  and  state.has('Rictusempra', player)  and  state.has('Skurge', player)  and  state.has('Spongify', player),
}

# Optional goal_name -> location names that must be reachable for victory.
GOAL_LOCATION_REQUIREMENTS: dict[str, list[str]] = {
}
