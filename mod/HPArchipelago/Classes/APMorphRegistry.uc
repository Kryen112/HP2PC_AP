// #3 marker-appearance subsystem: the per-AP-location appearance table and the
// morphable-marker registry. A logic-only singleton (GetInstance), per-level
// (bGameRelevant=False) so the registry of live marker Actor refs is INSTANCE
// state that dies with the level. The appearance table and the table-received
// flag are class-default, persisting for the process. Draw work is delegated to
// APAppearanceMath; markers register themselves here when their AP location id is
// known, and the sweep re-stamps every registered marker from the table.
class APMorphRegistry extends Info;

// AppearanceCode is indexed by the same window slot as NonCardLocationChecked
// (APLocationRegistry.SlotForApId). The window const stays for the table-clear
// loop and the array dimension (M212 array dims take an integer literal).
const NONCARD_LOC_WINDOW = 2048;
const MORPH_REGISTRY_SIZE = 256;

// Live per-level singleton is hosted on the per-level APGameInfo
// (APGameInfo.MorphRegistry), not a class-default pointer. See the MorphActor[]
// block below for why a class-default Actor ref crashes the level-teardown GC.

// Per-AP-location appearance code, indexed by the window slot exactly like
// NonCardLocationChecked[] (same dedupe-window math, same cross-level
// class-default persistence). Values: 0 = leave the marker's native vanilla look
// (also the async-safe default until the table arrives); 1..101 = HP2 card (value
// is the game card id); 1000+spellIdx = HP2 spell (wand-target gesture art on the
// card mesh); 2001..2011 = HP2 filler; 3001..3002 = HP2 equipment (Nimbus /
// Quidditch Armour); 3003 = HP2 open castle level/challenge key (the vanilla
// silver-key FX sprite); 9000 = foreign filler/useful (AP-logo plain); 9001 =
// foreign progression/trap (AP-logo arrow). Dimension literal MUST equal
// NONCARD_LOC_WINDOW (M212 array dims take an integer literal, not a const).
var int AppearanceCode[2048];
// Set once SetAppearanceCSV has ingested a table this process. The sweep and
// every marker self-apply early-return until then so a pre-table marker keeps
// its native look instead of going blank.
var byte bAppearanceReceived;
// Per-level (instance) one-shot guard so the Timer convergence sweep runs exactly
// once after the table is present in a given level; resets with each fresh
// per-level singleton.
var byte bAppearanceRestampedThisLevel;

// Morphable-marker registry (the #3 capability contract). A marker opts in by
// calling RegisterMorphMarker(self, apId) on the live per-level singleton when
// its AP location id is known (cards in PostBeginPlay; stars/vendors right after
// the watcher stamps their CheckLocationId). The sweep applies the table
// generically via APAppearanceMath.ApplyAppearanceTo(Actor, code), which only
// touches Actor-level draw fields, so NO marker class is named here and a future
// check marker opts in with the same one call.
//
// INSTANCE state, NOT class-default. A class-default array of Actor refs is a
// fatal M212 hazard: the class default object outlives every level, so on level
// cleanup ULevel::CleanupDestroyed walks the persistent ObjectProperty array and
// asserts (Obj->IsValid) on a freed marker from a torn-down level (the chest
// FancySpawn + pickup-Destroy pattern guarantees stale slots). Instance storage
// is necessary but not sufficient: the singleton pointer is ALSO kept off the
// class default (hosted on the per-level APGameInfo), because a class-default
// pointer to this instance lets the teardown GC reach it through the class object
// and fault on a freed slot. With both off the class default the instance is
// unreachable at travel and collected without serializing MorphActor[]; markers
// re-register into each level's fresh singleton, with the PostBeginPlay self-apply
// as the independent safety net since AppearanceCode[] IS class-default (only
// Object refs are unsafe there). MORPH_REGISTRY_SIZE is generous: a level holds at most
// a handful of card chests + the chest FancySpawn burst + a few stars + 2 vendors.
var Actor MorphActor[256];
var int   MorphApId[256];
// Parallel to MorphActor[]: the class name each reference had when it registered.
// The sweep compares it against the live reference's current class before
// painting. A morphable marker never changes class, so it always matches and
// paints normally. If a slot's reference has drifted to a different actor (a real
// world decoration, which never registers here), the class differs and the sweep
// skips it, so a non-marker is never overwritten with an AP item look. Dimension
// literal mirrors MorphActor[] (M212 array dims take an integer literal).
var name  MorphClassName[256];

// Found-or-spawned singleton accessor. Lazily spawns one via the caller's context
// on first use of a level (a marker registering, or the watcher's sweep). Logic-
// only (no mesh) so runtime spawn is safe.
static function APMorphRegistry GetInstance(Actor ctx)
{
    local APGameInfo gi;

    if (ctx == None) return None;
    gi = APGameInfo(ctx.Level.Game);
    if (gi == None) return None;
    if (gi.MorphRegistry != None && !gi.MorphRegistry.bDeleteMe)
        return gi.MorphRegistry;
    return ctx.Spawn(class'APMorphRegistry');
}

event PreBeginPlay()
{
    Super.PreBeginPlay();
    // Register on the per-level GameInfo host (not a class-default pointer) so the
    // dying instance is unreachable at the level-teardown GC.
    if (APGameInfo(Level.Game) != None)
        APGameInfo(Level.Game).MorphRegistry = self;
}

// Ingest the client's "apId:code,apId:code,..." appearance table. Full AP
// location ids on the wire (same convention as CHECK_LOCID); stored at the window
// slot (APLocationRegistry.SlotForApId). Clears the whole table first so a resend
// is authoritative (a location that dropped out of the table reverts to native).
// Class-default + sticky like the goal config; idempotent. Sets bAppearanceReceived
// so the sweep / self-apply paths come alive.
static function SetAppearanceCSV(string csv)
{
    local string rest;
    local int apId, code, slot, n;

    for (slot = 0; slot < NONCARD_LOC_WINDOW; slot++)
    {
        default.AppearanceCode[slot] = 0;
    }

    rest = csv;
    n = 0;
    while (rest != "")
    {
        apId = class'APCsvCodec'.static.NextCsvIntUpTo(rest, ":");
        code = class'APCsvCodec'.static.NextCsvIntUpTo(rest, ",");
        slot = class'APLocationRegistry'.static.SlotForApId(apId);
        if (slot >= 0)
        {
            default.AppearanceCode[slot] = code;
            n++;
        }
    }
    default.bAppearanceReceived = 1;
    Log("[Archipelago] APMorphRegistry.SetAppearanceCSV: ingested " $ n $ " appearance entry(ies)");
}

// Table lookup. 0 (native / unknown / out-of-window) is the safe default.
static function int AppearanceForApId(int apId)
{
    local int slot;
    slot = class'APLocationRegistry'.static.SlotForApId(apId);
    if (slot < 0) return 0;
    return default.AppearanceCode[slot];
}

// Capability-contract entry point. A morphable marker calls this on the live
// per-level singleton (GetInstance) with itself and its AP location id once that
// id is known. Instance (NOT static / NOT class-default): see the registry
// declaration; actor refs in class-default storage crash the engine at level
// cleanup. Idempotent per actor (updates in place). Registry-full just means this
// marker relies on its PostBeginPlay self-apply for this level; never fatal.
function RegisterMorphMarker(Actor a, int apId)
{
    local int i, free;

    if (a == None) return;

    free = -1;
    for (i = 0; i < MORPH_REGISTRY_SIZE; i++)
    {
        if (MorphActor[i] == a)
        {
            MorphApId[i] = apId;
            MorphClassName[i] = a.Class.Name;
            return;
        }
        if (free < 0 && (MorphActor[i] == None || MorphActor[i].bDeleteMe))
        {
            free = i;
        }
    }
    if (free < 0) return;
    MorphActor[free] = a;
    MorphApId[free]  = apId;
    MorphClassName[free] = a.Class.Name;
}

// Convergence sweep: re-stamp every registered marker from the live table.
// Authoritative for stars/vendors (id stamped after Spawn) and the catch-up
// after an async table arrival. Native-safe: early return until a table exists;
// empty/dead slots skipped. Instance; the registry is per-level instance state so
// there is no cross-level entry to filter.
function RestampMarkerAppearance()
{
    local int i, applied;
    local Actor a;

    if (default.bAppearanceReceived == 0) return;

    applied = 0;
    for (i = 0; i < MORPH_REGISTRY_SIZE; i++)
    {
        a = MorphActor[i];
        if (a == None) continue;
        if (a.bDeleteMe) continue;
        // Guard against a drifted reference: only paint when the live actor is
        // still the same class that registered here. A morphable marker keeps its
        // class for life, so this never blocks a real marker. A mismatch means the
        // slot now points at a different actor (a world decoration, never a
        // marker), so skip it and free the slot instead of overwriting its look.
        if (a.Class.Name != MorphClassName[i])
        {
            Log("[Archipelago] APMorphRegistry.RestampMarkerAppearance: slot " $ i
                $ " registered as " $ string(MorphClassName[i]) $ " now references "
                $ string(a.Class.Name) $ " (" $ string(a.Name) $ ") at " $ string(a.Location)
                $ " - NOT morphing, this is not an AP marker");
            MorphActor[i] = None;
            continue;
        }
        class'APAppearanceMath'.static.ApplyAppearanceTo(a, AppearanceForApId(MorphApId[i]));
        applied++;
    }
    if (applied > 0)
    {
        Log("[Archipelago] APMorphRegistry.RestampMarkerAppearance: applied appearance to "
            $ applied $ " marker(s) in " $ string(Level.Outer.Name));
    }
}

// Timer entry: run the convergence sweep at most once per level. The forced
// callers (the watcher's per-level bind, the IPC table arrival) call
// RestampMarkerAppearance directly; only the per-tick Timer needs this guard so
// it does not re-stamp every tick. The guard sets only once the table is present,
// so a level entered before the table still sweeps when it arrives.
function RestampOncePerLevel()
{
    if (bAppearanceRestampedThisLevel == 1) return;
    bAppearanceRestampedThisLevel = 1;
    RestampMarkerAppearance();
}

defaultproperties
{
    // Logic-only, no render/collision. bGameRelevant=False so each level
    // transition destroys this singleton: the instance MorphActor[] registry dies
    // with the level (never a class-default Actor array, which would crash the
    // teardown GC), and bAppearanceRestampedThisLevel resets. The live singleton is
    // reached via the per-level APGameInfo host, not a class-default pointer, so the
    // dying instance is unreachable at travel. The appearance table is class-default
    // and persists regardless.
    bHidden=True
    bGameRelevant=False
    bCollideActors=False
    bBlockActors=False
}
