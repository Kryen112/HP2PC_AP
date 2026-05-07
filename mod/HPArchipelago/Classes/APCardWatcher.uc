class APCardWatcher extends Actor;

const MAX_CARD_ID = 101;

var harry HarryRef;
var StatusItemWizardCards siBronze;
var StatusItemWizardCards siSilver;
var StatusItemWizardCards siGold;
var byte WasOwnedByHarry[102];
var bool bSnapshotted;

event PreBeginPlay()
{
    Super.PreBeginPlay();
    Log("[Archipelago] APCardWatcher.PreBeginPlay - starting timer");
    SetTimer(0.25, true);
}

event Timer()
{
    local int id;
    local APGameInfo gi;

    if (!bSnapshotted)
    {
        if (!Bind())
        {
            return;
        }
        Snapshot();
        bSnapshotted = True;
        return;
    }

    gi = APGameInfo(Level.Game);

    for (id = 1; id <= MAX_CARD_ID; id++)
    {
        if (WasOwnedByHarry[id] == 0 && IsHarryOwned(id))
        {
            WasOwnedByHarry[id] = 1;
            Log("[Archipelago] APCardWatcher: new card owned by Harry, id=" $ id);
            if (gi != None && gi.IPCActor != None)
            {
                gi.IPCActor.SendCheck(id);
            }
        }
    }
}

function bool Bind()
{
    local StatusGroupWizardCards sg;

    if (HarryRef == None)
    {
        foreach AllActors(class'harry', HarryRef)
        {
            break;
        }
    }
    if (HarryRef == None || HarryRef.managerStatus == None)
    {
        return False;
    }

    sg = StatusGroupWizardCards(HarryRef.managerStatus.GetStatusGroup(class'StatusGroupWizardCards'));
    if (sg == None)
    {
        return False;
    }

    siBronze = StatusItemWizardCards(sg.GetStatusItem(class'StatusItemBronzeCards'));
    siSilver = StatusItemWizardCards(sg.GetStatusItem(class'StatusItemSilverCards'));
    siGold   = StatusItemWizardCards(sg.GetStatusItem(class'StatusItemGoldCards'));

    if (siBronze == None || siSilver == None || siGold == None)
    {
        return False;
    }

    Log("[Archipelago] APCardWatcher: bound to Harry's status items");
    return True;
}

function Snapshot()
{
    local int id, ownedCount;

    ownedCount = 0;
    for (id = 1; id <= MAX_CARD_ID; id++)
    {
        if (IsHarryOwned(id))
        {
            WasOwnedByHarry[id] = 1;
            ownedCount++;
        }
    }
    Log("[Archipelago] APCardWatcher: initial snapshot - Harry already owns " $ ownedCount $ " cards");
}

function bool IsHarryOwned(int id)
{
    return siBronze.IsOwnedByHarry(id) || siSilver.IsOwnedByHarry(id) || siGold.IsOwnedByHarry(id);
}

defaultproperties
{
    bHidden=True
}
