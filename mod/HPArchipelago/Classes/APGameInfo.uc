class APGameInfo extends GameInfo;

var APIPCActor IPCActor;

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
                Log("[Archipelago] ReplaceCardChests: spawned " $ string(spawned) $ " at " $ string(spawned.Location));
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

function ApplyGrant(string ItemName)
{
    local harry h;

    Log("[Archipelago] APGameInfo.ApplyGrant: " $ ItemName);

    h = FindActiveHarry(self);
    if (h == None)
    {
        Log("[Archipelago] ApplyGrant: no harry to deliver to");
        return;
    }
    Log("[Archipelago] ApplyGrant: targeting harry=" $ string(h) $ " managerStatus=" $ string(h.managerStatus));

    if (IsKnownSpellName(ItemName))
    {
        Log("[Archipelago] ApplyGrant: spell " $ ItemName $ " - marking AP-granted + AddToSpellBookByString");
        if (class'APCardWatcher'.static.GetLatest() != None)
        {
            class'APCardWatcher'.static.GetLatest().MarkSpellAsGranted(ItemName);
        }
        h.AddToSpellBookByString(ItemName);
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
