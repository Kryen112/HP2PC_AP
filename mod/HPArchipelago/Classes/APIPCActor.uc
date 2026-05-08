class APIPCActor extends IpDrv.TcpLink;

var APIPCActor PersistentInstance;

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
    local APGameInfo gi;
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
        gi = APGameInfo(Level.Game);
        if (gi != None)
        {
            gi.ApplyGrant(Mid(trimmed, 6));
        }
    }
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

defaultproperties
{
    LinkMode=MODE_Text
    ReceiveMode=RMODE_Event
    bGameRelevant=True
    bAlwaysRelevant=True
}
