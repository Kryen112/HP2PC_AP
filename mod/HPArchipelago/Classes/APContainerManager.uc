// Containersanity: arm every catalogued bean container in a level with its AP
// token. Chests and cauldrons are modified in place (the baked marker is injected
// as the first eject item); GenericSpawner boxes are swapped for an
// APContainerSpawner_<Leaf>. A logic-only singleton (GetInstance), per-level
// (bGameRelevant=False) so the once-per-level guard resets with the fresh
// instance; the on/off flag is class-default and sticky. Reads the watcher's
// NonCardLocationChecked ledger cross-class to skip already-collected locations.
class APContainerManager extends Info;

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
    // Only an instance in the caller's level counts (a save-loaded level stays resident after travel).
    if (default.LatestInstance != None && !default.LatestInstance.bDeleteMe
        && (ctx == None || default.LatestInstance.Level == ctx.Level))
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
    local HDecoration deco;
    local HPlants plnt;
    local string lvl;
    local int apId, n;

    if (bContainersReplacedThisLevel == 1) return;
    bContainersReplacedThisLevel = 1;

    // The recorded map name, so a level loaded from a save still resolves.
    lvl = class'APGameInfo'.static.CurrentMapName(self);

    foreach AllActors(class'chestbronze', chest)
    {
        apId = class'APLocationRegistry'.static.GetContainerLocationId(lvl, string(chest.Name));
        if (apId > 0)
        {
            InjectContainerMarkerChest(chest, apId);
            if (chest.bOpened && !IsLocationChecked(apId))
            {
                RearmOpenedChest(chest, apId);
            }
            n++;
        }
    }
    foreach AllActors(class'bronzecauldron', caul)
    {
        apId = class'APLocationRegistry'.static.GetContainerLocationId(lvl, string(caul.Name));
        if (apId > 0)
        {
            InjectContainerMarkerCauldron(caul, apId);
            if (caul.bOpened && !IsLocationChecked(apId))
            {
                RearmOpenedCauldron(caul, apId);
            }
            n++;
        }
    }
    foreach AllActors(class'GenericSpawner', spawner)
    {
        // A swap restored from the level's saved state: repair what the save
        // dropped and re-arm it, never swap it again.
        if (Left(string(spawner.Class.Name), 19) == "APContainerSpawner_")
        {
            RepairSwappedSpawner(spawner);
            continue;
        }
        apId = class'APLocationRegistry'.static.GetContainerLocationId(lvl, string(spawner.Name));
        if (apId > 0)
        {
            SwapContainerSpawner(spawner, apId);
            n++;
        }
    }
    // SpawnThingy decorations: the plant dragons and the Whomping Willow dragon eject
    // their beans from co-located SpawnThingy actors fired by a spellTrigger, not from a
    // GenericSpawner. HDecoration covers the Willow dragon statue; HPlants covers the
    // plant dragons. GetSpawnThingyDecorationId returns 0 for every other prop in these
    // trees, so only the catalogued ones arm.
    foreach AllActors(class'HDecoration', deco)
    {
        apId = class'APLocationRegistry'.static.GetSpawnThingyDecorationId(lvl, string(deco.Name));
        if (apId > 0)
        {
            ArmSpawnThingyDecoration(deco, apId);
            n++;
        }
    }
    foreach AllActors(class'HPlants', plnt)
    {
        apId = class'APLocationRegistry'.static.GetSpawnThingyDecorationId(lvl, string(plnt.Name));
        if (apId > 0)
        {
            ArmSpawnThingyDecoration(plnt, apId);
            n++;
        }
    }
    EnsureSpawnerTokens(lvl);
    Log("[Archipelago] APContainerManager.ReplaceContainers: " $ lvl $ " - armed " $ n $ " container location(s)");
}

static function bool IsLocationChecked(int apId)
{
    local int slot;

    slot = class'APLocationRegistry'.static.SlotForApId(apId);
    return slot < 0 || class'APCardWatcher'.static.IsNonCardChecked(slot);
}

// Destroy every uncollected token of one location still lying in the level.
function RemoveTokens(int apId)
{
    local APContainerMarker token;

    foreach AllActors(class'APContainerMarker', token)
    {
        if (token.CheckLocationId == apId)
        {
            token.Destroy();
        }
    }
}

// An opened chest whose token was never collected opens again. A token left
// lying from the earlier opening is cleared first, so the fresh one is the
// only copy and never sits out of reach.
function RearmOpenedChest(chestbronze chest, int apId)
{
    RemoveTokens(apId);
    chest.bOpened = False;
    chest.bProjTarget = class'chestbronze'.default.bProjTarget;
    chest.eVulnerableToSpell = class'chestbronze'.default.eVulnerableToSpell;
    chest.GotoState('waitforspell');
    Log("[Archipelago] APContainerManager.RearmOpenedChest: " $ string(chest.Name) $ " (apId " $ apId $ ") opens again");
}

// Cauldron variant of RearmOpenedChest. Cauldrons open with Flipendo.
function RearmOpenedCauldron(bronzecauldron caul, int apId)
{
    RemoveTokens(apId);
    caul.bOpened = False;
    caul.bProjTarget = class'bronzecauldron'.default.bProjTarget;
    caul.eVulnerableToSpell = class'bronzecauldron'.default.eVulnerableToSpell;
    caul.GotoState('waitforspell');
    Log("[Archipelago] APContainerManager.RearmOpenedCauldron: " $ string(caul.Name) $ " (apId " $ apId $ ") opens again");
}

// Object references a swapped spawner carries from its map placement, where the
// placement differs from the leaf class default. The level's saved state keeps no
// object references, so a restored swap falls back to the class default: a cigar
// box with nothing to eject, which the stock PostBeginPlay then makes unopenable.
// A plain GenericSpawner has no default goodies, so an empty first slot is what
// marks a restored swap. A fresh swap already carries the map's references.
function RestoreSpawnerObjects(GenericSpawner s, int apId)
{
    local Mesh chestMesh;

    if (apId == 5761117 && s.GoodieToSpawn[0] == None)
    {
        // Forbidden Forest - Chest 3: a wooden chest with a gnome inside.
        chestMesh = class'APAppearanceMath'.static.LoadMesh("HPModels.skwoodchestMesh");
        if (chestMesh != None) s.Mesh = chestMesh;
        s.GoodieToSpawn[0] = class'GNOME';
    }
    else if (apId == 5761126 && s.GoodieToSpawn[0] == None)
    {
        // Bean Bonus Room - Gargoyle: a hidden spawner with no mesh.
        s.Mesh = None;
        s.GoodieToSpawn[0] = class'Jellybean';
        s.GoodieToSpawn[1] = class'Jellybean';
        s.GoodieToSpawn[2] = class'Jellybean';
    }
    else if (apId == 5761257 && s.GoodieToSpawn[0] == None)
    {
        // Entry Hall - Chest 6: a wooden chest of potion ingredients.
        chestMesh = class'APAppearanceMath'.static.LoadMesh("HPModels.skwoodchestMesh");
        if (chestMesh != None) s.Mesh = chestMesh;
        s.GoodieToSpawn[0] = class'FlobberwormMucus_BAfalse';
        s.GoodieToSpawn[1] = class'WiggentreeBark_BAfalse';
    }
    else if (apId == 5761302)
    {
        // Grand Staircase - Dragon Skeleton: spiders.
        s.GoodieToSpawn[0] = class'SpiderSmall';
    }
}

// A swapped spawner rebuilt from the level's saved state. Put back the object
// references the save dropped, re-derive the cached eject setup the way
// GenericSpawner.PostBeginPlay does, and re-arm it when its token was ejected but
// never collected.
function RepairSwappedSpawner(GenericSpawner s)
{
    local int apId, i, howMany;
    local bool exact, bRearmed;

    apId = class'APContainerStamp'.static.ApIdOf(s);
    if (apId <= 0) return;
    RestoreSpawnerObjects(s, apId);

    if (!IsLocationChecked(apId) && class'APContainerStamp'.static.TokenEjected(s))
    {
        RemoveTokens(apId);
        class'APContainerStamp'.static.SetTokenEjected(s, False);
        // An append leaf's first SpawnObject took one off Limits for the token.
        // Give it back. A replace leaf never touches Limits.
        if (!class'APContainerStamp'.static.IsReplaceLeaf(s))
        {
            s.Limits.Min += 1;
            s.Limits.Max += 1;
        }
        if (s.Lives <= 0)
        {
            s.Lives = 1;
        }
        bRearmed = True;
    }

    howMany = 0;
    for (i = 0; i < ArrayCount(s.GoodieToSpawn); i++)
    {
        if (s.GoodieToSpawn[i] == None) break;
        howMany++;
    }
    if (s.Lives <= 0) howMany = 0;
    s.HowManyObjectsToSpawn = howMany;
    exact = False;
    for (i = 0; i < ArrayCount(s.GoodiesNumber); i++)
    {
        if (s.GoodiesNumber[i] != 0) exact = True;
    }
    s.bSpawnExactNumbers = exact;
    if (s.Lives > 0)
    {
        s.eVulnerableToSpell = s.eVulnerableToSpellSaved;
    }
    if (bRearmed)
    {
        s.GotoState('stateStart');
        Log("[Archipelago] APContainerManager.RepairSwappedSpawner: " $ string(s.Name) $ " (apId " $ apId $ ") opens again");
    }
}

// Every catalogued swapped container of this level whose location is unchecked
// but whose box is gone (a potion jar is used up once opened) gets a fresh
// token thrown from where the box stood.
function EnsureSpawnerTokens(string lvl)
{
    local int i, apId;
    local Vector loc;
    local Rotator rot;

    i = 0;
    while (class'APContainerCatalog'.static.SpawnerAt(lvl, i, apId, loc, rot))
    {
        EnsureSpawnerToken(lvl, apId, loc, rot);
        i++;
    }
}

// One catalogued swapped container. The throw mirrors GenericSpawner.SpawnObject:
// out of the box's front, 40 units up.
function EnsureSpawnerToken(string lvl, int apId, Vector loc, Rotator rot)
{
    local GenericSpawner s;
    local class<APContainerMarker> tokenCls;
    local Actor token;
    local Vector vThrow;
    local bool bFound;

    if (IsLocationChecked(apId)) return;
    foreach AllActors(class'GenericSpawner', s)
    {
        if (s.bDeleteMe) continue;
        if (class'APContainerStamp'.static.ApIdOf(s) == apId
            || class'APLocationRegistry'.static.GetContainerLocationId(lvl, string(s.Name)) == apId)
        {
            bFound = True;
            break;
        }
    }
    if (bFound) return;

    tokenCls = class'APMarkerClassTable'.static.ContainerTokenClass(
        class'APLocationRegistry'.static.SlotForApId(apId));
    if (tokenCls == None) return;
    RemoveTokens(apId);
    token = Spawn(tokenCls, , , loc + vect(0, 0, 40), rot);
    if (token == None)
    {
        Log("[Archipelago] APContainerManager.EnsureSpawnerToken: Spawn returned None for apId " $ apId $ " at " $ string(loc));
        return;
    }
    vThrow = vector(rot);
    vThrow.Z = 0.0;
    vThrow = Normal(vThrow) * 75.0;
    vThrow.Z = 150.0;
    token.Velocity = vThrow;
    token.SetPhysics(PHYS_Falling);
    Log("[Archipelago] APContainerManager.EnsureSpawnerToken: box for apId " $ apId $ " is gone, threw a fresh token at " $ string(loc));
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

    slot = class'APLocationRegistry'.static.SlotForApId(apId);
    if (slot >= 0
        && class'APCardWatcher'.static.IsNonCardChecked(slot))
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
    markerCls = class'APMarkerClassTable'.static.ContainerTokenClass(slot);
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

    slot = class'APLocationRegistry'.static.SlotForApId(apId);
    if (slot >= 0
        && class'APCardWatcher'.static.IsNonCardChecked(slot))
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
    markerCls = class'APMarkerClassTable'.static.ContainerTokenClass(slot);
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

// Place a container spawner at the destroyed original's exact transform. A spot
// set into level geometry (the Diffindo Challenge plant pot inside a wall sconce)
// fails the engine's spawn-time placement check even with bCollideWhenPlacing
// False, and Spawn then returns None. Fall back to the engine's own FancySpawn,
// which walks outward from the spot until one takes, then slide the actor back to
// the saved transform with world collision off for that one move. Returns None
// only when the whole search finds no room.
function Actor PlaceContainerSpawner(class<GenericSpawner> cls, name spawnTag,
                                     Vector loc, Rotator rot)
{
    local Actor placed;
    local bool savedCollideWorld, bSlidBack;

    placed = Spawn(cls, , spawnTag, loc, rot);
    if (placed != None) return placed;

    placed = FancySpawn(cls, , spawnTag, loc, rot);
    if (placed == None) return None;

    savedCollideWorld = placed.bCollideWorld;
    placed.bCollideWorld = False;
    bSlidBack = placed.SetLocation(loc);
    placed.bCollideWorld = savedCollideWorld;
    Log("[Archipelago] APContainerManager.PlaceContainerSpawner: " $ string(cls.Name)
        $ " needed the outward search at " $ string(loc)
        $ " (spot is set into level geometry); slid back=" $ string(bSlidBack));
    return placed;
}

// Swap a GenericSpawner-family box for its APContainerSpawner_<Leaf> subclass,
// CLONING the placed instance's spawn config so the swap is behaviourally
// identical to the original. The eject count comes from per-instance Limits /
// GoodiesNumber, which the leaf class defaults do NOT carry, so reverting to
// class defaults would randomise it (and break exact-count boxes). The original
// is destroyed first so the replacement spawns in its place without encroaching,
// so its config is saved to locals beforehand. A spot that refuses the
// replacement gets a stock clone back rather than nothing. After copying
// GoodieToSpawn / GoodiesNumber / Lives, the engine's cached init (HowManyObjectsToSpawn,
// bSpawnExactNumbers) is re-derived exactly as GenericSpawner.PostBeginPlay does.
// CheckLocationId is stamped via APContainerStamp (the generated subclasses each
// declare it but share no base type to cast to here).
function SwapContainerSpawner(GenericSpawner old, int apId)
{
    local class<GenericSpawner> swapCls, savedOriginalCls;
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
    local bool bAppendToken, bStockFallback;

    // Already collected -> leave the spawner 100% vanilla (no swap, no extra
    // eject slot), so a re-clear drops no phantom AP token.
    slot = class'APLocationRegistry'.static.SlotForApId(apId);
    if (slot >= 0
        && class'APCardWatcher'.static.IsNonCardChecked(slot))
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
    // Kept so a rejected swap can put a stock clone back after the Destroy below.
    savedOriginalCls = old.Class;
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

    spawned = PlaceContainerSpawner(swapCls, savedTag, savedLoc, savedRot);
    if (spawned == None)
    {
        // The original is already gone, so put a stock clone back rather than
        // leave the spot empty. The clone ejects no token, so on the next visit
        // EnsureSpawnerTokens throws this location's token from the spot.
        bStockFallback = True;
        spawned = PlaceContainerSpawner(savedOriginalCls, savedTag, savedLoc, savedRot);
        Log("[Archipelago] APContainerManager.SwapContainerSpawner: no room for "
            $ string(swapCls.Name) $ " at " $ string(savedLoc) $ " (apId " $ apId
            $ "); restoring a stock " $ string(savedClass));
    }
    nw = GenericSpawner(spawned);
    if (nw == None)
    {
        Log("[Archipelago] APContainerManager.SwapContainerSpawner: LOST the container at "
            $ string(savedLoc) $ " (apId " $ apId $ "): neither " $ string(swapCls.Name)
            $ " nor a stock " $ string(savedClass) $ " would place");
        return;
    }
    // Only append leaves buy an extra eject slot for the token: a replace leaf
    // (single-content jar) has the token stand in for its native goodie, and a
    // stock fallback clone ejects no token at all.
    bAppendToken = !bStockFallback && !class'APContainerStamp'.static.IsReplaceLeaf(nw);
    nw.Event = savedEvent;
    nw.EventName = savedEventName;
    nw.Lives = savedLives;
    // +1 buys one extra eject iteration on the first hit for the AP token; the
    // subclass's first SpawnObject undoes this so multi-life re-hits stay vanilla.
    // Skipped without an appended token: a replace leaf has the token stand in
    // for the native goodie, and a stock fallback ejects no token at all.
    nw.Limits.Max = savedLimMax;
    nw.Limits.Min = savedLimMin;
    if (bAppendToken)
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
    if (exact && bAppendToken)
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
    if (bAppendToken && nw.GoodieDelay <= 0.0) { nw.GoodieDelay = 0.5; }
    nw.BaseDelay = savedBaseDelay;

    if (bStockFallback)
    {
        Log("[Archipelago] APContainerManager.SwapContainerSpawner: stock " $ string(nw.Class.Name)
            $ " back in place (apId " $ apId $ ", lives " $ string(savedLives) $ ", NO AP token)");
        return;
    }
    if (!class'APContainerStamp'.static.Stamp(nw, apId))
    {
        Log("[Archipelago] APContainerManager.SwapContainerSpawner: Stamp FAILED (unknown subclass) for " $ string(nw.Class.Name));
    }
    Log("[Archipelago] APContainerManager.SwapContainerSpawner: swapped " $ string(nw.Class.Name)
        $ " (apId " $ apId $ ", lives " $ string(savedLives) $ ")");
}

// SpawnThingy decorations: the plant dragons and the Whomping Willow dragon are inert
// HDecoration / HPlants props, but each has co-located SpawnThingy actors (fired by the
// statue's spellTrigger on a Flipendo hit) that eject its beans. Repoint the nearest
// bean-ejecting SpawnThingy's SpawnClass to the baked AP marker, so the hit ejects the
// AP token in place of that first bean -- like a bark / mucus jar -- through the game's
// own spawn, which renders. Skipped when already collected so a re-clear stays vanilla.
function ArmSpawnThingyDecoration(HProp deco, int apId)
{
    local SpawnThingy st, best;
    local class<Actor> markerCls;
    local float d, bestD;
    local int slot;

    slot = class'APLocationRegistry'.static.SlotForApId(apId);
    if (slot < 0) return;
    if (class'APCardWatcher'.static.IsNonCardChecked(slot)) return;

    // Pick the placed bean ejector nearest the decoration. SpawnThingys sit ~60-160u
    // from their statue; a colour bean is a Jellybean subclass, so the IsA test skips
    // the FX / spider SpawnThingys and grabs an actual bean to replace.
    bestD = 100000.0;
    foreach AllActors(class'SpawnThingy', st)
    {
        if (st.SpawnClass == None) continue;
        if (!ClassIsChildOf(st.SpawnClass, class'Jellybean')) continue;
        d = VSize(st.Location - deco.Location);
        if (d < bestD) { bestD = d; best = st; }
    }
    if (best == None || bestD > 300.0)
    {
        Log("[Archipelago] APContainerManager.ArmSpawnThingyDecoration: no bean SpawnThingy near "
            $ string(deco.Name) $ " (apId " $ apId $ ")");
        return;
    }

    markerCls = class'APMarkerClassTable'.static.ContainerTokenClass(slot);
    if (markerCls == None) return;

    best.SpawnClass = markerCls;
    Log("[Archipelago] APContainerManager.ArmSpawnThingyDecoration: " $ string(deco.Name)
        $ " -> " $ string(best.Name) $ " now ejects APContainerMarker_" $ string(slot));
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
