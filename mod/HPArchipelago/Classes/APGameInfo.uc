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

    siCard.SetCardOwner(cardClass.default.Id, siCard.ECardOwner.CardOwner_Harry);
    sgCards.RemoveHarryOwnedCardsFromLevel(None);

    Log("[Archipelago] ApplyGrant: granted card " $ ItemName $ " (Id=" $ cardClass.default.Id $ ") via SetCardOwner+RemoveHarryOwnedCardsFromLevel");
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

function ApplyGrant(string ItemName)
{
    local harry h;
    local PlayerPawn pp;

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

    if (TryApplyCard(ItemName, h))
    {
        return;
    }

    Log("[Archipelago] ApplyGrant: unknown item " $ ItemName);
}
