from .access import (
    _Access,
    alohomora,
    always,
    bicorn_level_key,
    boomslang_level_key,
    chamber_of_secrets_key,
    diffindo,
    diffindo_challenge_key,
    duelling_key,
    flipendo,
    forbidden_forest_key,
    goyle_level_key,
    gryffindor_challenge_key,
    lumos,
    never,
    quidditch_key,
    rictusempra,
    rictusempra_challenge_key,
    running,
    _silver_cards,
    skurge,
    skurge_challenge_key,
    slytherin_common_room_key,
    spongify,
    spongify_challenge_key,
    whomping_willow_key,
)

START_REGION: str = "Menu"

REGION_NAMES: list[str] = [
    "BeanBonusRoom",
    "BicornLevel",
    "BoomslangLevel",
    "CastleExterior",
    "ChamberOfSecrets",
    "DiffindoChallenge",
    "DuellingClub",
    "DumbledoreStudy",
    "EntryHall",
    "ForbiddenForest",
    "GoldCardRoom",
    "GoyleLevel",
    "GrandStaircase",
    "GryffindorChallenge",
    "Menu",
    "Quidditch",
    "RictusempraChallenge",
    "SkurgeChallenge",
    "SlytherinCommon",
    "SpongifyChallenge",
    "WhompingWillow",
]

REGION_ENTRY_RULES_VANILLA: dict[str, _Access] = {
    # Vanilla enters the bean room by completing the Rictusempra challenge, so the
    # gate is that completion's reachability. RictusempraChallenge entry (lumos &
    # flipendo & rictusempra) already subsumes the Complete location's own
    # flipendo & rictusempra.
    "BeanBonusRoom": lumos & flipendo & rictusempra,
    "BicornLevel": lumos & flipendo & alohomora & rictusempra & skurge & bicorn_level_key,
    "BoomslangLevel": lumos
    & flipendo
    & alohomora
    & rictusempra
    & skurge
    & diffindo
    & bicorn_level_key
    & boomslang_level_key,
    "CastleExterior": lumos & flipendo,
    "ChamberOfSecrets": lumos
    & flipendo
    & alohomora
    & rictusempra
    & skurge
    & diffindo
    & spongify
    & bicorn_level_key
    & boomslang_level_key
    & goyle_level_key
    & slytherin_common_room_key
    & forbidden_forest_key
    & chamber_of_secrets_key,
    "DiffindoChallenge": lumos & flipendo & diffindo,
    "DuellingClub": lumos & flipendo & alohomora & rictusempra & skurge & bicorn_level_key & duelling_key,
    "DumbledoreStudy": lumos
    & flipendo
    & alohomora
    & rictusempra
    & skurge
    & diffindo
    & bicorn_level_key
    & boomslang_level_key,
    "EntryHall": lumos & flipendo,
    "ForbiddenForest": lumos
    & flipendo
    & alohomora
    & rictusempra
    & skurge
    & diffindo
    & spongify
    & bicorn_level_key
    & boomslang_level_key
    & goyle_level_key
    & slytherin_common_room_key
    & forbidden_forest_key,
    "GoldCardRoom": lumos & flipendo & _silver_cards(40),
    "GoyleLevel": lumos
    & flipendo
    & alohomora
    & rictusempra
    & skurge
    & diffindo
    & bicorn_level_key
    & boomslang_level_key
    & goyle_level_key,
    "GrandStaircase": lumos & flipendo,
    "GryffindorChallenge": never,
    "Quidditch": lumos & flipendo & rictusempra & quidditch_key,
    "RictusempraChallenge": lumos & flipendo & rictusempra,
    "SkurgeChallenge": lumos & flipendo & rictusempra & skurge,
    "SlytherinCommon": lumos
    & flipendo
    & alohomora
    & rictusempra
    & skurge
    & diffindo
    & bicorn_level_key
    & boomslang_level_key
    & goyle_level_key
    & slytherin_common_room_key,
    "SpongifyChallenge": lumos
    & flipendo
    & alohomora
    & rictusempra
    & skurge
    & diffindo
    & spongify
    & bicorn_level_key
    & boomslang_level_key
    & goyle_level_key
    & slytherin_common_room_key,
    "WhompingWillow": always,
}

REGION_ENTRY_RULES_OPEN_CASTLE: dict[str, _Access] = {
    "BeanBonusRoom": always,
    "BicornLevel": bicorn_level_key & skurge,
    "BoomslangLevel": boomslang_level_key & diffindo,
    "CastleExterior": always,
    "ChamberOfSecrets": chamber_of_secrets_key & alohomora,
    "DiffindoChallenge": diffindo_challenge_key & diffindo,
    "DuellingClub": duelling_key,
    "DumbledoreStudy": alohomora,
    "EntryHall": always,
    "ForbiddenForest": forbidden_forest_key,
    "GoldCardRoom": _silver_cards(20),
    "GoyleLevel": goyle_level_key,
    "GrandStaircase": always,
    "GryffindorChallenge": gryffindor_challenge_key,
    "Quidditch": quidditch_key | running,
    "RictusempraChallenge": rictusempra_challenge_key,
    "SkurgeChallenge": skurge_challenge_key & skurge,
    "SlytherinCommon": slytherin_common_room_key,
    "SpongifyChallenge": spongify_challenge_key,
    "WhompingWillow": whomping_willow_key & spongify,
}
