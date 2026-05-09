class APIPCActor extends IpDrv.TcpLink;

var APIPCActor PersistentInstance;
var array<string> PendingGrants;
var bool bLoggedGrantDeferral;

static function APIPCActor GetInstance()
{
    if (default.PersistentInstance != None && !default.PersistentInstance.bDeleteMe)
    {
        return default.PersistentInstance;
    }
    return None;
}

event PreBeginPlay()
{
    local IpAddr Addr;

    Super.PreBeginPlay();
    Log("[Archipelago] APIPCActor.PreBeginPlay - connecting to 127.0.0.1:38281");

    default.PersistentInstance = self;
    SetTimer(0.25, true);

    BindPort();
    if (!StringToIpAddr("127.0.0.1", Addr))
    {
        Log("[Archipelago] APIPCActor: StringToIpAddr failed");
        return;
    }
    Addr.Port = 38281;
    if (!Open(Addr))
    {
        Log("[Archipelago] APIPCActor: Open() returned false");
    }
}

event Destroyed()
{
    Log("[Archipelago] APIPCActor.Destroyed");
    if (default.PersistentInstance == self)
    {
        default.PersistentInstance = None;
    }
    Super.Destroyed();
}

event Opened()
{
    Log("[Archipelago] APIPCActor: Opened - sending hello");
    SendText("HELLO" $ Chr(10));
}

event ReceivedText(string Text)
{
    local string trimmed;
    local int idx;

    trimmed = Text;
    idx = InStr(trimmed, Chr(13));
    if (idx >= 0) trimmed = Left(trimmed, idx);
    idx = InStr(trimmed, Chr(10));
    if (idx >= 0) trimmed = Left(trimmed, idx);

    Log("[Archipelago] APIPCActor: ReceivedText: " $ trimmed);

    if (Left(trimmed, 6) == "GRANT ")
    {
        QueueGrant(Mid(trimmed, 6));
    }
}

event Timer()
{
    TryDrainPendingGrants();
}

event Closed()
{
    Log("[Archipelago] APIPCActor: Closed");
}

function SendCheck(int CardId)
{
    SendText("CHECK " $ CardId $ Chr(10));
    Log("[Archipelago] APIPCActor: sent CHECK " $ CardId);
}

function SendCheckSpell(string SpellName)
{
    SendText("CHECK_SPELL " $ SpellName $ Chr(10));
    Log("[Archipelago] APIPCActor: sent CHECK_SPELL " $ SpellName);
}

function SendCheckKeyItem(string KeyItemName)
{
    SendText("CHECK_KEYITEM " $ KeyItemName $ Chr(10));
    Log("[Archipelago] APIPCActor: sent CHECK_KEYITEM " $ KeyItemName);
}

function SendGoalComplete()
{
    SendText("GOAL_COMPLETE" $ Chr(10));
    Log("[Archipelago] APIPCActor: sent GOAL_COMPLETE");
}

function QueueGrant(string ItemName)
{
    PendingGrants[PendingGrants.Length] = ItemName;
    Log("[Archipelago] APIPCActor: queued grant " $ ItemName $ " (pending=" $ string(PendingGrants.Length) $ ")");
    TryDrainPendingGrants();
}

function TryDrainPendingGrants()
{
    local APGameInfo gi;
    local harry readyHarry;
    local string ItemName;

    if (PendingGrants.Length == 0)
    {
        bLoggedGrantDeferral = False;
        return;
    }

    gi = APGameInfo(Level.Game);
    if (gi == None)
    {
        Log("[Archipelago] APIPCActor: cannot drain pending grants - Level.Game is not APGameInfo yet");
        return;
    }

    readyHarry = class'APGameInfo'.static.FindGrantReadyHarry(self);
    if (readyHarry == None)
    {
        if (!bLoggedGrantDeferral)
        {
            Log("[Archipelago] APIPCActor: deferring " $ string(PendingGrants.Length) $ " grant(s) - no ready gameplay harry yet");
            bLoggedGrantDeferral = True;
        }
        return;
    }
    bLoggedGrantDeferral = False;

    while (PendingGrants.Length > 0)
    {
        ItemName = PendingGrants[0];
        PendingGrants.Remove(0, 1);
        Log("[Archipelago] APIPCActor: draining queued grant " $ ItemName $ " to " $ string(readyHarry));
        gi.ApplyGrant(ItemName);
    }
}

defaultproperties
{
    LinkMode=MODE_Text
    ReceiveMode=RMODE_Event
    bGameRelevant=True
    bAlwaysRelevant=True
}
