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
        Log("[Archipelago] APGameInfo: APCardWatcher spawned");
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

function ApplyGrant(string ItemName)
{
    local class<WizardCardIcon> cardClass;
    local WizardCardIcon cardActor;
    local harry h;
    local PlayerPawn pp;
    local Vector spawnLoc;
    local int attempt;

    Log("[Archipelago] APGameInfo.ApplyGrant: " $ ItemName);

    foreach AllActors(class'PlayerPawn', pp)
    {
        if (pp.bIsPlayer && pp.IsA('harry'))
        {
            h = harry(pp);
            break;
        }
    }
    if (h == None)
    {
        foreach AllActors(class'harry', h)
        {
            break;
        }
    }
    if (h == None)
    {
        Log("[Archipelago] ApplyGrant: no harry to deliver to");
        return;
    }

    if (IsKnownSpellName(ItemName))
    {
        Log("[Archipelago] ApplyGrant: spell " $ ItemName $ " - calling AddToSpellBookByString");
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

    cardClass = class<WizardCardIcon>(DynamicLoadObject("HGame." $ ItemName, class'Class'));
    if (cardClass == None)
    {
        Log("[Archipelago] ApplyGrant: unknown class HGame." $ ItemName);
        return;
    }

    foreach AllActors(class'PlayerPawn', pp)
    {
        if (pp.bIsPlayer && pp.IsA('harry'))
        {
            h = harry(pp);
            break;
        }
    }
    if (h == None)
    {
        foreach AllActors(class'harry', h)
        {
            break;
        }
    }
    if (h == None)
    {
        Log("[Archipelago] ApplyGrant: no harry to deliver to");
        return;
    }

    for (attempt = 0; attempt < 4; attempt++)
    {
        spawnLoc = h.Location + vect(0, 0, 1) * (100 + attempt * 200);
        cardActor = Spawn(cardClass, , , spawnLoc);
        if (cardActor != None)
        {
            break;
        }
    }
    if (cardActor == None)
    {
        Log("[Archipelago] ApplyGrant: Spawn failed for " $ ItemName $ " after retries");
        return;
    }

    Log("[Archipelago] ApplyGrant: spawned " $ ItemName $ " (Id=" $ cardActor.Id $ "), firing Touch");
    cardActor.Touch(h);
    // NOTE: SetCardOwner state writes here are observed by the watcher (CHECK fires
    // for the granted Id), but HP2 has internal logic that periodically resets
    // WizardCards[] and only re-applies its own "official" pickups. Album does not
    // reflect AP-granted cards yet. Open question for M212 Discord: where does HP2
    // store the canonical card-ownership list, and what's the right hook?
}
