class APGameInfo extends GameInfo;

var APIPCActor IPCActor;

// Per-classroom offset applied to the cutscene's Location when spawning the
// blocker. Lets us nudge the bookshelf without recompiling the cutscene
// lookup. (0,0,0) places it exactly on the cutscene actor; positive X is
// "forward" relative to the cutscene's Rotation.
var Vector RictaBlockerOffset;

// Class-default reference to the spawned blocker. Set after a successful
// Spawn in BlockRictaClassroomIfMissing, used by RemoveRictaBlocker for
// O(1) destroy without needing a per-level watcher in the right UWorld.
// Cleared in RemoveRictaBlocker. Auto-invalidates via bDeleteMe when the
// level it lives in is unloaded.
var Actor RictaBlockerInstance;

event InitGame(string Options, out string Error)
{
    local class<Actor> cls;

    Super.InitGame(Options, Error);
    Log("[Archipelago] APGameInfo.InitGame - subclass active");

    IPCActor = class'APIPCActor'.static.GetInstance();
    if (IPCActor != None)
    {
        Log("[Archipelago] APGameInfo: reusing existing APIPCActor singleton");
    }
    else
    {
        cls = class<Actor>(DynamicLoadObject("HPArchipelago.APIPCActor", class'Class'));
        if (cls != None)
        {
            IPCActor = APIPCActor(Spawn(cls));
            Log("[Archipelago] APGameInfo: APIPCActor spawned (new singleton)");
        }
        else
        {
            Log("[Archipelago] APGameInfo: APIPCActor class load FAILED");
        }
    }

    cls = class<Actor>(DynamicLoadObject("HPArchipelago.APCardWatcher", class'Class'));
    if (cls != None)
    {
        Spawn(cls);
        Log("[Archipelago] APGameInfo: APCardWatcher spawned (per-level)");
    }
    else
    {
        Log("[Archipelago] APGameInfo: APCardWatcher class load FAILED");
    }

    ReplaceCardChests();
    BlockRictaClassroomIfMissing();
}

// If the player doesn't already own Rictusempra (per APCardWatcher's AP-grant
// flag), spawn a bookshelf at the location of the lesson-intro cutscene
// (`02060DADARictaInt`). The cutscene's actor location is the chokepoint
// where Lockhart's intro fires when Harry walks up; blocking it prevents the
// whole softlock chain (intro -> wand minigame -> changegamestate ->
// LevelChange Ch1Rictusempra) without disturbing the eventual real run-through
// once AP grants the spell.
function BlockRictaClassroomIfMissing()
{
    local CutScene cs;
    local Actor blocker;
    local Vector spawnLoc;
    local Rotator spawnRot;
    local bool found;

    if (class'APCardWatcher'.default.APGrantedSpell[4] == 1)
    {
        Log("[Archipelago] BlockRicta: player has Rictusempra (APGrantedSpell[4]=1) - no blocker needed");
        return;
    }

    foreach AllActors(class'CutScene', cs)
    {
        if (cs.FileName == "02060DADARictaInt")
        {
            spawnLoc = cs.Location + RictaBlockerOffset;
            spawnRot = cs.Rotation;
            Log("[Archipelago] BlockRicta: cutscene=" $ string(cs.Name)
                $ " FileName=" $ cs.FileName
                $ " Loc=" $ string(cs.Location)
                $ " Rot=" $ string(cs.Rotation)
                $ " offset=" $ string(RictaBlockerOffset)
                $ " spawnLoc=" $ string(spawnLoc));
            blocker = Spawn(class'BookcaseGlassDoors', , , spawnLoc, spawnRot);
            if (blocker == None)
            {
                Log("[Archipelago] BlockRicta: Spawn returned None (encroachment likely - try a non-zero RictaBlockerOffset.Z)");
            }
            else
            {
                blocker.Tag = 'APRictaBlocker';
                default.RictaBlockerInstance = blocker;
                Log("[Archipelago] BlockRicta: spawned " $ string(blocker)
                    $ " bCollideActors=" $ string(blocker.bCollideActors)
                    $ " bBlockActors=" $ string(blocker.bBlockActors)
                    $ " bBlockPlayers=" $ string(blocker.bBlockPlayers)
                    $ " (tracked as default.RictaBlockerInstance)");
            }
            found = True;
            break;
        }
    }
    if (!found)
    {
        Log("[Archipelago] BlockRicta: 02060DADARictaInt cutscene not present in this level (expected only in Grandstaircase_hub)");
    }
}

// Live removal: destroy any blocker we previously spawned. Called when AP
// grants Rictusempra mid-session.
//
// Two paths:
//  1) Direct ref via default.RictaBlockerInstance (set when BlockRicta
//     spawned the blocker THIS session). O(1), works across UWorlds.
//  2) Fallback: iterate via the latest watcher's UWorld looking for any
//     actor tagged 'APRictaBlocker' (covers the case where the blocker
//     was saved into a .usa and restored in a fresh session, so our
//     class-default ref is None but a tagged actor still exists).
function RemoveRictaBlocker()
{
    local Actor b, a, scanActor;
    local APCardWatcher w;
    local int n;

    b = default.RictaBlockerInstance;
    if (b != None && !b.bDeleteMe)
    {
        Log("[Archipelago] RemoveRictaBlocker: destroying tracked blocker " $ string(b) $ " at " $ string(b.Location) $ " (in level " $ string(b.Level) $ ")");
        b.Destroy();
        default.RictaBlockerInstance = None;
        return;
    }
    if (b != None)
    {
        Log("[Archipelago] RemoveRictaBlocker: tracked ref was already bDeleteMe - clearing");
        default.RictaBlockerInstance = None;
    }

    // Fallback: scan via watcher's UWorld for any tagged blocker.
    w = class'APCardWatcher'.static.GetLatest();
    if (w == None)
    {
        Log("[Archipelago] RemoveRictaBlocker: no tracked ref AND no watcher to scan - giving up (nothing to destroy)");
        return;
    }
    if (w.HarryRef != None && !w.HarryRef.bDeleteMe)
    {
        scanActor = w.HarryRef;
    }
    else
    {
        scanActor = w;
    }
    n = 0;
    foreach scanActor.AllActors(class'Actor', a)
    {
        if (a.Tag == 'APRictaBlocker' && !a.bDeleteMe)
        {
            Log("[Archipelago] RemoveRictaBlocker: tag-scan found " $ string(a) $ " in " $ string(scanActor.Level) $ " - destroying");
            a.Destroy();
            n++;
        }
    }
    if (n == 0)
    {
        Log("[Archipelago] RemoveRictaBlocker: tag-scan in " $ string(scanActor.Level) $ " found 0 blockers (player likely not in Grandstaircase_hub)");
    }
}

// Replace every card-class reference in chests/cauldrons (and every loose
// WizardCardIcon actor in the level) with the corresponding APCardMarker_<class>
// subclass. Called from InitGame on every level entry.
//
// Why this exists: vanilla harry.uc:977 calls RemoveHarryOwnedCardsFromLevel(None)
// on level entry, which bean-swaps any chest holding a card the player already
// owns. That makes those AP locations unreachable. Our markers carry a sentinel
// Id that vanilla never matches, so they survive the sweep.
function ReplaceCardChests()
{
    local chestbronze chest;
    local bronzecauldron cauldron;
    local WizardCardIcon wci;
    local class<Actor> markerClass;
    local Actor spawned;
    local Vector looseLoc;
    local Rotator looseRot;
    local int i;
    local int totalReplaced;

    totalReplaced = 0;

    foreach AllActors(class'chestbronze', chest)
    {
        for (i = 0; i < ArrayCount(chest.EjectedObjects); i++)
        {
            if (TryReplaceCardSlot(chest.EjectedObjects[i], markerClass))
            {
                Log("[Archipelago] ReplaceCardChests: chest=" $ string(chest) $ " slot=" $ i $ " was=" $ string(chest.EjectedObjects[i]) $ " -> " $ string(markerClass));
                chest.EjectedObjects[i] = markerClass;
                totalReplaced++;
            }
        }
    }

    foreach AllActors(class'bronzecauldron', cauldron)
    {
        for (i = 0; i < ArrayCount(cauldron.EjectedObjects); i++)
        {
            if (TryReplaceCardSlot(cauldron.EjectedObjects[i], markerClass))
            {
                Log("[Archipelago] ReplaceCardChests: cauldron=" $ string(cauldron) $ " slot=" $ i $ " was=" $ string(cauldron.EjectedObjects[i]) $ " -> " $ string(markerClass));
                cauldron.EjectedObjects[i] = markerClass;
                totalReplaced++;
            }
        }
    }

    foreach AllActors(class'WizardCardIcon', wci)
    {
        if (wci.IsA('APCardMarker')) continue;
        markerClass = class<Actor>(DynamicLoadObject("HPArchipelago.APCardMarker_" $ string(wci.Class.Name), class'Class'));
        if (markerClass != None)
        {
            // Capture location/rotation before destroying wci. We must destroy
            // wci FIRST — Spawn at the same coords with wci still present causes
            // encroachment, the engine destroys the new marker and returns None.
            looseLoc = wci.Location;
            looseRot = wci.Rotation;
            Log("[Archipelago] ReplaceCardChests: loose icon=" $ string(wci) $ " (class=" $ string(wci.Class.Name) $ ") at " $ string(looseLoc) $ " -> spawn " $ string(markerClass));
            wci.Destroy();
            spawned = Spawn(markerClass, , , looseLoc, looseRot);
            if (spawned == None)
            {
                Log("[Archipelago] ReplaceCardChests: Spawn STILL returned None for " $ string(markerClass) $ " at " $ string(looseLoc));
            }
            else
            {
                APCardMarker(spawned).MarkAsLoose();
                Log("[Archipelago] ReplaceCardChests: spawned " $ string(spawned) $ " at " $ string(spawned.Location) $ " (loose, gravity disabled)");
            }
            totalReplaced++;
        }
        else
        {
            Log("[Archipelago] ReplaceCardChests: loose icon=" $ string(wci) $ " (class=" $ string(wci.Class.Name) $ ") - no APCardMarker_<class> found, leaving alone");
        }
    }

    if (totalReplaced > 0)
    {
        Log("[Archipelago] ReplaceCardChests: replaced " $ totalReplaced $ " card slot(s) / loose icon(s) with APCardMarker subclasses");
    }
}

// Helper: if `slot` is a WizardCardIcon subclass that isn't already our marker,
// resolve the corresponding APCardMarker_<ClassName> and write it to outClass.
// Returns true if a replacement was found.
function bool TryReplaceCardSlot(class<Actor> slot, out class<Actor> outClass)
{
    if (slot == None) return False;
    if (ClassIsChildOf(slot, class'APCardMarker')) return False;
    if (!ClassIsChildOf(slot, class'WizardCardIcon')) return False;

    outClass = class<Actor>(DynamicLoadObject("HPArchipelago.APCardMarker_" $ string(slot.Name), class'Class'));
    if (outClass == None)
    {
        Log("[Archipelago] ReplaceCardChests: no APCardMarker_" $ string(slot.Name) $ " - leaving slot alone");
        return False;
    }
    return True;
}

function bool IsKnownSpellName(string Name)
{
    return Name == "Alohomora" || Name == "Diffindo" || Name == "Flipendo"
        || Name == "Lumos" || Name == "Rictusempra" || Name == "Skurge"
        || Name == "Spongify";
}

function bool TryApplyCard(string ItemName, harry h)
{
    local class<WizardCardIcon> cardClass;
    local class<StatusItemWizardCards> siClass;
    local StatusGroupWizardCards sgCards;
    local StatusItemWizardCards siCard;

    cardClass = class<WizardCardIcon>(DynamicLoadObject("HGame." $ ItemName, class'Class'));
    if (cardClass == None)
    {
        return False;
    }

    if (ClassIsChildOf(cardClass, class'BronzeCards'))
    {
        siClass = class'StatusItemBronzeCards';
    }
    else if (ClassIsChildOf(cardClass, class'SilverCards'))
    {
        siClass = class'StatusItemSilverCards';
    }
    else if (ClassIsChildOf(cardClass, class'Goldcards'))
    {
        siClass = class'StatusItemGoldCards';
    }
    else
    {
        Log("[Archipelago] ApplyGrant: " $ ItemName $ " is not a recognized card tier");
        return False;
    }

    if (h.managerStatus == None)
    {
        Log("[Archipelago] ApplyGrant: harry.managerStatus is None, cannot grant card");
        return False;
    }
    sgCards = StatusGroupWizardCards(h.managerStatus.GetStatusGroup(class'StatusGroupWizardCards'));
    if (sgCards == None)
    {
        Log("[Archipelago] ApplyGrant: StatusGroupWizardCards not found");
        return False;
    }
    siCard = StatusItemWizardCards(sgCards.GetStatusItem(siClass));
    if (siCard == None)
    {
        Log("[Archipelago] ApplyGrant: StatusItem for " $ string(siClass) $ " not found");
        return False;
    }

    if (class'APCardWatcher'.static.GetLatest() != None)
    {
        class'APCardWatcher'.static.GetLatest().MarkAsGranted(cardClass.default.Id);
    }
    siCard.SetCardOwner(cardClass.default.Id, siCard.ECardOwner.CardOwner_Harry);
    // NOTE: vanilla Touch chain ends with sgCards.RemoveHarryOwnedCardsFromLevel(self)
    // to clean up the picked-up icon and replace duplicate-card chest contents
    // with Jellybeans. We deliberately DO NOT call it here. For an AP grant we
    // have no in-level icon to clean up, and the chest-mutation side effect
    // makes the player unable to visit those card locations later (the chest
    // would spawn a bean instead of the card icon). Trade-off documented in
    // docs/DESIGN.md v2 parking lot.
    Log("[Archipelago] ApplyGrant: granted card " $ ItemName $ " (Id=" $ cardClass.default.Id $ ")");
    return True;
}

function bool TryApplyKeyItem(string Name, harry h)
{
    local APCardWatcher watcher;

    if (h == None || h.managerStatus == None) return False;
    if (Name != "Boomslang" && Name != "Bicorn" && Name != "BitOGoyle") return False;

    watcher = class'APCardWatcher'.static.GetLatest();
    if (watcher != None)
    {
        watcher.MarkKeyItemAsGranted(Name);
    }

    if (Name == "Boomslang")
    {
        h.managerStatus.AddBoomslang(1);
        Log("[Archipelago] ApplyGrant: granted Boomslang via AddBoomslang(1)");
        return True;
    }
    if (Name == "Bicorn")
    {
        h.managerStatus.AddBicorn(1);
        Log("[Archipelago] ApplyGrant: granted Bicorn via AddBicorn(1)");
        return True;
    }
    if (Name == "BitOGoyle")
    {
        h.managerStatus.IncrementCount(class'StatusGroupPolyIngr', class'StatusItemBitOGoyle', 1);
        Log("[Archipelago] ApplyGrant: granted BitOGoyle via IncrementCount");
        return True;
    }
    return False;
}

static function harry FindActiveHarry(Actor caller)
{
    local APCardWatcher watcher;
    local harry h, fallback;

    watcher = class'APCardWatcher'.static.GetLatest();
    if (watcher != None)
    {
        h = TryGetViewportHarry(harry(watcher.Level.PlayerHarryActor));
        if (h != None)
        {
            Log("[Archipelago] FindActiveHarry: using watcher console Viewport.Actor=" $ string(h) $ " (watcher.Level=" $ string(watcher.Level) $ ")");
            return h;
        }
        h = harry(watcher.Level.PlayerHarryActor);
        if (h != None && !h.bDeleteMe)
        {
            Log("[Archipelago] FindActiveHarry: using watcher.Level.PlayerHarryActor=" $ string(h) $ " (watcher.Level=" $ string(watcher.Level) $ ")");
            return h;
        }
        if (watcher.HarryRef != None && !watcher.HarryRef.bDeleteMe)
        {
            Log("[Archipelago] FindActiveHarry: using watcher.HarryRef=" $ string(watcher.HarryRef));
            return watcher.HarryRef;
        }
    }

    h = TryGetViewportHarry(harry(caller.Level.PlayerHarryActor));
    if (h != None)
    {
        Log("[Archipelago] FindActiveHarry: using caller console Viewport.Actor=" $ string(h));
        return h;
    }

    h = harry(caller.Level.PlayerHarryActor);
    if (h != None && !h.bDeleteMe)
    {
        Log("[Archipelago] FindActiveHarry: fallback to caller.Level.PlayerHarryActor=" $ string(h));
        return h;
    }

    foreach caller.AllActors(class'harry', h)
    {
        if (h.bDeleteMe)
        {
            continue;
        }
        if (fallback == None)
        {
            fallback = h;
        }
    }
    if (fallback != None)
    {
        Log("[Archipelago] FindActiveHarry: last-resort foreach fallback=" $ string(fallback));
    }
    return fallback;
}

static function harry TryGetViewportHarry(harry SourceHarry)
{
    local HPConsole Console;
    local harry ViewportHarry;

    if (SourceHarry == None || SourceHarry.Player == None)
    {
        return None;
    }

    Console = HPConsole(SourceHarry.Player.Console);
    if (Console == None || Console.Viewport == None)
    {
        return None;
    }

    ViewportHarry = harry(Console.Viewport.Actor);
    if (ViewportHarry != None && !ViewportHarry.bDeleteMe)
    {
        return ViewportHarry;
    }
    return None;
}

static function harry FindGrantReadyHarry(Actor caller)
{
    local APCardWatcher watcher;
    local harry h;

    watcher = class'APCardWatcher'.static.GetLatest();
    if (watcher != None)
    {
        h = TryGetViewportHarry(watcher.HarryRef);
        if (h != None)
        {
            Log("[Archipelago] FindGrantReadyHarry: using watcher.HarryRef console Viewport.Actor=" $ string(h));
            return h;
        }

        h = TryGetViewportHarry(harry(watcher.Level.PlayerHarryActor));
        if (h != None)
        {
            Log("[Archipelago] FindGrantReadyHarry: using watcher.Level.PlayerHarryActor console Viewport.Actor=" $ string(h));
            return h;
        }

        if (watcher.HarryRef != None && watcher.HarryRef.Player != None && !watcher.HarryRef.bDeleteMe)
        {
            Log("[Archipelago] FindGrantReadyHarry: using watcher.HarryRef=" $ string(watcher.HarryRef));
            return watcher.HarryRef;
        }

        h = harry(watcher.Level.PlayerHarryActor);
        if (h != None && h.Player != None && !h.bDeleteMe)
        {
            Log("[Archipelago] FindGrantReadyHarry: using watcher.Level.PlayerHarryActor=" $ string(h));
            return h;
        }
    }

    h = TryGetViewportHarry(harry(caller.Level.PlayerHarryActor));
    if (h != None)
    {
        Log("[Archipelago] FindGrantReadyHarry: using caller console Viewport.Actor=" $ string(h));
        return h;
    }

    h = harry(caller.Level.PlayerHarryActor);
    if (h != None && h.Player != None && !h.bDeleteMe)
    {
        Log("[Archipelago] FindGrantReadyHarry: using caller.Level.PlayerHarryActor=" $ string(h));
        return h;
    }

    return None;
}

function ApplyGrant(string ItemName)
{
    local harry h;

    Log("[Archipelago] APGameInfo.ApplyGrant: " $ ItemName);

    h = FindGrantReadyHarry(self);
    if (h == None)
    {
        Log("[Archipelago] ApplyGrant: no ready gameplay harry to deliver to");
        return;
    }
    Log("[Archipelago] ApplyGrant: targeting harry=" $ string(h) $ " managerStatus=" $ string(h.managerStatus));

    if (IsKnownSpellName(ItemName))
    {
        Log("[Archipelago] ApplyGrant: spell " $ ItemName $ " - marking AP-granted + AddToSpellBookByString");
        // Always set the class-default flag — works even when no watcher
        // instance is alive (e.g. during Save0.usa load gap). Next level's
        // watcher PreBeginPlay will copy default -> instance.
        class'APCardWatcher'.static.MarkSpellAsAPGrantedDefault(ItemName);
        if (class'APCardWatcher'.static.GetLatest() != None)
        {
            class'APCardWatcher'.static.GetLatest().MarkSpellAsGranted(ItemName);
        }
        h.AddToSpellBookByString(ItemName);
        if (ItemName == "Rictusempra")
        {
            RemoveRictaBlocker();
        }
        return;
    }

    if (TryApplyKeyItem(ItemName, h))
    {
        return;
    }

    if (ItemName == "BeansSmall")
    {
        h.managerStatus.AddBeans(25);
        Log("[Archipelago] ApplyGrant: granted BeansSmall (+25)");
        return;
    }
    if (ItemName == "BeansMedium")
    {
        h.managerStatus.AddBeans(50);
        Log("[Archipelago] ApplyGrant: granted BeansMedium (+50)");
        return;
    }
    if (ItemName == "BeansLarge")
    {
        h.managerStatus.AddBeans(100);
        Log("[Archipelago] ApplyGrant: granted BeansLarge (+100)");
        return;
    }

    if (TryApplyCard(ItemName, h))
    {
        return;
    }

    Log("[Archipelago] ApplyGrant: unknown item " $ ItemName);
}

defaultproperties
{
    RictaBlockerOffset=(X=-15.000000,Y=130.000000,Z=0.000000)
}
