"""HP2PC_AP — Harry Potter 2: Chamber of Secrets PC randomizer for Archipelago.

Items + locations come from data/*.yaml. The .py files in this directory
are auto-generated; treat data/*.yaml as the source of truth.

Generation models the Basilisk goal as the item/logic requirements needed to
reach endgame. Runtime completion comes from the game-side GOAL_COMPLETE signal
when credits start after the Basilisk sequence.
"""

from __future__ import annotations

import random as _random
from dataclasses import dataclass
from typing import Any

from BaseClasses import (CollectionState, Item, ItemClassification, Location,
                         LocationProgressType, Region)
from Options import (Choice, DeathLink, DefaultOnToggle, NamedRange,
                     OptionError, OptionGroup, OptionSet, PerGameCommonOptions,
                     Range, StartInventoryPool, Toggle)
from worlds.AutoWorld import WebWorld, World
from worlds.LauncherComponents import Component, Type, components
from worlds.LauncherComponents import launch as launch_component

from .items import BASE_ID as ITEM_BASE_ID
from .items import (FILLER_NAMES, ITEM_CLASSIFICATIONS, ITEM_GROUPS,
                    ITEM_NAME_TO_ID, TRAP_NAMES)
from .locations import BASE_ID as LOCATION_BASE_ID
from .locations import (CARD_GAME_ID_TO_LOCATION_NAME,
                        GOLD_CARD_ROOM_LOCATIONS, LOCATION_GROUPS,
                        LOCATION_NAME_TO_ID, LOCATION_REGIONS,
                        MISSABLE_SECRET_DEPS_VANILLA, MISSABLE_SECRETS)
from .regions import (REGION_ENTRY_RULES_OPEN_CASTLE, REGION_ENTRY_RULES_VANILLA,
                      REGION_NAMES, START_REGION)
from .rules import (GOAL_LOCATION_REQUIREMENTS_VANILLA, GOAL_RULES_VANILLA,
                    LOCATION_RULES_OPEN_CASTLE, LOCATION_RULES_VANILLA)

PROGRESSION_ITEM_NAMES: list[str] = [
    name for name, c in ITEM_CLASSIFICATIONS.items() if c == ItemClassification.progression
]

DEFAULT_GOAL = "basilisk"
SPELL_ITEM_NAMES: list[str] = sorted(ITEM_GROUPS.get("Spells", []))
# All 101 wizard-card item names. In open castle these are upgraded to
# progression_skip_balancing at create_item time so AP guarantees them
# reachable (a card-count Great Hall goal needs that); vanilla keeps the
# generated classification so vanilla seeds are unchanged.
CARD_ITEM_NAMES: frozenset[str] = frozenset(
    ITEM_GROUPS.get("Cards (Bronze)", [])
    + ITEM_GROUPS.get("Cards (Silver)", [])
    + ITEM_GROUPS.get("Cards (Gold)", [])
)
# Level-entry keys. In open castle, all 14 are AP items gating every level
# transition. In vanilla with vanilla_gate_levels on, the 7 in
# VANILLA_BLOCKED_KEY_NAMES are also AP items (the mod spawns a bookcase
# blocking each region until the key arrives) and the other 7 are
# precollected so their logic.yaml terms pass trivially without entering the
# pool. With vanilla_gate_levels off, all 14 are precollected and no bookcase
# spawns.
OPEN_CASTLE_KEY_NAMES: set[str] = set(ITEM_GROUPS.get("Open Castle Keys", []))
# Keys that gate a region behind a bookcase in vanilla when
# vanilla_gate_levels is on (linear story order).
# Bicorn/Boomslang/Goyle/Slytherin/Forbidden Forest are a cumulative chain (a
# region needs its own key plus every earlier level key); Duelling and
# Quidditch are standalone (own key only, gating just their duels / matches).
# The other 7 keys are always vanilla-precollected.
VANILLA_BLOCKED_KEY_NAMES: set[str] = {
    "Bicorn Level Key", "Boomslang Level Key", "Goyle Level Key",
    "Slytherin Common Room Key", "Forbidden Forest Key",
    "Duelling Key", "Quidditch Key",
}

# Regions that exist only in an open castle seed. Their level is never entered
# in a vanilla playthrough, so every location in them must not be created as a
# vanilla check at all — not merely made unreachable. _location_enabled
# enforces this (the mirror image of the Classrooms+open-castle exclusion).
# The region name itself still appears in BOTH logic files because gen_apworld
# requires the vanilla and open-castle region SETS to be identical; in vanilla
# the region is inert (entry false, zero locations attached).
OPEN_CASTLE_ONLY_REGIONS: set[str] = {"GryffindorChallenge"}


def launch_client(*args: str) -> None:
    # Lazy-import Client so apworld registration (this module's import side
    # effects) doesn't pull in CommonClient / colorama / kivy until the user
    # actually clicks the launcher button.
    from .Client import launch
    launch_component(launch, name="HP2 PC Client", args=args)


components.append(Component(
    "HP2 PC Client",
    func=launch_client,
    component_type=Type.CLIENT,
    game_name="Harry Potter 2 PC",
    supports_uri=True,
    description="Connect to a multiworld and bridge to the HP2 PC mod.",
))


class HP2Item(Item):
    game = "Harry Potter 2 PC"


class HP2Location(Location):
    game = "Harry Potter 2 PC"


class GameMode(Choice):
    """Which install layout this seed targets.

    `vanilla` (default): retail HP2 + M212 patch — the normal story flow.
    Whether the 7 region keys gate their regions behind bookcases or are
    precollected is governed by `vanilla_gate_levels`; the other 7 keys are
    always precollected here.

    `open_castle`: the HP2 Bingo community pack's distribution maps (every
    door unlocked from spawn). The 14 open castle keys are AP items gating
    each level transition.

    Which spells Harry starts with is governed by `starting_spells`;
    `vanilla_gate_levels` governs the 7 region keys. Neither is set by this
    option.
    """
    display_name = "Game Mode"
    option_vanilla = 0
    option_open_castle = 1
    default = 0


class VanillaGateLevels(DefaultOnToggle):
    """Vanilla only. If true, the 7 region keys (Bicorn, Boomslang, Goyle,
    Slytherin Common Room, Forbidden Forest, Duelling, Quidditch) are AP items:
    the mod spawns a bookcase blocking each region until its key arrives, and
    the 5 level regions form a cumulative chain (each needs its own key plus
    every earlier level key, matching vanilla's linear story order).

    If false, those 7 keys are precollected instead, so the regions open
    immediately and no bookcases spawn — the classic precollect-everything
    vanilla flow. Has no effect in open castle mode (all 14 keys are always AP
    items there).
    """
    display_name = "Vanilla gate levels"


class StartingSpells(OptionSet):
    """Spells Harry starts with. Any spell not listed is an AP item instead.

    `vanilla` game_mode physically requires Lumos and Flipendo to finish the
    Whomping Willow level. If left blank for `vanilla`, Lumos and Flipendo are
    granted anyways.

    Valid spells: Alohomora, Flipendo, Lumos, Rictusempra, Skurge, Diffindo & Spongify.
    """
    display_name = "Starting Spells"
    valid_keys = frozenset(SPELL_ITEM_NAMES)
    default = frozenset({"Flipendo", "Lumos", "Alohomora"})


class EnableWizardCards(DefaultOnToggle):
    """If true, the 101 wizard cards become AP locations.
    """
    display_name = "Enable Wizard Cards"


class EnableSecrets(DefaultOnToggle):
    """If true, the 109 Secrets become AP locations (both game modes).

    The `allow_secrets_progression` missable-vs-replayable split is
    vanilla-only; in open castle every level is infinitely replayable, so all
    enabled secrets follow normal region-entry logic.
    """
    display_name = "Enable Secrets"


class AllowSecretsProgression(Toggle):
    """Vanilla-only (ignored in open castle). If true (and `enable_secrets` is
    true), missable secrets in un-replayable vanilla levels (Willow, Bicorn,
    Boomslang, Goyle, Slytherin Common, Forest, Chamber) are allowed to hold
    progression items.

    If false, missable secrets are filler-only, which is safer because the
    player can't soft-lock by missing a story-replay secret. Replayable
    secrets (Hogwarts, Castle Exterior, the 4 spell challenges) always allow
    progression regardless of this setting; this flag only gates the
    un-replayable subset.

    Open castle makes every level infinitely replayable, so nothing is
    missable there and this option has no effect.
    """
    display_name = "Allow Secrets progression"


class EnableChallengeStars(DefaultOnToggle):
    """If true, the 44 Challenge Stars across the 4 spell-challenges
    (Rictusempra, Skurge, Diffindo, Spongify) become AP locations.
    """
    display_name = "Enable Challenge Stars"


class EnableDuelling(Toggle):
    """If true, each of the 10 duels at the Duelling Club become a location.
    """
    display_name = "Enable Duelling"


class EnableQuidditchMatches(Toggle):
    """If true, each of the 6 Quidditch matches becomes a location.
    """
    display_name = "Enable Quidditch matches"


class EnableSpellChallengeTimes(Toggle):
    """If true, beating the replay par time ("Mastered") on each of the 4
    spell challenges (Rictusempra, Skurge, Diffindo, Spongify) becomes a
    location.
    """
    display_name = "Enable Spell Challenge times"


class EnableQuidditchUpgrades(Toggle):
    """If true, the Nimbus 2001 from Fred and the Quidditch Armour from George
    become locations.
    """
    display_name = "Enable Quidditch upgrades"


# --- OPEN CASTLE section: the Great Hall key. The 5 clauses below are AND'd;
# a clause set to 0 / off drops out. Open castle only (ignored in vanilla). If
# a yaml resolves all five to 0/off, _open_castle_goal_config falls back to
# "all 7 spells" so there is always a gate. NamedRange gives named anchors
# plus a free integer, and supports yaml `random` / `random-low` / `random-high`.
class OpenCastleGoalCards(NamedRange):
    """Open castle only. Wizard cards needed to open the Great Hall. 0
    disables this clause. Counts cards Harry actually owns (incl. AP-granted)."""
    display_name = "Open castle goal: cards"
    range_start = 0
    range_end = 101
    default = 50
    special_range_names = {"none": 0, "few": 25, "half": 50, "most": 80, "all": 101}


class OpenCastleGoalSpells(NamedRange):
    """Open castle only. Spells needed to open the Great Hall. 0 disables
    this clause. (If every open castle goal clause is 0/off, this is forced
    to 7.)"""
    display_name = "Open castle goal: spells"
    range_start = 0
    range_end = 7
    default = 7
    special_range_names = {"none": 0, "all": 7}


class OpenCastleGoalLevels(NamedRange):
    """Open castle only. Level objectives finished to open the Great Hall. 0
    disables. 12 objectives, fixed: 3 key-item levels + 2 bosses + 2 story
    levels + 5 challenges."""
    display_name = "Open castle goal: level objectives"
    range_start = 0
    range_end = 12
    default = 12
    special_range_names = {"none": 0, "all": 12}


class OpenCastleGoalDuels(Toggle):
    """Open castle only. If true, all 10 Duelling Club duels must be won to
    open the Great Hall."""
    display_name = "Open castle goal: all duels"


class OpenCastleGoalQuidditch(Toggle):
    """Open castle only. If true, all 6 Quidditch matches must be won to open
    the Great Hall."""
    display_name = "Open castle goal: all Quidditch matches"


class RingLink(Toggle):
    """If true, organic changes to your Bertie Bott's bean total — in-game
    pickups and vendor spending — are mirrored to every other RingLink slot
    in the room, and their organic bean changes are applied to yours
    (clamped at zero). AP-granted bean filler and the Bean Thief trap are
    not mirrored. Interoperable with Sonic-style RingLink games. Core
    Archipelago ships a DeathLink option but no RingLink class (it is a
    convention), so this toggle is defined here."""
    display_name = "Ring Link"


class EnableTraps(Toggle):
    """If true, trap items (Bean Thief, Goyle Transformation, Forgetfulness)
    enter the seed, replacing a fraction of the filler set by `trap_fill_percent`."""
    display_name = "Enable Traps"


class TrapFillPercent(Range):
    """Percentage of filler items replaced with traps when `enable_traps` is on.
    Does nothing when `enable_traps` is off."""
    display_name = "Trap fill percent"
    range_start = 5
    range_end = 50
    default = 5


class Tradersanity(Choice):
    """Every non-Weasley card vendor and ingredient vendor sells one AP
    location check on its first sale, then permanently reverts to selling its
    normal card/ingredient. Fred & George (Nimbus 2001 / Quidditch Armour) are
    untouched. `off` (default) leaves all vendors vanilla and emits no
    Tradersanity locations. The three on settings differ only in what the
    AP-check sale costs: `price_vanilla` keeps the vendor's normal asking
    price, `price_random` randomises it within a band, `price_low` clamps it
    to a cheap fixed price."""
    display_name = "Tradersanity"
    option_off = 0
    option_price_vanilla = 1
    option_price_random = 2
    option_price_low = 3
    default = 0


@dataclass
class HP2Options(PerGameCommonOptions):
    # PerGameCommonOptions includes start_inventory (just-add) but NOT
    # StartInventoryPool (add-and-remove-from-pool). Keep it available for
    # playtest YAMLs; v1's three starter spells are precollected by the world.
    start_inventory_from_pool: StartInventoryPool
    game_mode: GameMode
    starting_spells: StartingSpells
    # Per-category check toggles. Each gates both the matching locations and
    # any paired items (currently: wizard cards, vendor equipment) — generator
    # emits both sides into the stable id space, HP2World filters at build
    # time. Spells + classrooms have no toggle: a spell-randomized run is the
    # core experience, so spells are always in the pool and classrooms are
    # always seed locations. With every toggle false the seed has only the 4
    # classrooms and 4 non-starter spells.
    enable_wizard_cards: EnableWizardCards
    enable_secrets: EnableSecrets
    allow_secrets_progression: AllowSecretsProgression
    enable_challenge_stars: EnableChallengeStars
    enable_quidditch_upgrades: EnableQuidditchUpgrades
    enable_duelling: EnableDuelling
    enable_quidditch_matches: EnableQuidditchMatches
    enable_spell_challenge_times: EnableSpellChallengeTimes
    ring_link: RingLink
    # Built-in AP Bounce-channel option (Toggle, default off). Pure runtime
    # channel — no fill/logic impact; the client reads it from slot_data on
    # Connected and (de)registers the DeathLink tag.
    death_link: DeathLink
    enable_traps: EnableTraps
    trap_fill_percent: TrapFillPercent
    tradersanity: Tradersanity
    # Rendered under their own OptionGroup headers (see
    # HP2WebWorld.option_groups), so the dataclass position here does not
    # affect template ordering.
    vanilla_gate_levels: VanillaGateLevels
    open_castle_goal_cards: OpenCastleGoalCards
    open_castle_goal_spells: OpenCastleGoalSpells
    open_castle_goal_levels: OpenCastleGoalLevels
    open_castle_goal_duels: OpenCastleGoalDuels
    open_castle_goal_quidditch: OpenCastleGoalQuidditch


class HP2WebWorld(WebWorld):
    """Web frontend metadata for archipelago.gg.

    The VANILLA / OPEN CASTLE option groups split the template: shared options
    stay in the auto "Game Options" block above; mode-specific options sit
    under their own banner. Padded names render as a wide ``#`` box header.
    """
    option_groups = [
        OptionGroup("           VANILLA           ", [
            VanillaGateLevels, AllowSecretsProgression,
        ]),
        OptionGroup("         OPEN CASTLE         ", [
            OpenCastleGoalCards, OpenCastleGoalSpells, OpenCastleGoalLevels,
            OpenCastleGoalDuels, OpenCastleGoalQuidditch,
        ]),
    ]


class HP2World(World):
    """Harry Potter and the Chamber of Secrets (PC) randomizer."""

    game = "Harry Potter 2 PC"
    web = HP2WebWorld()
    options_dataclass = HP2Options

    item_name_to_id = ITEM_NAME_TO_ID
    location_name_to_id = LOCATION_NAME_TO_ID
    item_name_groups = ITEM_GROUPS

    def generate_early(self) -> None:
        # Reject contradictory open castle yaml combos before fill, with a
        # message that names the fix (rather than silently degrading the goal).
        # Open castle only — vanilla ignores the open_castle_goal_* options entirely.
        if not self._is_open_castle():
            return
        if int(self.options.open_castle_goal_cards.value) > 0 and not self.options.enable_wizard_cards:
            raise OptionError(
                "Harry Potter 2 PC: open_castle_goal_cards > 0 requires "
                "enable_wizard_cards: true (the Great Hall cards clause would "
                "gate on cards the seed never places). Set open_castle_goal_cards: 0 "
                "or enable_wizard_cards: true."
            )

    def create_item(self, name: str) -> HP2Item:
        classification = ITEM_CLASSIFICATIONS[name]
        # Open castle's configurable Great Hall key can require a card count,
        # so AP must guarantee cards reachable — promote every card to
        # progression_skip_balancing (reachable-guaranteed, but excluded from
        # the heavy progression-balancing pass, like the silvers already are).
        # Open castle only: vanilla keeps the generated classification untouched.
        if name in CARD_ITEM_NAMES and self._is_open_castle():
            classification = ItemClassification.progression_skip_balancing
        return HP2Item(name, classification, self.item_name_to_id[name], self.player)

    def get_filler_item_name(self) -> str:
        # AP calls this when extra items are needed (e.g. start_inventory_from_pool
        # shrunk the pool). Default would pick any item name including cards,
        # producing card duplicates in the seed. Restrict to bean tiers.
        return self.multiworld.random.choice(FILLER_NAMES)

    # Location-group → option-attr map. Locations whose group is in this map
    # and whose corresponding option is False are filtered out of the seed.
    # The Classrooms group has an open-castle-mode special case in
    # _location_enabled: the spell-teaching cutscenes are tied to the vanilla
    # story flow that open castle's everything-unlocked layout skips, so those
    # 4 checks are unreachable in open castle and get dropped entirely (their
    # spells stay in the pool, placed elsewhere).
    _LOC_GROUP_TO_OPT: dict[str, str] = {
        "CardLocations":      "enable_wizard_cards",
        "Secrets":            "enable_secrets",
        "ChallengeStars":     "enable_challenge_stars",
        "QuidditchPurchases": "enable_quidditch_upgrades",
        "Duels":              "enable_duelling",
        "QuidditchMatches":   "enable_quidditch_matches",
        "SpellChallengeTimes": "enable_spell_challenge_times",
        # Tradersanity is a Choice, not a Toggle: _location_enabled treats any
        # non-off value (price_vanilla/random/low) as enabled via .value.
        "Tradersanity":       "tradersanity",
        # LevelCompletions has no opt: the 12 "X Level - Complete" spots are
        # always real checks. The open castle levels clause gates on their
        # reachability, so they must always exist; open_castle_goal_levels
        # (0..12) is the only knob over how many count toward the Great Hall.
    }
    # Item-group → option-attr map. Same shape, applies to paired items.
    # Spells / Key Items / Filler aren't listed — always in the pool. Traps
    # are also explicitly excluded from non_filler in create_items (they are
    # drawn only via the filler-delta partition), so this entry is the
    # belt-and-suspenders gate for any other _item_enabled consumer.
    _ITEM_GROUP_TO_OPT: dict[str, str] = {
        "Cards (Bronze)": "enable_wizard_cards",
        "Cards (Silver)": "enable_wizard_cards",
        "Cards (Gold)":   "enable_wizard_cards",
        "Equipment":      "enable_quidditch_upgrades",
        "Traps":          "enable_traps",
    }

    def _is_open_castle(self) -> bool:
        return self.options.game_mode.current_key == "open_castle"

    def _region_rules(self) -> dict:
        return REGION_ENTRY_RULES_OPEN_CASTLE if self._is_open_castle() else REGION_ENTRY_RULES_VANILLA

    def _location_rules(self) -> dict:
        return LOCATION_RULES_OPEN_CASTLE if self._is_open_castle() else LOCATION_RULES_VANILLA

    def _goal_rules(self) -> dict:
        # Vanilla-only: the open castle path sets completion_condition from
        # _open_castle_complete and returns before this is consulted, so there
        # is no open castle goal-rule table.
        return GOAL_RULES_VANILLA

    def _goal_location_requirements(self) -> dict:
        # Vanilla-only: the open castle path sets completion_condition from
        # _open_castle_complete and returns before this is consulted, so there
        # is no open castle goal-location table.
        return GOAL_LOCATION_REQUIREMENTS_VANILLA

    def _location_enabled(self, loc_name: str) -> bool:
        group = LOCATION_GROUPS.get(loc_name)
        if group == "Classrooms" and self._is_open_castle():
            return False
        # Open-castle-only regions (e.g. the Gryffindor challenge level): the
        # room is physically unreachable in vanilla, so its stars + completion
        # never exist as vanilla checks.
        if (not self._is_open_castle()
                and LOCATION_REGIONS.get(loc_name) in OPEN_CASTLE_ONLY_REGIONS):
            return False
        opt_attr = self._LOC_GROUP_TO_OPT.get(group or "")
        if opt_attr is None:
            return True
        # .value generalises the Toggle gates and makes a Choice (Tradersanity:
        # off=0) read as enabled for any non-off setting — bool(option) is
        # always truthy for a Choice instance, so it must be bool(value).
        return bool(getattr(self.options, opt_attr).value)

    def _item_enabled(self, item_name: str) -> bool:
        for group_name, opt_attr in self._ITEM_GROUP_TO_OPT.items():
            if item_name in ITEM_GROUPS.get(group_name, []):
                return bool(getattr(self.options, opt_attr))
        return True

    def create_regions(self) -> None:
        # Build every region declared in logic.yaml plus a "TBD" placeholder for
        # cards whose vanilla home is still uncatalogued. TBD is reachable from
        # Menu with no requirement so seed gen succeeds during playtest.
        all_region_names = list(REGION_NAMES)
        if "TBD" not in all_region_names:
            all_region_names.append("TBD")

        regions_by_name: dict[str, Region] = {}
        for region_name in all_region_names:
            r = Region(region_name, self.player, self.multiworld)
            regions_by_name[region_name] = r
            self.multiworld.regions.append(r)

        start = regions_by_name[START_REGION]
        for region_name, region in regions_by_name.items():
            if region_name == START_REGION:
                continue
            rule_fn = self._region_rules().get(region_name)
            if rule_fn is None:
                start.connect(region)
            else:
                start.connect(
                    region,
                    rule=lambda state, fn=rule_fn, player=self.player: fn(state, player),
                )

        for loc_name, region_name in LOCATION_REGIONS.items():
            if not self._location_enabled(loc_name):
                continue
            r = regions_by_name.get(region_name) or regions_by_name["TBD"]
            loc_id = LOCATION_NAME_TO_ID[loc_name]
            r.locations.append(HP2Location(self.player, loc_name, loc_id, r))

    def _starter_names(self) -> set[str]:
        # Precollected = the spells the player chose via `starting_spells`,
        # plus (vanilla only) all 14 open castle level-entry keys so logic.yaml
        # references to them auto-pass without entering the vanilla pool.
        # Open castle keeps the keys in the pool — the mod-side bookcases gate
        # each level transition until the matching key arrives via the AP grant.
        spells = set(self.options.starting_spells.value) & set(ITEM_GROUPS.get("Spells", []))
        if not self._is_open_castle():
            # Vanilla physically needs Lumos+Flipendo to clear Whomping Willow,
            # so force them precollected — a vanilla seed is always playable
            # regardless of what (if anything) starting_spells lists.
            spells |= {"Lumos", "Flipendo"}
        # Open castle: no keys precollected (all 14 are AP items). Vanilla with
        # vanilla_gate_levels on: precollect every key except the 7 that gate a
        # region behind a bookcase. Vanilla with it off: precollect all 14 so
        # every region opens immediately and no bookcase spawns.
        if self._is_open_castle():
            keys: set[str] = set()
        elif self.options.vanilla_gate_levels:
            keys = OPEN_CASTLE_KEY_NAMES - VANILLA_BLOCKED_KEY_NAMES
        else:
            keys = set(OPEN_CASTLE_KEY_NAMES)
        return spells | keys

    def _apply_missable_exclusions(self) -> None:
        # Vanilla-only. A missable secret lives in a one-way level: reachable
        # only while the player is passing through that level the single time.
        # It is safe to hold progression only if guaranteed reachable then —
        # i.e. allow_secrets_progression is on AND every item it depends on
        # (region entry AND its own requires) is precollected. Otherwise force
        # it filler-only so AP fill never gates the seed on a location the
        # level makes permanently unreachable.
        #
        # Open castle has no missable secrets: every level is infinitely
        # replayable, so nothing is ever truly missed. The whole system is a
        # vanilla concept; allow_secrets_progression is ignored in open castle
        # and normal region-entry logic governs these secrets.
        if self._is_open_castle():
            return
        precollected = self._starter_names()
        deps_map = MISSABLE_SECRET_DEPS_VANILLA
        allow_prog = bool(self.options.allow_secrets_progression)
        for name in MISSABLE_SECRETS:
            if not self._location_enabled(name):
                continue
            deps = set(deps_map.get(name, []))
            eligible = allow_prog and deps.issubset(precollected)
            if eligible:
                continue
            try:
                loc = self.multiworld.get_location(name, self.player)
            except KeyError:
                continue
            loc.progress_type = LocationProgressType.EXCLUDED

    def create_items(self) -> None:
        starters = self._starter_names()
        # Traps are excluded here alongside filler: neither counts as a
        # placeable non-filler item. Traps only ever enter the pool through
        # the filler-delta partition below (so item/location balance is
        # identical to a no-traps seed — they just displace some filler).
        non_filler = [
            name for name in ITEM_NAME_TO_ID
            if name not in FILLER_NAMES
            and name not in TRAP_NAMES
            and self._item_enabled(name)
        ]
        placeable_non_filler = [
            name for name in non_filler
            if name not in starters
        ]
        for name in non_filler:
            if name in starters:
                self.multiworld.push_precollected(self.create_item(name))
                continue
            self.multiworld.itempool.append(self.create_item(name))

        # delta uses the FILTERED location count, not the full id-space size,
        # so disabled categories don't bloat the pool with orphan filler.
        active_location_count = sum(
            1 for loc_name in LOCATION_NAME_TO_ID if self._location_enabled(loc_name)
        )
        delta = active_location_count - len(placeable_non_filler)
        if delta > 0:
            rng: _random.Random = self.multiworld.random if hasattr(self.multiworld, "random") else _random.Random()
            # Split the delta between traps and filler. Off / 0% / no
            # TRAP_NAMES ⇒ trap_n stays 0 and the whole delta is filler. The
            # partition keeps the pool size exactly `delta`, so item/location
            # balance is unaffected.
            trap_n = 0
            if bool(self.options.enable_traps) and TRAP_NAMES:
                pct = int(self.options.trap_fill_percent.value)
                trap_n = round(delta * pct / 100)
                trap_n = max(0, min(trap_n, delta))
            for _ in range(trap_n):
                self.multiworld.itempool.append(
                    self.create_item(rng.choice(TRAP_NAMES)))
            for _ in range(delta - trap_n):
                self.multiworld.itempool.append(
                    self.create_item(rng.choice(FILLER_NAMES)))

    def set_rules(self) -> None:
        from worlds.generic.Rules import add_item_rule, add_rule, set_rule

        self._apply_missable_exclusions()

        for loc_name, rule_fn in self._location_rules().items():
            try:
                loc = self.multiworld.get_location(loc_name, self.player)
            except KeyError:
                continue
            set_rule(loc, lambda state, fn=rule_fn, player=self.player: fn(state, player))

        # Placement constraint: gold-card locations cannot hold silver card
        # items. The gold card room opens only after collecting 40 silver
        # cards (=4 gold keys), so a silver buried in a gold-room location
        # creates a circular dependency where the player can't reach 40
        # silvers to unlock the room containing that silver. Enforced at
        # fill time (the rule grammar can't express a placement constraint).
        #
        # GOLD_CARD_ROOM_LOCATIONS is generated from the items.yaml gold tier
        # (cards_gold) — the same classification ITEM_GROUPS draws from — so
        # the excluded item set and the target location set cannot drift.
        silver_items = frozenset(ITEM_GROUPS.get("Cards (Silver)", []))
        for loc_name in GOLD_CARD_ROOM_LOCATIONS:
            try:
                loc = self.multiworld.get_location(loc_name, self.player)
            except KeyError:
                continue
            add_item_rule(loc, lambda item, silvers=silver_items: item.name not in silvers)
        # Gold Card Room *reachability* — the 40-silver gate itself — lives in
        # the GoldCardRoom region `entry` of logic_vanilla.yaml and
        # logic_open_castle.yaml as the `@all_silver_cards` macro, expanded by
        # gen_apworld.py from the same cards_silver classification.

        # Quidditch-purchase vendors (Nimbus 2001 / Quidditch Armour) cost a
        # lot of beans the player can't have collected early; gate them behind
        # owning at least 3 spells AND at least 3 open castle keys (any of
        # them — a count threshold the logic grammar can't express). ANDs onto
        # the existing rule. Only the QuidditchPurchases locations that exist
        # this seed are touched, so this is a no-op when the vendors are disabled.
        spell_names = ITEM_GROUPS.get("Spells", [])
        key_names = ITEM_GROUPS.get("Open Castle Keys", [])
        for loc_name, group in LOCATION_GROUPS.items():
            if group != "QuidditchPurchases":
                continue
            try:
                loc = self.multiworld.get_location(loc_name, self.player)
            except KeyError:
                continue
            add_rule(loc, lambda state, sp=spell_names, kp=key_names, player=self.player:
                sum(state.has(s, player) for s in sp) >= 3
                and sum(state.has(k, player) for k in kp) >= 3)

        # Open castle: AP's completion_condition mirrors the mod's GoalSatisfied().
        # cards/spells are has-counts (the same items the mod counts; cards
        # are promoted to progression_skip_balancing in create_item for open
        # castle so AP guarantees them reachable). The levels clause gates on
        # the reachability of the 11 "X Level - Complete" locations — completing
        # a level, not merely owning its key (owning 'Boomslang Level Key' is
        # not the same as finishing Boomslang, which also needs Diffindo).
        # duels/quidditch gate on the key that opens that bookcase. Same
        # _open_castle_goal_config the mod gets via fill_slot_data. The
        # GoldCardRoom key/spell placement exclusion below stops AP shoving a
        # goal-required key behind the 40-silver wall.
        if self._is_open_castle():
            keys_and_spells = frozenset(
                ITEM_GROUPS.get("Open Castle Keys", []) + ITEM_GROUPS.get("Spells", []))
            for loc_name in GOLD_CARD_ROOM_LOCATIONS:
                try:
                    loc = self.multiworld.get_location(loc_name, self.player)
                except KeyError:
                    continue
                add_item_rule(loc, lambda item, bad=keys_and_spells: item.name not in bad)

            cfg = self._open_castle_goal_config()
            need_cards = cfg["open_castle_goal_cards"]
            need_spells = cfg["open_castle_goal_spells"]
            need_levels = cfg["open_castle_goal_levels"]
            need_duels = cfg["open_castle_goal_duels"]
            need_quidditch = cfg["open_castle_goal_quidditch"]
            card_items = sorted(CARD_ITEM_NAMES)
            spell_items = ITEM_GROUPS.get("Spells", [])
            duel_key = "Duelling Key"
            quidditch_key = "Quidditch Key"
            # The 11 level-completion locations. Always created (no toggle),
            # so this set is stable; each one's reachability already folds in
            # its region entry plus any per-completion `requires:` on the
            # level_completions rows. Counting reachable completions is the
            # AP analogue of the mod's clause-3 detector.
            completion_locs = [n for n, g in LOCATION_GROUPS.items()
                               if g == "LevelCompletions"]

            def _open_castle_complete(state, p=self.player):
                if need_cards and sum(state.has(c, p) for c in card_items) < need_cards:
                    return False
                if need_spells and sum(state.has(s, p) for s in spell_items) < need_spells:
                    return False
                if need_levels and sum(
                        state.can_reach_location(loc, p)
                        for loc in completion_locs) < need_levels:
                    return False
                if need_duels and not state.has(duel_key, p):
                    return False
                if need_quidditch and not state.has(quidditch_key, p):
                    return False
                return True

            self.multiworld.completion_condition[self.player] = (
                lambda state, fn=_open_castle_complete: fn(state)
            )
            return

        goal_locations = self._goal_location_requirements().get(DEFAULT_GOAL, [])
        goal_rule = self._goal_rules().get(DEFAULT_GOAL)
        if not goal_locations and goal_rule is None:
            # Fallback: if logic.yaml has no goal defined, use M5 placeholder
            # (collect every progression item).
            progression = list(PROGRESSION_ITEM_NAMES)
            self.multiworld.completion_condition[self.player] = (
                lambda state: all(state.has(name, self.player) for name in progression)
            )
            return

        self.multiworld.completion_condition[self.player] = (
            lambda state, locs=goal_locations, fn=goal_rule, player=self.player:
                (fn(state, player) if fn is not None else True)
                and all(state.can_reach_location(loc, player) for loc in locs)
        )

    def _open_castle_goal_config(self) -> dict:
        # Single source of truth for the resolved open castle Great Hall key
        # config. fill_slot_data (the game's gate) and the set_rules open castle
        # gate both call this, so AP's solvability model and the game agree
        # exactly. Applies the never-zero-gate fallback: if a yaml resolves
        # every clause to 0/off there would be no gate at all, so fall back to
        # "all spells".
        o = self.options
        cards     = int(o.open_castle_goal_cards.value)
        spells    = int(o.open_castle_goal_spells.value)
        levels    = int(o.open_castle_goal_levels.value)
        duels     = int(bool(o.open_castle_goal_duels.value))
        quidditch = int(bool(o.open_castle_goal_quidditch.value))
        # The contradictory combo (open_castle_goal_cards>0 while
        # enable_wizard_cards is off) is rejected up front in generate_early
        # with a clear message, so it can't reach here — no silent zeroing needed.
        if not (cards or spells or levels or duels or quidditch):
            # SPELL_ITEM_NAMES is the 7 spells (defined at module top).
            spells = len(SPELL_ITEM_NAMES)
        return {
            "open_castle_goal_cards": cards,
            "open_castle_goal_spells": spells,
            "open_castle_goal_levels": levels,
            "open_castle_goal_duels": duels,
            "open_castle_goal_quidditch": quidditch,
            # Bit i set => level objective i (goal_plan.md §6.4) counts toward
            # open_castle_goal_levels. All 12 in scope. Field exists so a future
            # "which objectives" option needs no slot_data schema bump.
            "open_castle_level_mask": (1 << 12) - 1,
        }

    def fill_slot_data(self) -> dict:
        # The client only learns the RingLink / DeathLink toggles through
        # slot_data; it has no other view of the YAML. Must be in both paths.
        if not self._is_open_castle():
            return {
                "game_mode": "vanilla",
                "ring_link": bool(self.options.ring_link),
                "death_link": bool(self.options.death_link.value),
                "tradersanity": self.options.tradersanity.value,
            }
        sd = {
            "game_mode": "open_castle",
            "ring_link": bool(self.options.ring_link),
            "death_link": bool(self.options.death_link.value),
            "tradersanity": self.options.tradersanity.value,
        }
        sd.update(self._open_castle_goal_config())
        return sd
