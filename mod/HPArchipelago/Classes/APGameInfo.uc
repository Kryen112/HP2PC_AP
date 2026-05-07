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

function ApplyGrant(string CardName)
{
    local class<WizardCardIcon> cardClass;
    local WizardCardIcon cardActor;
    local harry h;
    local PlayerPawn pp;
    local Vector spawnLoc;
    local int attempt;

    Log("[Archipelago] APGameInfo.ApplyGrant: " $ CardName);

    cardClass = class<WizardCardIcon>(DynamicLoadObject("HGame." $ CardName, class'Class'));
    if (cardClass == None)
    {
        Log("[Archipelago] ApplyGrant: unknown card class HGame." $ CardName);
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
        Log("[Archipelago] ApplyGrant: Spawn failed for " $ CardName $ " after retries");
        return;
    }

    Log("[Archipelago] ApplyGrant: spawned " $ CardName $ " (Id=" $ cardActor.Id $ "), firing Touch");
    cardActor.Touch(h);
    // NOTE: SetCardOwner state writes here are observed by the watcher (CHECK fires
    // for the granted Id), but HP2 has internal logic that periodically resets
    // WizardCards[] and only re-applies its own "official" pickups. Album does not
    // reflect AP-granted cards yet. Open question for M212 Discord: where does HP2
    // store the canonical card-ownership list, and what's the right hook?
}
