// Open-castle bean-reward-room subsystem: per-bean floor persistence, chest/
// gargoyle one-time dispense + dropped-bean snapshot, and the AP-storage resync.
// A logic-only singleton (no mesh, bGameRelevant=False so it dies on every level
// transition) found-or-spawned via GetInstance. The per-visit scratch
// (bFloorBeansTagged, BeanPresentNow/LastTick, bDropsRestored) is INSTANCE state
// that resets with each level's fresh singleton, exactly like the per-level
// watcher; the cross-level ledger (BeanRoomCollected, DispenserOpened,
// DropBeanPos/Count) is class-default and persists for the process. The watcher
// drives Scan/Manage each tick via GetInstance.
class APBeanRoom extends Info;

// Process-wide singleton pointer (class-default). The instance copy is unused and
// kept None for save-graph hygiene, mirroring APHUDToast.
var APBeanRoom LatestInstance;

// Per-bean collection state for the FLOOR beans. The room reloads fresh on every
// entry (vanilla only visits it on scripted occasions and wants fresh beans each
// time), so picked-up beans would respawn = farming. The placed floor beans are
// the base Jellybean class with stable Names (Jellybean<N>), so BeanRoomCollected[N]
// (class-default, persisted) records which were taken; a re-entry destroys only
// those and leaves uncollected ones (e.g. behind a spell the player lacks) for a
// later visit. Index space covers the max placed index (497) with slack. The
// ledger applies ONLY to placed floor beans, tagged 'APFloorBean' at the first
// scan of a visit: chest/gargoyle beans are subclasses or spawned later and can
// recycle a freed floor-bean Name, so without the tag they would be mistaken for
// collected floor beans and destroyed. BeanPresentNow/LastTick + bFloorBeansTagged
// are per-visit scratch (instance, zero-init per fresh singleton).
var byte BeanRoomCollected[512];
var byte BeanPresentNow[512];
var byte BeanPresentLastTick[512];
var byte bFloorBeansTagged;

// Bean-ledger and drop-snapshot sizes. The arrays are dimensioned with the
// literal value (M212 forbids a const in an array dimension); the loop bounds
// and range checks below use the const so the two stay in step.
const BEAN_LEDGER_SIZE = 512;
const MAX_DROP_BEANS = 64;

// Chest/gargoyle one-time + dropped-bean persistence. The room reloads fresh on
// every entry, so natively chests/gargoyle re-open (farm) and dropped beans
// vanish. DispenserOpened (class-default, persisted) marks ChestGold0-5 (idx 0-5)
// and GenericSpawner0 (idx 6) opened, so a re-entry forces them spent (no re-farm).
// DropBeanPos/Count (class-default, persisted) is a snapshot of the dropped beans
// currently on the ground, re-recorded each tick so collected beans drop out: on
// re-entry the snapshot is re-spawned at its saved spots, never added on top (so
// no compounding). bDropsRestored is per-visit.
var byte DispenserOpened[8];
var Vector DropBeanPos[64];
var int DropBeanCount;
var byte bDropsRestored;

// Found-or-spawned singleton accessor. Returns the live instance, lazily spawning
// one via the caller's context on first use of a level. Logic-only (no mesh) so
// runtime spawn is safe in this open-castle build.
static function APBeanRoom GetInstance(Actor ctx)
{
    if (default.LatestInstance != None && !default.LatestInstance.bDeleteMe)
        return default.LatestInstance;
    if (ctx == None) return None;
    return ctx.Spawn(class'APBeanRoom');
}

event PreBeginPlay()
{
    Super.PreBeginPlay();
    // The instance copy of LatestInstance must stay None (only default.LatestInstance
    // is the singleton pointer); Spawn seeds it from the class default.
    LatestInstance = None;
    default.LatestInstance = self;
}

// Per-bean persistence sweep. Each call: destroy beans whose index is already
// collected, then mark any bean that was present last tick and is now gone (the
// only way a bean leaves the room is the player collecting it). First visit starts
// with an empty ledger so every bean is collectable; uncollected beans persist for
// later visits. No-op outside BeanRewardRoom / open castle. Called from the
// watcher's Snapshot (immediate) and per-tick Timer (catches collections + the
// room's fresh reload).
function ScanBeanRoom()
{
    local Jellybean b;
    local int idx, i;

    if (class'APModeDetector'.default.bOpenCastleMode != 1) return;
    if (Caps(string(Level.Outer.Name)) != "BEANREWARDROOM") return;

    // First scan of the visit: tag the placed floor beans, which are the only
    // beans present before any chest/gargoyle dispenses. Restrict to the exact
    // base Jellybean class (placed floor beans); chest beans are subclasses.
    // Only tagged beans are tracked below, so a chest/gargoyle bean that later
    // recycles a freed floor-bean Name is never mistaken for a collected floor
    // bean (which is what was deleting chest beans after ~0.25s).
    if (bFloorBeansTagged == 0)
    {
        foreach AllActors(class'Jellybean', b)
        {
            if (b == None || b.bDeleteMe) continue;
            if (b.Class != class'Jellybean') continue;
            b.Tag = 'APFloorBean';
        }
        bFloorBeansTagged = 1;
    }

    for (i = 0; i < BEAN_LEDGER_SIZE; i++)
    {
        BeanPresentNow[i] = 0;
    }

    foreach AllActors(class'Jellybean', b)
    {
        if (b == None || b.bDeleteMe) continue;
        if (b.Tag != 'APFloorBean') continue; // floor beans only; ignore chest/gargoyle beans
        idx = int(Mid(string(b.Name), 9));    // strip the "Jellybean" prefix (9 chars)
        if (idx < 0 || idx >= BEAN_LEDGER_SIZE) continue;
        if (default.BeanRoomCollected[idx] == 1)
        {
            b.Destroy();                      // collected on a prior visit
            continue;
        }
        BeanPresentNow[idx] = 1;
    }

    for (i = 0; i < BEAN_LEDGER_SIZE; i++)
    {
        if (BeanPresentLastTick[i] == 1 && BeanPresentNow[i] == 0
            && default.BeanRoomCollected[i] == 0)
        {
            default.BeanRoomCollected[i] = 1; // present last tick, gone now = picked up
        }
        BeanPresentLastTick[i] = BeanPresentNow[i];
    }
}

// One of ChestGold's ejected bean subclasses (so the floor ledger, base Jellybean
// only, ignores them). Position is the only persisted attribute, so colour is
// free to vary.
function class<Actor> RandomBeanClass()
{
    switch (Rand(5))
    {
        case 0:  return class'BlueJellyBean';
        case 1:  return class'GreenJellyBean';
        case 2:  return class'SpottedJellyBean';
        case 3:  return class'GreenPurpleCheckerBean';
    }
    return class'RedBlackStripeBean';
}

// Re-create one persisted dropped bean at its saved resting `pos` (no fling),
// tagged 'APDropBean' so the snapshot recognises it.
function SpawnDropBean(Vector pos)
{
    local Actor bean;

    pos.Z += 8.0;
    bean = Spawn(RandomBeanClass(), None, 'APDropBean', pos);
    if (bean != None) bean.Tag = 'APDropBean';
}

// Chest/gargoyle one-time + dropped-bean persistence. Runs after ScanBeanRoom so
// floor beans are already tagged 'APFloorBean' and excluded here. See the
// DispenserOpened/DropBeanPos declaration for the model.
function ManageBeanDrops()
{
    local ChestGold chest;
    local GenericSpawner garg;
    local Jellybean b;
    local int idx, s;

    if (class'APModeDetector'.default.bOpenCastleMode != 1) return;
    if (Caps(string(Level.Outer.Name)) != "BEANREWARDROOM") return;

    // Restore once per visit: force prior-opened dispensers spent and re-create
    // the saved dropped beans. Return before the snapshot so the re-created beans
    // are recorded next tick rather than cleared this one.
    if (bDropsRestored == 0)
    {
        foreach AllActors(class'ChestGold', chest)
        {
            if (chest == None || chest.bDeleteMe) continue;
            idx = int(Mid(string(chest.Name), 9));   // "ChestGold" is 9 chars
            if (idx < 0 || idx > 5) continue;
            if (default.DispenserOpened[idx] == 1)
            {
                chest.bOpened = True;
                chest.bProjTarget = False;
                if (!chest.IsInState('stillOpen')) chest.GotoState('stillOpen');
            }
        }
        foreach AllActors(class'GenericSpawner', garg)
        {
            if (garg == None || garg.bDeleteMe) continue;
            // Spent: remove the gargoyle on re-entry so its leftover Alohomora
            // target reticle goes too. Its beans persist via the snapshot.
            if (default.DispenserOpened[6] == 1)
                garg.Destroy();
            break;
        }
        // Clear any drop beans already present, so a re-run of restore (the
        // latest watcher gets replaced by a newly-promoted one mid-visit, which
        // re-snapshots) re-creates the ledger instead of stacking a second copy.
        foreach AllActors(class'Jellybean', b)
        {
            if (b == None || b.bDeleteMe) continue;
            if (b.Tag == 'APDropBean') b.Destroy();
        }
        for (s = 0; s < default.DropBeanCount; s++)
            SpawnDropBean(default.DropBeanPos[s]);
        bDropsRestored = 1;
        Log("[Archipelago] ManageBeanDrops: restored " $ default.DropBeanCount $ " dropped bean(s)");
        return;
    }

    // First open this visit: let the dispenser eject natively over time. A player
    // who leaves mid-spew loses the beans that have not ejected yet - that is
    // accepted. The containersanity AP token rides the native eject queue like any
    // other container (the chest is injected at EjectedObjects[0], the gargoyle is
    // swapped to APContainerSpawner_GenericSpawner; both by APContainerManager), so
    // it drops first, in sequence, at the correct time. All this needs to do is
    // mark the dispenser spent so a re-entry can't re-farm; the snapshot below
    // persists the beans that reach the floor.
    foreach AllActors(class'ChestGold', chest)
    {
        if (chest == None || chest.bDeleteMe) continue;
        idx = int(Mid(string(chest.Name), 9));
        if (idx < 0 || idx > 5) continue;
        if (chest.bOpened && default.DispenserOpened[idx] == 0)
        {
            default.DispenserOpened[idx] = 1;
            Log("[Archipelago] ManageBeanDrops: ChestGold" $ idx $ " opened (native eject)");
        }
    }
    foreach AllActors(class'GenericSpawner', garg)
    {
        if (garg == None || garg.bDeleteMe) continue;
        if (!garg.IsInState('stateStart') && default.DispenserOpened[6] == 0)
        {
            default.DispenserOpened[6] = 1;
            Log("[Archipelago] ManageBeanDrops: gargoyle opened (native eject)");
        }
        break;
    }

    // Tag any new dropped beans (floor beans are already 'APFloorBean').
    foreach AllActors(class'Jellybean', b)
    {
        if (b == None || b.bDeleteMe) continue;
        if (b.Tag == 'APFloorBean' || b.Tag == 'APDropBean') continue;
        b.Tag = 'APDropBean';
    }

    // Snapshot the dropped beans on the ground. Re-recorded each tick, so a
    // collected bean drops out and the ledger never grows on its own.
    default.DropBeanCount = 0;
    foreach AllActors(class'Jellybean', b)
    {
        if (b == None || b.bDeleteMe) continue;
        if (b.Tag != 'APDropBean') continue;
        if (default.DropBeanCount >= MAX_DROP_BEANS) break;
        default.DropBeanPos[default.DropBeanCount] = b.Location;
        default.DropBeanCount++;
    }
}

// Serialize the whole bean-room ledger to one flat comma-list for the client to
// persist in AP data storage (the .usa cannot hold mod data on M212, so AP
// storage is the only thing that survives a restart). Layout: 8 dispenser flags,
// then floor-collected count + each collected index, then drop count + each
// drop's int x,y,z. Parsed back by ApplyResyncBeanRoom.
static function string BuildBeanRoomState()
{
    local int i, nFloor;
    local string csv;
    local Vector vp;

    csv = "";
    for (i = 0; i < 8; i++)
        csv = csv $ string(default.DispenserOpened[i]) $ ",";

    nFloor = 0;
    for (i = 0; i < BEAN_LEDGER_SIZE; i++)
        if (default.BeanRoomCollected[i] == 1) nFloor++;
    csv = csv $ string(nFloor);
    for (i = 0; i < BEAN_LEDGER_SIZE; i++)
        if (default.BeanRoomCollected[i] == 1) csv = csv $ "," $ string(i);

    csv = csv $ "," $ string(default.DropBeanCount);
    for (i = 0; i < default.DropBeanCount && i < MAX_DROP_BEANS; i++)
    {
        vp = default.DropBeanPos[i];
        csv = csv $ "," $ string(int(vp.X)) $ "," $ string(int(vp.Y)) $ "," $ string(int(vp.Z));
    }
    return csv;
}

// Restore the bean-room ledger from a persisted payload (client sends it on
// connect / HELLO). Dispensers + floor merge (set, never clear) so re-applying
// on a mid-session reconnect can't un-spend or un-collect. Drops apply only when
// the in-memory ledger is empty (a cold load), so a reconnect mid-visit can't
// revert live drops.
static function ApplyResyncBeanRoom(string payload)
{
    local string rest;
    local int i, v, nFloor, idx, nDrop, m;
    local Vector vp;

    if (payload == "") return;
    rest = payload;

    for (i = 0; i < 8; i++)
    {
        v = class'APCsvCodec'.static.NextCsvInt(rest);
        if (v != 0) default.DispenserOpened[i] = 1;
    }

    nFloor = class'APCsvCodec'.static.NextCsvInt(rest);
    for (i = 0; i < nFloor; i++)
    {
        if (rest == "") break;
        idx = class'APCsvCodec'.static.NextCsvInt(rest);
        if (idx >= 0 && idx < BEAN_LEDGER_SIZE) default.BeanRoomCollected[idx] = 1;
    }

    nDrop = class'APCsvCodec'.static.NextCsvInt(rest);
    if (default.DropBeanCount == 0 && nDrop > 0)
    {
        m = nDrop;
        if (m > MAX_DROP_BEANS) m = MAX_DROP_BEANS;
        for (i = 0; i < m; i++)
        {
            if (rest == "") break;
            vp.X = class'APCsvCodec'.static.NextCsvInt(rest);
            vp.Y = class'APCsvCodec'.static.NextCsvInt(rest);
            vp.Z = class'APCsvCodec'.static.NextCsvInt(rest);
            default.DropBeanPos[i] = vp;
        }
        default.DropBeanCount = m;
    }
    Log("[Archipelago] ApplyResyncBeanRoom: applied (floor=" $ nFloor $ " drops=" $ nDrop $ ")");
}

// Clear the bean-room ledger for a genuine new game so the fresh playthrough's
// room starts full (all beans collectable, dispensers closed). Class-defaults
// otherwise carry the prior playthrough's state within a process.
static function WipeBeanRoomState()
{
    local int i;
    for (i = 0; i < 8; i++) default.DispenserOpened[i] = 0;
    for (i = 0; i < BEAN_LEDGER_SIZE; i++) default.BeanRoomCollected[i] = 0;
    default.DropBeanCount = 0;
    Log("[Archipelago] WipeBeanRoomState: cleared (new game)");
}

// Push the current bean-room ledger to the client so it lands in AP data storage
// and survives a restart. Called when the player leaves BeanRewardRoom.
static function SendBeanRoomStateToClient()
{
    local APIPCActor ipc;
    ipc = class'APIPCActor'.static.GetInstance();
    if (ipc != None)
        ipc.SendBeanRoomState(BuildBeanRoomState());
}

defaultproperties
{
    // Logic-only, no render, no collision. bGameRelevant=False is load-bearing,
    // not decorative: it makes each level transition destroy this singleton so
    // the next level's fresh instance zero-inits the per-visit scratch, exactly
    // like the per-level watcher. The class-default ledger persists regardless.
    bHidden=True
    bGameRelevant=False
    bCollideActors=False
    bBlockActors=False
}
