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

// One-time startup safety save. APCardWatcher drives the trigger; these
// flags are owned by the persistent singleton so they survive level
// transitions and fire exactly once per process — the player only needs the
// early-quit safety net once per fresh launch. TcpLink is transient (not
// serialized into the save), so a new launch re-arms them.
// bSawStateBelowGreatHall: set once the watcher reads any gstate below the
// Great Hall arrival state. Only a genuine new game does (it climbs through
// the intro); a load straight into a >=180 save never does, which scopes
// the safety save to new games and skips a redundant re-save every load.
var bool bStartupSafetySaveDone;
var bool bSawStateBelowGreatHall;

// RingLink (#5). The persistent singleton owns the bean baseline so it
// survives level loads. LastBeanBaseline is the last bean count the poll
// diffed against. The poll is deliberately NOT gated on
// IsPlayerInPlayableState: a vendor spend drains beans while harry is
// bKeepStationary (non-playable) and must still be mirrored. It IS gated on
// harry + StatusManager being readable — every save-load and level/area
// transition passes through a no-readable-harry window (the same gap the
// grant drain defers on), and that window alone re-snapshots the baseline
// so the load's bean jump is absorbed, never broadcast. bBaselineValid is
// False until the first readable tick snapshots it. PendingRingDelta
// accumulates inbound RINGIN deltas until a playable tick can apply them;
// order is irrelevant so one int, not a queue.
var int LastBeanBaseline;
var bool bBaselineValid;
var int PendingRingDelta;
// Defensive backstop: a |delta| beyond this is treated as a baseline resync
// (not broadcast) — guards against a save-load fast enough to skip the
// no-readable-harry window from broadcasting a bogus room-wide swing.
const RING_SANITY_CAP = 100000;

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
    // RingLink: a (re)connect is a boundary — re-snapshot the baseline on
    // the next playable tick and drop any deferred remote delta so it can't
    // apply against a count that moved while the link was down.
    bBaselineValid = False;
    PendingRingDelta = 0;
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
    local APCardWatcher w;

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
    else if (Left(line, 8) == "GOALCFG ")
    {
        // Bingo Great Hall key thresholds from the apworld slot_data, as
        // "cards,spells,levels,duels,quidditch,mask". Sticky class-default on
        // the watcher (mirrors bBingoMode); resent every HELLO so a fresh
        // launch / reconnect re-arms it. Idempotent.
        class'APCardWatcher'.static.SetGoalConfigCSV(Mid(line, 8));
    }
    else if (Left(line, 9) == "TRADECFG ")
    {
        // Tradersanity price mode from the apworld slot_data, as a single
        // int (0 off / 1 vanilla / 2 random / 3 low). Sticky class-default
        // on the watcher (mirrors GOALCFG); resent every HELLO. Idempotent.
        class'APCardWatcher'.static.SetTradersanityMode(int(Mid(line, 9)));
    }
    else if (Left(line, 11) == "APPEARANCE ")
    {
        // #3 per-location appearance table from the client, as
        // "apId:code,apId:code,…" (full AP location ids). Sticky class-default
        // on the watcher (mirrors GOALCFG); resent every HELLO. Sweep the live
        // watcher so an async mid-level arrival converges within a tick.
        class'APCardWatcher'.static.SetAppearanceCSV(Mid(line, 11));
        w = class'APCardWatcher'.static.GetLatest();
        if (w != None)
        {
            w.RestampMarkerAppearance();
        }
    }
    else if (Left(line, 7) == "RINGIN ")
    {
        // Net remote RingLink delta. Accumulate — order is irrelevant, only
        // the sum matters. Applied by TickRingLink on the next playable tick.
        PendingRingDelta += int(Mid(line, 7));
        Log("[Archipelago] APIPCActor: RINGIN " $ Mid(line, 7) $ " (PendingRingDelta=" $ string(PendingRingDelta) $ ")");
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
    TickRingLink();
}

// RingLink poll + drain (#5). The poll diffs whenever harry + StatusManager
// are readable — NOT gated on IsPlayerInPlayableState, because a vendor
// spend drains beans while harry is bKeepStationary (non-playable) and must
// still be broadcast. Readability alone is the load discriminator: every
// save-load and level/area transition passes through a window with no
// readable harry (the same gap the grant drain defers on), so that window
// re-snapshots the baseline and the load's bean jump is absorbed, never
// broadcast. The poll runs BEFORE the drain so an organic change in the
// same tick is broadcast, while the remote delta the drain applies resyncs
// the baseline (via MutateBeansNoBroadcast) and is not rebroadcast. The
// drain alone keeps the playable gate so beans are never mutated
// mid-cutscene / mid-vendor.
function TickRingLink()
{
    local harry h;
    local string deferReason;
    local int current, delta, applied;

    h = class'APGameInfo'.static.FindGrantReadyHarry(self);

    if (h == None || h.managerStatus == None)
    {
        // No readable harry/StatusManager — the load gap every save-load
        // and level/area transition passes through. Re-snapshot the
        // baseline on the next readable tick so the load's bean jump is
        // absorbed and never broadcast, and drop any pending remote delta
        // so a delta that arrived just before the load can't apply against
        // the post-load total. Beans are filler — a dropped inbound delta
        // is a one-time small desync, not corruption.
        bBaselineValid = False;
        PendingRingDelta = 0;
        return;
    }

    current = h.managerStatus.GetBeanCount();

    if (!bBaselineValid)
    {
        LastBeanBaseline = current;
        bBaselineValid = True;
    }
    else
    {
        delta = current - LastBeanBaseline;
        if (delta != 0)
        {
            if (delta > RING_SANITY_CAP || delta < -RING_SANITY_CAP)
            {
                Log("[Archipelago] RingLink: implausible bean delta " $ string(delta)
                    $ " - resyncing baseline, not broadcasting");
            }
            else
            {
                SendRingOut(delta);
            }
            LastBeanBaseline = current;
        }
    }

    // Drain accumulated remote delta. Gated on IsPlayerInPlayableState (the
    // laxer poll above only reads beans; this mutates them) so an inbound
    // delta is never applied mid-cutscene / mid-vendor — it stays deferred
    // in PendingRingDelta until safe. bAllowInGameMenu=True: a bean apply
    // is pure data, safe with the pause menu open (unlike GRANT drain).
    if (PendingRingDelta != 0
        && class'APGameInfo'.static.IsPlayerInPlayableState(h, deferReason, true))
    {
        // Local clamp at zero so beans never display negative or break
        // vendor affordability (belt-and-suspenders: StatusItem.SetCount
        // already floors at 0). We still broadcast our own true deltas
        // unclamped — only what we apply from inbound is clamped.
        applied = PendingRingDelta;
        if (applied < -current)
        {
            applied = -current;
        }
        if (applied != 0)
        {
            // No toast: the bean HUD already updates live when the count
            // changes, and a per-delta toast would be spammy.
            MutateBeansNoBroadcast(h, applied);
        }
        PendingRingDelta = 0;
    }
}

// Shared "mutate beans without broadcasting" helper (§6.0). Applies the
// bean change and then immediately resyncs LastBeanBaseline to the freshly
// read truth so the next poll diff is zero — this is the linchpin that
// kills the feedback loop and self-heals if AddBeans clamps. Every
// non-organic bean mutation must route through here: AP-granted bean filler
// (APGameInfo.ApplyGrant) and the #9 Bean Thief trap. Organic pickups /
// vendor spend must NOT — they are exactly what RingLink broadcasts.
function MutateBeansNoBroadcast(harry h, int Delta)
{
    if (h == None || h.managerStatus == None)
    {
        return;
    }
    h.managerStatus.AddBeans(Delta);
    LastBeanBaseline = h.managerStatus.GetBeanCount();
    bBaselineValid = True;
}

function SendRingOut(int Delta)
{
    SendText("RINGOUT " $ Delta $ Chr(10));
    Log("[Archipelago] APIPCActor: sent RINGOUT " $ Delta);
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

    // Don't drain while the engine is paused (HPConsole sets Level.Pauser
    // briefly during e.g. exec-script sleeps; load screens; dev `pause`).
    // Note: HP2's in-game menu does NOT flip Level.Pauser — that case is
    // caught further down by IsPlayerInPlayableState's `menuBook.bIsOpen`
    // check. Level.Pauser is a string in HP2 (UE1 retail), not an object
    // ref — compare to "" not None. See HPConsole.uc:752.
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
