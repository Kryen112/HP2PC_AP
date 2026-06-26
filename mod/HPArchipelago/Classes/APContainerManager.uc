// Containersanity: arm every catalogued bean container in a level with its AP
// token. Chests and cauldrons are modified in place (the baked marker is injected
// as the first eject item); GenericSpawner boxes are swapped for an
// APContainerSpawner_<Leaf>. A logic-only singleton (GetInstance), per-level
// (bGameRelevant=False) so the once-per-level guard resets with the fresh
// instance; the on/off flag is class-default and sticky. Reads the watcher's
// NonCardLocationChecked ledger cross-class to skip already-collected locations.
class APContainerManager extends Info;

// Mirror APCardWatcher's id constants (the injectors index its class-default
// NonCardLocationChecked ledger cross-class by apId - LOC_BASE).
const LOC_BASE = 5760000;
const NONCARD_LOC_WINDOW = 2048;

// Process-wide singleton pointer (class-default). Instance copy kept None for
// save-graph hygiene, mirroring APHUDToast / APBeanRoom.
var APContainerManager LatestInstance;

// containersanity flag from the apworld slot_data (CONTAINERSANITY IPC). Sticky
// class-default; resent every HELLO. The watcher gates ReplaceContainers on it.
var byte bContainersanity;

// Per-level (instance) one-shot guard: ReplaceContainers runs once per level, on
// the first tick after the flag is present. Resets with each fresh per-level
// singleton.
var byte bContainersReplacedThisLevel;

// Found-or-spawned singleton accessor. Lazily spawns one via the caller's context
// on first use of a level. Logic-only (no mesh) so runtime spawn is safe.
static function APContainerManager GetInstance(Actor ctx)
{
    if (default.LatestInstance != None && !default.LatestInstance.bDeleteMe)
        return default.LatestInstance;
    if (ctx == None) return None;
    return ctx.Spawn(class'APContainerManager');
}

event PreBeginPlay()
{
    Super.PreBeginPlay();
    // Only default.LatestInstance is the singleton pointer; Spawn seeds the
    // instance copy from the class default, so clear it.
    LatestInstance = None;
    default.LatestInstance = self;
}

// containersanity flag from the apworld slot_data (CONTAINERSANITY IPC). Sticky
// class-default; resent every HELLO. ReplaceContainers gates on it per level.
static function SetContainersanity(byte v)
{
    default.bContainersanity = v;
    Log("[Archipelago] APContainerManager.SetContainersanity: enabled=" $ string(default.bContainersanity));
}

// containersanity: arm every catalogued bean container in this level. Chests and
// cauldrons are modified IN PLACE (the baked AP marker is injected as the first
// item of the native actor's own eject queue) -- never destroyed -- so they
// survive hub SaveGame/restore exactly like the card system's chests, and a tall
// cauldron never floats from a respawn. GenericSpawner boxes are swapped for an
// APContainerSpawner_<Leaf> (they reload fresh in hubs, so a swap is safe and is
// the only way to hook their random eject). GetContainerLocationId returns 0 for
// non-location actors (card chests, decorative cauldrons), so those are skipped.
// Self-guards to once per level; the watcher calls it each tick while armed.
function ReplaceContainers()
{
    local chestbronze chest;
    local bronzecauldron caul;
    local GenericSpawner spawner;
    local string lvl;
    local int apId, n;

    if (bContainersReplacedThisLevel == 1) return;
    bContainersReplacedThisLevel = 1;

    lvl = Caps(string(Level.Outer.Name));

    foreach AllActors(class'chestbronze', chest)
    {
        apId = class'APLocationRegistry'.static.GetContainerLocationId(lvl, string(chest.Name));
        if (apId > 0)
        {
            InjectContainerMarkerChest(chest, apId);
            n++;
        }
    }
    foreach AllActors(class'bronzecauldron', caul)
    {
        apId = class'APLocationRegistry'.static.GetContainerLocationId(lvl, string(caul.Name));
        if (apId > 0)
        {
            InjectContainerMarkerCauldron(caul, apId);
            n++;
        }
    }
    foreach AllActors(class'GenericSpawner', spawner)
    {
        // Skip our own swapped subclasses so a re-run can't double-swap.
        if (Left(string(spawner.Class.Name), 19) == "APContainerSpawner_")
        {
            continue;
        }
        apId = class'APLocationRegistry'.static.GetContainerLocationId(lvl, string(spawner.Name));
        if (apId > 0)
        {
            SwapContainerSpawner(spawner, apId);
            n++;
        }
    }
    Log("[Archipelago] APContainerManager.ReplaceContainers: " $ lvl $ " - armed " $ n $ " container location(s)");
}

// Inject the per-location baked-id marker (APContainerMarker_<offset>) as the
// FIRST item of a chest's own EjectedObjects, IN PLACE on the native actor (no
// destroy/respawn). The chest's eject loop then spits it out first with bean
// velocity and the inter-bean delay. Roll the beans now (the chest's own random
// roll, incl. the live-health ChocolateFrog) then freeze bRandomBeans so the
// open-time re-roll can't clobber the marker slot. Skipped entirely when the
// location is already collected (no phantom drop on a level re-clear) or already
// injected (hub re-entry restores the modified chest -- do not double-inject).
function InjectContainerMarkerChest(chestbronze chest, int apId)
{
    local class<Actor> markerCls;
    local int i, maxN, slot;

    slot = apId - LOC_BASE;
    if (slot >= 0 && slot < NONCARD_LOC_WINDOW
        && class'APCardWatcher'.default.NonCardLocationChecked[slot] == 1)
    {
        return;  // already collected -> leave the chest 100% vanilla
    }
    for (i = 0; i < ArrayCount(chest.EjectedObjects); i++)
    {
        if (chest.EjectedObjects[i] != None
            && ClassIsChildOf(chest.EjectedObjects[i], class'APContainerMarker'))
        {
            return;  // already injected this level (incl. restored hub state)
        }
    }
    markerCls = class<Actor>(DynamicLoadObject(
        "HPArchipelago.APContainerMarker_" $ string(slot), class'Class'));
    if (markerCls == None)
    {
        return;
    }
    if (chest.bRandomBeans)
    {
        chest.SetupRandomBeans();
    }
    chest.bRandomBeans = False;
    maxN = ArrayCount(chest.EjectedObjects);
    if (chest.iNumberOfBeans < maxN)
    {
        for (i = chest.iNumberOfBeans; i > 0; i--)
        {
            chest.EjectedObjects[i] = chest.EjectedObjects[i - 1];
        }
        chest.iNumberOfBeans = chest.iNumberOfBeans + 1;
    }
    chest.EjectedObjects[0] = markerCls;
    Log("[Archipelago] APContainerManager.InjectContainerMarkerChest: " $ string(chest.Name)
        $ " (apId " $ apId $ ", beans " $ string(chest.iNumberOfBeans) $ ")");
}

// Cauldron variant: bronzecauldron has 3 eject slots and the singular bRandomBean
// flag. Same in-place injection as InjectContainerMarkerChest.
function InjectContainerMarkerCauldron(bronzecauldron caul, int apId)
{
    local class<Actor> markerCls;
    local int i, maxN, slot;

    slot = apId - LOC_BASE;
    if (slot >= 0 && slot < NONCARD_LOC_WINDOW
        && class'APCardWatcher'.default.NonCardLocationChecked[slot] == 1)
    {
        return;
    }
    for (i = 0; i < ArrayCount(caul.EjectedObjects); i++)
    {
        if (caul.EjectedObjects[i] != None
            && ClassIsChildOf(caul.EjectedObjects[i], class'APContainerMarker'))
        {
            return;
        }
    }
    markerCls = class<Actor>(DynamicLoadObject(
        "HPArchipelago.APContainerMarker_" $ string(slot), class'Class'));
    if (markerCls == None)
    {
        return;
    }
    if (caul.bRandomBean)
    {
        caul.SetupRandomBeans();
    }
    caul.bRandomBean = False;
    maxN = ArrayCount(caul.EjectedObjects);
    if (caul.iNumberOfBeans < maxN)
    {
        for (i = caul.iNumberOfBeans; i > 0; i--)
        {
            caul.EjectedObjects[i] = caul.EjectedObjects[i - 1];
        }
        caul.iNumberOfBeans = caul.iNumberOfBeans + 1;
    }
    caul.EjectedObjects[0] = markerCls;
    Log("[Archipelago] APContainerManager.InjectContainerMarkerCauldron: " $ string(caul.Name)
        $ " (apId " $ apId $ ", beans " $ string(caul.iNumberOfBeans) $ ")");
}

// Swap a GenericSpawner-family box for its APContainerSpawner_<Leaf> subclass,
// CLONING the placed instance's spawn config so the swap is behaviourally
// identical to the original. The eject count comes from per-instance Limits /
// GoodiesNumber, which the leaf class defaults do NOT carry, so reverting to
// class defaults would randomise it (and break exact-count boxes). The original
// is destroyed first so the replacement spawns in its place without encroaching,
// so its config is saved to locals beforehand. After copying GoodieToSpawn /
// GoodiesNumber / Lives, the engine's cached init (HowManyObjectsToSpawn,
// bSpawnExactNumbers) is re-derived exactly as GenericSpawner.PostBeginPlay does.
// CheckLocationId is stamped via APContainerStamp (the generated subclasses each
// declare it but share no base type to cast to here).
function SwapContainerSpawner(GenericSpawner old, int apId)
{
    local class<GenericSpawner> swapCls;
    local GenericSpawner nw;
    local Actor spawned;
    local Vector savedLoc, savedStartPos, savedStartVel;
    local Rotator savedRot;
    local name savedTag, savedEvent, savedEventName, savedStartBone;
    local int savedLives, savedLimMax, savedLimMin, i, howMany, slot;
    local bool savedPersist, exact;
    local class<Actor> savedGoodie[8];
    local int savedNum[8];
    local name savedClass;
    local ESpellType savedVuln;
    local Mesh savedMesh;
    local float savedDrawScale;
    local Vector savedPrePivot;
    local float savedGoodieDelay, savedBaseDelay, savedColRadius, savedColHeight;
    local bool bReplace;

    // Already collected -> leave the spawner 100% vanilla (no swap, no extra
    // eject slot), so a re-clear drops no phantom AP token.
    slot = apId - LOC_BASE;
    if (slot >= 0 && slot < NONCARD_LOC_WINDOW
        && class'APCardWatcher'.default.NonCardLocationChecked[slot] == 1)
    {
        return;
    }

    swapCls = class<GenericSpawner>(DynamicLoadObject(
        "HPArchipelago.APContainerSpawner_" $ string(old.Class.Name), class'Class'));
    if (swapCls == None)
    {
        return;
    }
    savedLoc = old.Location;
    savedRot = old.Rotation;
    savedTag = old.Tag;
    savedEvent = old.Event;
    savedEventName = old.EventName;
    savedLives = old.Lives;
    savedLimMax = old.Limits.Max;
    savedLimMin = old.Limits.Min;
    savedPersist = old.bMakeSpawnPersistent;
    savedStartPos = old.StartPos;
    savedStartVel = old.StartVel;
    savedStartBone = old.StartBone;
    savedClass = old.Class.Name;
    // Carry over the instance's open-spell. Without this the swap reverts to the
    // GenericSpawner class default (Flipendo) and PostBeginPlay forces it to None
    // (the leaf has no goodie defaults at Spawn), leaving the box unopenable.
    savedVuln = old.eVulnerableToSpellSaved;
    // Carry over the look too. The map actor overrides Mesh to a wooden chest at
    // DrawScale 2; without this the swap reverts to the GenericSpawner default
    // (skcigarboxMesh at DrawScale 1 = the tiny cigar box that broke this spot).
    savedMesh = old.Mesh;
    savedDrawScale = old.DrawScale;
    // PrePivot is the mesh's seating offset; without it the taller chest floats.
    savedPrePivot = old.PrePivot;
    // Collision: copy the instance's cylinder so the Alohomora target matches the
    // original chest, and so the PrePivot mesh-seating (below) uses the right height.
    savedColRadius = old.CollisionRadius;
    savedColHeight = old.CollisionHeight;
    // Eject timing: GoodieDelay/BaseDelay are 0 by class default, so the goodies
    // all spew in one frame instead of dribbling out like a bean chest.
    savedGoodieDelay = old.GoodieDelay;
    savedBaseDelay = old.BaseDelay;
    for (i = 0; i < 8; i++)
    {
        savedGoodie[i] = old.GoodieToSpawn[i];
        savedNum[i]    = old.GoodiesNumber[i];
    }
    old.Destroy();

    spawned = Spawn(swapCls, , savedTag, savedLoc, savedRot);
    nw = GenericSpawner(spawned);
    if (nw == None)
    {
        return;
    }
    // Replace leaves (single-content jars) have the AP token stand in for their
    // native goodie, so they skip the +1 eject-slot bump below.
    bReplace = class'APContainerStamp'.static.IsReplaceLeaf(nw);
    nw.Event = savedEvent;
    nw.EventName = savedEventName;
    nw.Lives = savedLives;
    // +1 buys one extra eject iteration on the first hit for the AP token; the
    // subclass's first SpawnObject undoes this so multi-life re-hits stay vanilla.
    // Replace leaves skip the bump: the token replaces the native goodie rather
    // than dropping alongside it, so the native eject count stays unchanged.
    nw.Limits.Max = savedLimMax;
    nw.Limits.Min = savedLimMin;
    if (!bReplace)
    {
        nw.Limits.Max += 1;
        nw.Limits.Min += 1;
    }
    nw.bMakeSpawnPersistent = savedPersist;
    nw.StartPos = savedStartPos;
    nw.StartVel = savedStartVel;
    nw.StartBone = savedStartBone;
    exact = False;
    for (i = 0; i < 8; i++)
    {
        nw.GoodieToSpawn[i]  = savedGoodie[i];
        nw.GoodiesNumber[i]  = savedNum[i];
        if (savedNum[i] != 0)
        {
            exact = True;
        }
    }
    // Exact-count boxes drive eject from GoodiesNumber, not Limits, so the +1
    // Limits bump above adds no extra eject -- the AP token would eat the first
    // goodie's slot. Bump the first non-empty count by 1 so the token rides the
    // extra iteration and every native goodie still drops. Replace leaves skip
    // this for the same reason they skip the Limits bump (token stands in).
    if (exact && !bReplace)
    {
        for (i = 0; i < 8; i++)
        {
            if (nw.GoodiesNumber[i] > 0) { nw.GoodiesNumber[i] += 1; break; }
        }
    }
    // Re-derive the engine's cached init (GenericSpawner.PostBeginPlay already
    // ran at Spawn with the leaf defaults; redo it now the real config is in).
    howMany = 0;
    for (i = 0; i < 8; i++)
    {
        if (savedGoodie[i] == None) break;
        howMany++;
    }
    if (savedLives <= 0) howMany = 0;
    nw.HowManyObjectsToSpawn = howMany;
    nw.bSpawnExactNumbers = exact;
    // Restore the open-spell preserved above (both fields: live + post-hit recovery).
    nw.eVulnerableToSpell = savedVuln;
    nw.eVulnerableToSpellSaved = savedVuln;
    // Restore the wooden-chest mesh/scale/pivot preserved above.
    nw.Mesh = savedMesh;
    nw.DrawScale = savedDrawScale;
    nw.PrePivot = savedPrePivot;
    // Base-origin meshes hang in the air: a Pawn rests with its origin
    // CollisionHeight above the floor, and these meshes draw from their base, so
    // they float by CollisionHeight. PrePivot is ADDED to the draw position (+Z
    // raises), so subtract CollisionHeight to seat the mesh on the floor. This
    // covers the base GenericSpawner wood chests (Entry Hall, Forbidden Forest)
    // and the jar/box leaves (plant pot, oil can, cigar box, jewel box, music box,
    // decanter). Bark/Mucus jars are short and sit at their saved transform, so
    // they need no adjustment.
    if (savedClass == 'GenericSpawner' || savedClass == 'PlantPotSpawn'
        || savedClass == 'OilCanSpawn' || savedClass == 'CigarBoxSpawn'
        || savedClass == 'JewelBoxSpawn' || savedClass == 'MusicBoxSpawn'
        || savedClass == 'DecanterSpawn')
    {
        nw.PrePivot.Z = savedPrePivot.Z - savedColHeight;
    }
    // The knight suit-of-armour mesh is taller than its collision cylinder, so at
    // its exact saved transform (bCollideWhenPlacing=False = no settle nudge) it
    // lands ~10u into the floor. Raise it by that empirical offset to seat it.
    else if (savedClass == 'Knightspawn')
    {
        nw.PrePivot.Z = savedPrePivot.Z + 10.0;
    }
    // Match the original's collision (Alohomora target) but pin it static -- a
    // fresh PHYS_Walking pawn drifts off the floor. Restore the eject timing so
    // goodies dribble out instead of spewing at once.
    nw.SetCollisionSize(savedColRadius, savedColHeight);
    nw.SetPhysics(PHYS_None);
    // Append leaves space the token + native goodies out so they dribble rather
    // than spew in one frame, so a zero native GoodieDelay gets a 0.5s floor.
    // Replace leaves eject a single token: keep the native timing (no floor) or
    // the jar lags ~0.5s before breaking, which feels unresponsive to the spell.
    nw.GoodieDelay = savedGoodieDelay;
    if (!bReplace && nw.GoodieDelay <= 0.0) { nw.GoodieDelay = 0.5; }
    nw.BaseDelay = savedBaseDelay;

    if (!class'APContainerStamp'.static.Stamp(nw, apId))
    {
        Log("[Archipelago] APContainerManager.SwapContainerSpawner: Stamp FAILED (unknown subclass) for " $ string(nw.Class.Name));
    }
    Log("[Archipelago] APContainerManager.SwapContainerSpawner: swapped " $ string(nw.Class.Name)
        $ " (apId " $ apId $ ", lives " $ string(savedLives) $ ")");
}

defaultproperties
{
    // Logic-only, no render/collision. bGameRelevant=False so each level
    // transition destroys this singleton, resetting bContainersReplacedThisLevel
    // on the next level's fresh instance. The on/off flag is class-default and
    // persists regardless.
    bHidden=True
    bGameRelevant=False
    bCollideActors=False
    bBlockActors=False
}
