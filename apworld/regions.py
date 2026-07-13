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
    keys_through_bicorn,
    keys_through_boomslang,
    keys_through_forbidden_forest,
    keys_through_goyle,
    keys_through_slytherin_common_room,
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
    "BicornLevel": lumos & flipendo & alohomora & rictusempra & skurge & keys_through_bicorn,
    "BoomslangLevel": lumos
    & flipendo
    & alohomora
    & rictusempra
    & skurge
    & diffindo
    & keys_through_boomslang,
    "CastleExterior": lumos & flipendo,
    "ChamberOfSecrets": lumos
    & flipendo
    & alohomora
    & rictusempra
    & skurge
    & diffindo
    & spongify
    & keys_through_forbidden_forest
    & chamber_of_secrets_key,
    "DiffindoChallenge": lumos & flipendo & diffindo,
    "DuellingClub": lumos & flipendo & alohomora & rictusempra & skurge & keys_through_bicorn & duelling_key,
    "DumbledoreStudy": lumos
    & flipendo
    & alohomora
    & rictusempra
    & skurge
    & diffindo
    & keys_through_boomslang,
    "EntryHall": lumos & flipendo,
    "ForbiddenForest": lumos
    & flipendo
    & alohomora
    & rictusempra
    & skurge
    & diffindo
    & spongify
    & keys_through_forbidden_forest,
    "GoldCardRoom": lumos & flipendo & _silver_cards(40),
    "GoyleLevel": lumos
    & flipendo
    & alohomora
    & rictusempra
    & skurge
    & diffindo
    & keys_through_goyle,
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
    & keys_through_slytherin_common_room,
    "SpongifyChallenge": lumos
    & flipendo
    & alohomora
    & rictusempra
    & skurge
    & diffindo
    & spongify
    & keys_through_slytherin_common_room,
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
    "ForbiddenForest": forbidden_forest_key | running,
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
