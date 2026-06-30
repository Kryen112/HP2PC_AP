// Open-castle Great Hall goal: the goal definition (the per-clause thresholds
// from the seed), clause-3 level-objective progress, the satisfied test, and the
// pause-menu progress readers. All class-default + static so it answers from any
// context (the IPC layer, the menu page, the watcher) with no live instance.
// Reads the grant ledger and live game state through APCardWatcher (the data it
// evaluates lives there); the watcher's Timer drives the unlock latch.
class APGoalTracker extends Object;

// Mirror APCardWatcher's ledger/id constants (M212 forbids a const array
// dimension, and these index its class-default ledgers cross-class).
const NUM_SPELLS = 7;
const NUM_BLOCKER_KEYS = 14;
const LOC_BASE = 5760000;
const NONCARD_LOC_WINDOW = 2048;

// Clause-3/4/5 objective counts and the AP id base each band starts at. The 13
// level completions are Whomping Willow, Bicorn, Boomslang, Goyle, Slytherin,
// Forbidden Forest, Chamber, Rictusempra, Skurge, Diffindo, Spongify, Gryffindor
// and Gold Card Room (idx 0-12).
const NUM_LEVEL_OBJECTIVES = 13;
const NUM_DUELS = 10;
const NUM_QUIDDITCH = 6;
const LEVEL_OBJECTIVE_LOC_BASE = 5760700;
const DUEL_LOC_BASE = 5760600;
const QUIDDITCH_LOC_BASE = 5760620;

// Open castle Great Hall key config. Delivered once per process by the client as
// "GOALCFG c,s,l,d,q,mask" (from apworld slot_data) and written by
// SetGoalConfigCSV; sticky across level transitions / save-load. GoalSatisfied
// reads them; the Great Hall bookcase clears when every enabled clause passes. A
// clause of 0 / off drops out of the AND (apworld already applied the all-off to
// all-spells fallback, so this is never a no-gate config in open castle).
var byte bGoalConfigured;
var int  GoalCards;
var int  GoalSpells;
var int  GoalLevels;
// Int (not byte) so the int return of NextCsvInt assigns without a coercion
// question; only ever 0/1.
var int  GoalDuels;
var int  GoalQuidditch;
var int  GoalLevelMask;
// Clause-3 objective bitset (up to 16 objectives), set by the level-objective
// detectors. Class-default sticky.
var byte GoalLevelDone[16];

// Ingest "cards,spells,levels,duels,quidditch,mask" from the client (apworld
// slot_data, sent every HELLO). Class-default + sticky; idempotent (re-parsing
// the same csv re-asserts the same values). The apworld already applied the
// all-off to all-spells fallback, so an open castle seed never delivers an
// all-zero (no-gate) config.
static function SetGoalConfigCSV(string csv)
{
    local string rest;

    rest = csv;
    default.GoalCards     = class'APCsvCodec'.static.NextCsvInt(rest);
    default.GoalSpells    = class'APCsvCodec'.static.NextCsvInt(rest);
    default.GoalLevels    = class'APCsvCodec'.static.NextCsvInt(rest);
    default.GoalDuels     = class'APCsvCodec'.static.NextCsvInt(rest);
    default.GoalQuidditch = class'APCsvCodec'.static.NextCsvInt(rest);
    default.GoalLevelMask = class'APCsvCodec'.static.NextCsvInt(rest);
    default.bGoalConfigured = 1;

    Log("[Archipelago] APGoalTracker.SetGoalConfigCSV: cards=" $ default.GoalCards
        $ " spells=" $ default.GoalSpells $ " levels=" $ default.GoalLevels
        $ " duels=" $ default.GoalDuels $ " quidditch=" $ default.GoalQuidditch
        $ " mask=" $ default.GoalLevelMask);
}

// Clause-3 objective index for a Caps'd map name. The 3 key-item ingredient
// levels (idx 0-2) are listed too: their StatusItem nCount path is unreliable in
// this build (orphaned StatusItemBitOGoyle; the Adv3DungeonQuest Bicorn prop has
// null class refs so PickupItem early-returns), so they are credited the robust
// Willow/Slytherin way: by leaving the (terminal, single-objective) level. -1 =
// not a clause-3 level.
static function int LevelObjectiveIndexFor(string CapsLevelName)
{
    if (CapsLevelName == "ADV4GREENHOUSE")   return 0;  // Boomslang Skin
    if (CapsLevelName == "ADV3DUNGEONQUEST") return 1;  // Bicorn Horn
    if (CapsLevelName == "ADV6GOYLE")        return 2;  // Bit O' Goyle
    if (CapsLevelName == "ADV9ARAGOG")       return 3;  // Forbidden Forest (Aragog)
    if (CapsLevelName == "ADV12CHAMBER")     return 4;  // Chamber (Basilisk)
    if (CapsLevelName == "ADV1WILLOW")       return 5;  // Whomping Willow
    if (CapsLevelName == "ADV7SLYTHCOMROOM") return 6;  // Slytherin Common Room
    if (CapsLevelName == "CH1RICTUSEMPRA")   return 7;
    if (CapsLevelName == "CH2SKURGE")        return 8;
    if (CapsLevelName == "CH3DIFFINDO")      return 9;
    if (CapsLevelName == "CH4SPONGIFY")      return 10;
    if (CapsLevelName == "CH7GRYFFINDOR")    return 11;  // Gryffindor challenge
    if (CapsLevelName == "CH6WIZARDCARD")    return 12;  // Gold Card Room (end trigger)
    return -1;
}

// Mark a clause-3 level objective complete. Dedupe is uniform with
// stars/duels/quidditch via the watcher's NonCardLocationChecked[apId-LOC_BASE],
// and the sticky GoalLevelDone[idx] bit (the clause-3 gate state GoalSatisfied
// reads) is also set. Fires the "X Level Complete" CHECK_LOCID 5760700+idx.
// Shared by Mechanisms A (key-item), B (boss), C (exit probe), D (end star).
static function NotifyLevelObjective(int idx)
{
    local APIPCActor ipc;
    local int locId, slot;

    if (idx < 0 || idx >= NUM_LEVEL_OBJECTIVES) return;
    locId = LEVEL_OBJECTIVE_LOC_BASE + idx;
    slot = locId - LOC_BASE;
    if (slot < 0 || slot >= NONCARD_LOC_WINDOW) return;
    if (class'APCardWatcher'.default.NonCardLocationChecked[slot] == 1) return;
    class'APCardWatcher'.default.NonCardLocationChecked[slot] = 1;
    default.GoalLevelDone[idx] = 1;
    Log("[Archipelago] APGoalTracker.NotifyLevelObjective: clause-3 objective idx="
        $ idx $ " complete - firing CHECK_LOCID " $ locId);
    ipc = class'APIPCActor'.static.GetInstance();
    if (ipc != None) ipc.SendCheckLocationId(locId);
}

// True when every ENABLED open castle Great Hall key clause passes. A clause with
// a 0 / off threshold drops out of the AND. Reads class-default thresholds vs the
// watcher's live state (ledger + StatusItem counts + duel/quidditch results via
// GetLatest). Clause 3 (GoalLevelDone[]) is populated by the level-objective
// detectors; until those land a non-zero GoalLevels simply keeps the gate shut,
// which is the safe direction.
static function bool GoalSatisfied()
{
    local int i, n;
    local APCardWatcher w;

    if (default.bGoalConfigured == 0) return False;  // never unlock un-configured

    w = class'APCardWatcher'.static.GetLatest();
    if (w == None) return False;

    // Clause 1: wizard cards Harry owns.
    if (default.GoalCards > 0)
    {
        if (w.siBronze == None || w.siSilver == None || w.siGold == None) return False;
        if (w.siBronze.nCount + w.siSilver.nCount + w.siGold.nCount < default.GoalCards)
            return False;
    }

    // Clause 2: spells received (APGrantedSpell is the sticky class-default
    // stamped on every AP spell grant; 0..NUM_SPELLS-1).
    if (default.GoalSpells > 0)
    {
        n = 0;
        for (i = 0; i < NUM_SPELLS; i++)
            if (class'APCardWatcher'.default.APGrantedSpell[i] == 1) n++;
        if (n < default.GoalSpells) return False;
    }

    // Clause 3: level objectives (the detectors set GoalLevelDone[];
    // GoalLevelMask selects which indices count).
    if (default.GoalLevels > 0)
    {
        n = 0;
        for (i = 0; i < NUM_LEVEL_OBJECTIVES; i++)
            if (((default.GoalLevelMask >> i) & 1) == 1 && default.GoalLevelDone[i] == 1)
                n++;
        if (n < default.GoalLevels) return False;
    }

    // Clause 4: all 10 duels (ScanDuelWins: ranks 1..DuelRankHarry-1 are won).
    if (default.GoalDuels == 1)
    {
        if (w.HarryRef == None || w.HarryRef.DuelRankHarry < 11) return False;
    }

    // Clause 5: all 6 Quidditch matches.
    if (default.GoalQuidditch == 1)
    {
        if (w.HarryRef == None) return False;
        for (i = 0; i < NUM_QUIDDITCH; i++)
            if (!w.HarryRef.quidGameResults[i].bWon) return False;
    }

    return True;
}

// Open castle goal-progress tallies, surfaced in the escape-menu widget
// (APFEInGamePage.DrawGoalProgressPanel). Mirror the client /progress command
// exactly so the two views always agree: cards = currently-owned bronze+silver+
// gold StatusItem counts (AP grants stamp these), spells/levels/duels/quidditch =
// the watcher's NonCardLocationChecked[] in their respective AP id bands. Cheap
// fixed-bound walks called once per menu open, no per-tick cost.

static function int GetOwnedCardCount()
{
    local APCardWatcher w;
    w = class'APCardWatcher'.static.GetLatest();
    if (w == None || w.siBronze == None || w.siSilver == None || w.siGold == None)
        return 0;
    return w.siBronze.nCount + w.siSilver.nCount + w.siGold.nCount;
}

static function int GetGrantedSpellCount()
{
    local int i, n;
    for (i = 0; i < NUM_SPELLS; i++)
        if (class'APCardWatcher'.default.APGrantedSpell[i] == 1) n++;
    return n;
}

// Per-index granted lookups for the pause-menu "Unlocked" icon panel. Read the
// same class-default ledgers as the count helpers, so they answer correctly from
// any context (the menu page is not a watcher instance).
static function bool IsSpellGranted(int i)
{
    if (i < 0 || i >= NUM_SPELLS) return false;
    return class'APCardWatcher'.default.APGrantedSpell[i] == 1;
}

static function bool IsBlockerKeyGranted(int i)
{
    if (i < 0 || i >= NUM_BLOCKER_KEYS) return false;
    return class'APCardWatcher'.default.APGrantedBlockerKey[i] == 1;
}

static function int GetCheckedLevelObjectiveCount()
{
    local int idx, slot, n;
    for (idx = 0; idx < NUM_LEVEL_OBJECTIVES; idx++)
    {
        if (((default.GoalLevelMask >> idx) & 1) == 0) continue;
        slot = (LEVEL_OBJECTIVE_LOC_BASE + idx) - LOC_BASE;
        if (slot < 0 || slot >= NONCARD_LOC_WINDOW) continue;
        if (class'APCardWatcher'.default.NonCardLocationChecked[slot] == 1) n++;
    }
    return n;
}

static function int GetCheckedDuelCount()
{
    local int idx, slot, n;
    for (idx = 0; idx < NUM_DUELS; idx++)
    {
        slot = (DUEL_LOC_BASE + idx) - LOC_BASE;
        if (slot < 0 || slot >= NONCARD_LOC_WINDOW) continue;
        if (class'APCardWatcher'.default.NonCardLocationChecked[slot] == 1) n++;
    }
    return n;
}

static function int GetCheckedQuidditchMatchCount()
{
    local int idx, slot, n;
    for (idx = 0; idx < NUM_QUIDDITCH; idx++)
    {
        slot = (QUIDDITCH_LOC_BASE + idx) - LOC_BASE;
        if (slot < 0 || slot >= NONCARD_LOC_WINDOW) continue;
        if (class'APCardWatcher'.default.NonCardLocationChecked[slot] == 1) n++;
    }
    return n;
}
