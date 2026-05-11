class APIPCActor extends IpDrv.TcpLink;

var APIPCActor PersistentInstance;
var array<string> PendingGrants;
var bool bLoggedGrantDeferral;
var float GrantWarmupUntil;
var float NextGrantDrainTime;
// ReceivedText delivers raw TCP chunks, not one-line-per-event. When the sidecar
// burst-writes a resync (e.g. 39 GRANTs back-to-back), TCP coalesces them into
// one or a few packets; UE1 fires ReceivedText with the whole blob. We have to
// split on \n ourselves and carry any trailing partial line across the next
// chunk. Pre-fix this lost ~95% of resync grants and silently truncated the
// queue.
var string RecvBuffer;

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
    // Bumped from 3.0s to 8.0s after save-load playtest showed grants draining
    // while the player was still on the post-load loading screen. The extra
    // headroom plus the Level.Pauser gate in TryDrainPendingGrants keeps the
    // queue cold until the player actually owns input.
    GrantWarmupUntil = Level.TimeSeconds + 8.0;
    if (NextGrantDrainTime < GrantWarmupUntil)
    {
        NextGrantDrainTime = GrantWarmupUntil;
    }
    SendText("HELLO" $ Chr(10));
}

event ReceivedText(string Text)
{
    local int idx, crIdx;
    local string line;

    // Append the new chunk to whatever partial line was carried over from the
    // previous ReceivedText call. Then drain every complete \n-terminated line;
    // leave any trailing tail in RecvBuffer for the next chunk to complete.
    RecvBuffer = RecvBuffer $ Text;

    while (True)
    {
        idx = InStr(RecvBuffer, Chr(10));
        if (idx < 0)
        {
            break;
        }
        line = Left(RecvBuffer, idx);
        RecvBuffer = Mid(RecvBuffer, idx + 1);

        // Strip a trailing \r if the sender used CRLF.
        crIdx = InStr(line, Chr(13));
        if (crIdx >= 0)
        {
            line = Left(line, crIdx);
        }

        if (line == "")
        {
            continue;
        }

        HandleLine(line);
    }
}

function HandleLine(string line)
{
    Log("[Archipelago] APIPCActor: ReceivedText: " $ line);

    if (Left(line, 6) == "GRANT ")
    {
        QueueGrant(Mid(line, 6));
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
    local APCardWatcher watcher;
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

    if (Level.TimeSeconds < GrantWarmupUntil)
    {
        if (!bLoggedGrantDeferral)
        {
            Log("[Archipelago] APIPCActor: deferring " $ string(PendingGrants.Length)
                $ " grant(s) - reconnect warmup active for "
                $ string(GrantWarmupUntil - Level.TimeSeconds) $ " more second(s)");
            bLoggedGrantDeferral = True;
        }
        return;
    }

    // Don't drain while the game is paused (loading screen, menu open,
    // cutscene pause). Without this gate, grants land mid-loading-screen and
    // either apply to a transitional Harry or get clobbered by post-load
    // state restore. Level.Pauser is a string in HP2 (UE1 retail), not an
    // object ref — compare to "" not None. See HPConsole.uc:752.
    if (Level.Pauser != "")
    {
        if (!bLoggedGrantDeferral)
        {
            Log("[Archipelago] APIPCActor: deferring " $ string(PendingGrants.Length)
                $ " grant(s) - Level.Pauser=" $ Level.Pauser $ " (menu/loading/cutscene)");
            bLoggedGrantDeferral = True;
        }
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

    watcher = class'APCardWatcher'.static.GetLatest();
    if (watcher == None || !watcher.bSnapshotted || watcher.HarryRef == None)
    {
        if (!bLoggedGrantDeferral)
        {
            Log("[Archipelago] APIPCActor: deferring " $ string(PendingGrants.Length)
                $ " grant(s) - watcher not snapshotted yet");
            bLoggedGrantDeferral = True;
        }
        return;
    }

    if (Level.TimeSeconds < NextGrantDrainTime)
    {
        return;
    }
    bLoggedGrantDeferral = False;

    ItemName = PendingGrants[0];
    PendingGrants.Remove(0, 1);
    Log("[Archipelago] APIPCActor: draining queued grant " $ ItemName $ " to " $ string(readyHarry));
    gi.ApplyGrant(ItemName);
    NextGrantDrainTime = Level.TimeSeconds + 0.75;
}

defaultproperties
{
    LinkMode=MODE_Text
    ReceiveMode=RMODE_Event
    bGameRelevant=True
    bAlwaysRelevant=True
}
