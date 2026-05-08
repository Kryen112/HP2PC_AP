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
    sgCards.RemoveHarryOwnedCardsFromLevel(None);
    Log("[Archipelago] ApplyGrant: granted card " $ ItemName $ " (Id=" $ cardClass.default.Id $ ")");
    return True;
}

function bool TryApplyKeyItem(string Name, harry h)
{
    if (h == None || h.managerStatus == None) return False;
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
        Log("[Archipelago] ApplyGrant: granted BitOGoyle via IncrementCount(StatusGroupPolyIngr,StatusItemBitOGoyle,1)");
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
