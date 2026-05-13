class APIPCActor extends IpDrv.TcpLink;

var APIPCActor PersistentInstance;
var array<string> PendingGrants;
var bool bLoggedGrantDeferral;
var float NextGrantDrainTime;
// Stability gate. Bumped to `Level.TimeSeconds + N` whenever any drain check
// defers OR when the watcher first snapshots in a level. Closes the
// 0.25s-tick race where harry transiently flickers through PlayerWalking
// between cutscene segments (or the gap between watcher snapshot and the
// level's first cutscene actor entering Running state — CutScene.uc:411
// Sleep(0.2) before Play). Without this, a single Timer tick of harry in
// PlayerWalking is enough to leak a grant during the intro sequence. See
// `PushDrainStability` for the bump rules.
var float NextGrantDrainEarliest;
const POST_DEFER_STABILITY_SECS = 1.0;
const POST_SNAPSHOT_WARMUP_SECS = 3.0;

// Reconnect state. If the client terminal closes / crashes mid-session, the
// engine fires Closed() and the connection stays dead — previously the mod
// sat silent for the rest of the session and the player had to restart the
// game. Now Closed() schedules a retry; Timer() drives the actual attempts
// with exponential backoff so a never-running client doesn't spin Open()
// hot on every 0.25s tick.
var bool bWantsReconnect;
var float NextReconnectAttempt;
var float ReconnectBackoff;
// ReceivedText delivers raw TCP chunks, not one-line-per-event. When the client
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
    Super.PreBeginPlay();
    Log("[Archipelago] APIPCActor.PreBeginPlay - connecting to 127.0.0.1:38281");

    default.PersistentInstance = self;
    SetTimer(0.25, true);

    BindPort();
    ReconnectBackoff = 1.0;
    bWantsReconnect = True;
    NextReconnectAttempt = Level.TimeSeconds;
    TryReconnect();
}

function TryReconnect()
{
    local IpAddr Addr;

    if (!bWantsReconnect)
    {
        return;
    }
    if (LinkState == STATE_Connected || LinkState == STATE_Connecting)
    {
        return;
    }
    if (Level.TimeSeconds < NextReconnectAttempt)
    {
        return;
    }

    Log("[Archipelago] APIPCActor: attempting connect (backoff=" $ string(ReconnectBackoff) $ "s)");

    if (!StringToIpAddr("127.0.0.1", Addr))
    {
        Log("[Archipelago] APIPCActor: StringToIpAddr failed");
        ScheduleNextReconnect();
        return;
    }
    Addr.Port = 38281;
    if (!Open(Addr))
    {
        Log("[Archipelago] APIPCActor: Open() returned false");
        ScheduleNextReconnect();
        return;
    }
    // Open succeeded. Either Opened() fires (success path — resets backoff)
    // or Closed() fires (failure — bumps backoff). Pre-schedule the next
    // attempt so a stuck STATE_Connecting still eventually retries.
    ScheduleNextReconnect();
}

function ScheduleNextReconnect()
{
    NextReconnectAttempt = Level.TimeSeconds + ReconnectBackoff;
    ReconnectBackoff = FMin(ReconnectBackoff * 2.0, 16.0);
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
    bWantsReconnect = False;
    ReconnectBackoff = 1.0;
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
    else if (Left(line, 5) == "SENT ")
    {
        // PrintJSON-driven "Sent X to Y" toast for items we sent to OTHER
        // slots. Client guarantees `receiving != self.slot` so own-slot
        // items don't double-toast (they go through ReceivedItems → GRANT
        // and produce a "Received X from Y" toast instead). No queueing —
        // toast is purely cosmetic, drop on the floor if no toast actor.
        HandleSent(Mid(line, 5));
    }
}

// Body is `<itemname>|<receiver_slot_name>`. Splits and forwards to the
// HUD toast actor as "Sent <item> to <receiver>".
function HandleSent(string Body)
{
    local string ItemName, Receiver, toastText;
    local int pipeIdx;
    local APHUDToast toast;

    pipeIdx = InStr(Body, "|");
    if (pipeIdx >= 0)
    {
        ItemName = Left(Body, pipeIdx);
        Receiver = Mid(Body, pipeIdx + 1);
    }
    else
    {
        ItemName = Body;
        Receiver = "";
    }

    if (Receiver != "")
    {
        toastText = "Sent " $ ItemName $ " to " $ Receiver;
    }
    else
    {
        toastText = "Sent " $ ItemName;
    }

    Log("[Archipelago] APIPCActor.HandleSent: " $ toastText);

    toast = class'APHUDToast'.static.GetInstance();
    if (toast != None)
    {
        toast.EnqueueToast(toastText);
    }
}

event Timer()
{
    TryReconnect();
    TryDrainPendingGrants();
}

event Closed()
{
    Log("[Archipelago] APIPCActor: Closed - scheduling reconnect");
    // RecvBuffer may hold a partial line from before the disconnect. A
    // reconnected client starts fresh, so any half-line we held is now
    // garbage — drop it.
    RecvBuffer = "";
    bWantsReconnect = True;
    // First retry after Closed: short delay so a graceful client restart
    // reconnects fast. Subsequent failures back off via ScheduleNextReconnect.
    NextReconnectAttempt = Level.TimeSeconds + 1.0;
}

function SendCheck(int CardId)
{
    SendText("CHECK " $ CardId $ Chr(10));
    Log("[Archipelago] APIPCActor: sent CHECK " $ CardId);
}

// CHECK_LOCID carries a raw AP location id (e.g. 5760318) instead of a game-side
// card id (1..101). Used by the secret/star pollers — those locations have no
// game-side numeric handle, so the watcher resolves marker → AP id via the
// generated APLocationRegistry and ships the resulting AP id directly. Client
// passes it straight to LocationChecks without a card-table lookup.
function SendCheckLocationId(int LocationId)
{
    SendText("CHECK_LOCID " $ LocationId $ Chr(10));
    Log("[Archipelago] APIPCActor: sent CHECK_LOCID " $ LocationId);
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

// Pushes the earliest-allowed drain time forward by `seconds` from now. Only
// bumps if the new candidate is later than the current value, so multiple
// simultaneous defer reasons don't compound.
function PushDrainStability(float seconds)
{
    local float candidate;
    candidate = Level.TimeSeconds + seconds;
    if (candidate > NextGrantDrainEarliest)
    {
        NextGrantDrainEarliest = candidate;
    }
}

function TryDrainPendingGrants()
{
    local APGameInfo gi;
    local harry readyHarry;
    local APCardWatcher watcher;
    local string ItemName;
    local string deferReason;

    if (PendingGrants.Length == 0)
    {
        bLoggedGrantDeferral = False;
        return;
    }

    // Stability cooldown — set whenever anything below defers, or by
    // APCardWatcher.Snapshot for the post-snapshot warmup. Silent re-poll
    // (no log spam): the original defer already logged its reason.
    if (Level.TimeSeconds < NextGrantDrainEarliest)
    {
        return;
    }

    gi = APGameInfo(Level.Game);
    if (gi == None)
    {
        Log("[Archipelago] APIPCActor: cannot drain pending grants - Level.Game is not APGameInfo yet");
        PushDrainStability(POST_DEFER_STABILITY_SECS);
        return;
    }

    // Don't drain while the game is paused (in-game menu, save/load). The
    // IsPlayerInPlayableState gate below is the authoritative "Harry is
    // actually playing" check; Level.Pauser is kept as a cheap early-out
    // for the pause-menu case. Level.Pauser is a string in HP2 (UE1
    // retail), not an object ref — compare to "" not None. See
    // HPConsole.uc:752.
    if (Level.Pauser != "")
    {
        if (!bLoggedGrantDeferral)
        {
            Log("[Archipelago] APIPCActor: deferring " $ string(PendingGrants.Length)
                $ " grant(s) - Level.Pauser=" $ Level.Pauser $ " (menu/loading/cutscene)");
            bLoggedGrantDeferral = True;
        }
        PushDrainStability(POST_DEFER_STABILITY_SECS);
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
        PushDrainStability(POST_DEFER_STABILITY_SECS);
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
        PushDrainStability(POST_DEFER_STABILITY_SECS);
        return;
    }

    if (!class'APGameInfo'.static.IsPlayerInPlayableState(readyHarry, deferReason))
    {
        if (!bLoggedGrantDeferral)
        {
            Log("[Archipelago] APIPCActor: deferring " $ string(PendingGrants.Length)
                $ " grant(s) - " $ deferReason);
            bLoggedGrantDeferral = True;
        }
        PushDrainStability(POST_DEFER_STABILITY_SECS);
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
