class APIPCActor extends IpDrv.TcpLink;

var APIPCActor PersistentInstance;
var array<string> PendingGrants;
// AP ReceivedItems index for each PendingGrants entry, in lockstep (same push
// in QueueGrant, same Remove(0,1) in the drain). On successful apply the drain
// sends `APPLIED <index>` so the client marks it durably consumed in AP Data
// Storage and never re-grants it (the .usa cannot persist mod data on M212,
// so the durable ledger lives in the AP server's Data Storage instead).
var array<int> PendingGrantIndex;
// One-shot-per-new-game latch on the persistent singleton (survives level
// travel; a fresh process re-arms it). Set when NEWGAME is sent on observing
// iGameState 0; APCardWatcher re-arms it (clears) once iGameState climbs > 0,
// so a later genuine new game in the same process signals again.
var bool bNewGameSignalled;
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
// engine fires Closed() and the connection stays dead. Closed() schedules a
// retry; Timer() drives the actual attempts with exponential backoff so a
// never-running client doesn't spin Open() hot on every 0.25s tick.
var bool bWantsReconnect;
var float NextReconnectAttempt;
var float ReconnectBackoff;
// ReceivedText delivers raw TCP chunks, not one-line-per-event. When the client
// burst-writes a resync (e.g. 39 GRANTs back-to-back), TCP coalesces them into
// one or a few packets; UE1 fires ReceivedText with the whole blob. We have to
// split on \n ourselves and carry any trailing partial line across the next
// chunk. Without this, a burst loses most resync grants and silently
// truncates the queue.
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

// RingLink. The persistent singleton owns the bean baseline so it
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
// One-shot gate: skip the next outbound RingLink diff so a LoadGame 0
// autosave revert is absorbed into the baseline instead of broadcast as
// an organic spend.
var byte bSuppressNextRingOutDiff;
// Treat |delta| over this as a save-revert, not a real spend. Sized to
// clear the largest legitimate single-tick bean swing while catching
// every save-revert class.
const RING_SANITY_CAP = 1000;
// Rate-limit outbound DEATH to one broadcast per window so a recurring
// loop cannot spam the room even if every targeted suppressor misses.
var float NextDeathSendTime;
const SEND_DEATH_MIN_INTERVAL_SECS = 5.0;

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
    local string rest;
    local int sp;

    Log("[Archipelago] APIPCActor: ReceivedText: " $ line);

    if (Left(line, 6) == "GRANT ")
    {
        // Wire form: `GRANT <apIndex> <payload>`. Split on the first space
        // after "GRANT ". A malformed line (no space) still applies, with
        // index -1 so the drain skips the APPLIED ack (item lands; ledger
        // just doesn't record it — graceful degradation, never a hang).
        rest = Mid(line, 6);
        sp = InStr(rest, " ");
        if (sp < 0)
        {
            Log("[Archipelago] APIPCActor: malformed GRANT (no index) - " $ rest);
            QueueGrant(rest, -1);
        }
        else
        {
            QueueGrant(Mid(rest, sp + 1), int(Left(rest, sp)));
        }
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
        // Open castle Great Hall key thresholds from the apworld slot_data, as
        // "cards,spells,levels,duels,quidditch,mask". Sticky class-default on
        // the watcher (mirrors bOpenCastleMode); resent every HELLO so a fresh
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
    else if (Left(line, 13) == "TRADERPRICES ")
    {
        // Per-vendor Tradersanity price factors pre-rolled in the apworld
        // from the seed, as `locId:factor,locId:factor,...` (factor = byte
        // 0..255). Sticky class-default on the watcher (mirrors TRADECFG);
        // resent every HELLO. The mod blends the factor into the active
        // price range so a vendor's AP-check price is fixed for the seed
        // across level transitions AND save/exit, instead of re-rolling on
        // every level entry.
        class'APCardWatcher'.static.SetTraderRolledFactors(Mid(line, 13));
    }
    else if (Left(line, 10) == "CONNECTED ")
    {
        // AP server address for the startup "Connected to host:port" toast,
        // client-formatted (scheme stripped). Sticky class-default on the
        // watcher (mirrors GOALCFG / TRADECFG); resent every HELLO. The toast
        // fire/arm is owned by APCardWatcher (Timer + .usa-restore re-arm),
        // so this line only records the address — idempotent on resend.
        class'APCardWatcher'.static.SetConnectedAddress(Mid(line, 10));
    }
    else if (Left(line, 5) == "MODE ")
    {
        // The seed's declared game_mode from apworld slot_data (sticky
        // class-default on the watcher; resent every HELLO). Recorded in BOTH
        // modes as a positive signal so the watcher can compare it against its
        // own install probe (the MGBingo package) and warn on a mismatch.
        // "open_castle" additionally latches bOpenCastleMode (a late belt
        // alongside the durable DLO probe); "MODE vanilla" only records the
        // declared mode — it never clears bOpenCastleMode (one-way invariant).
        class'APCardWatcher'.static.SetSeedDeclaredMode(Mid(line, 5));
        if (Mid(line, 5) == "open_castle")
        {
            class'APCardWatcher'.static.EnterOpenCastleMode("IPC MODE open_castle");
        }
    }
    else if (Left(line, 14) == "RESYNC_SPELLS ")
    {
        // Durable spell-grant resync from the apworld client, as a comma-
        // separated list of AP item names this slot has ever received (sourced
        // from the AP-Data-Storage `HP2PC_AP:granted_spells:{team}:{slot}` key).
        // Re-asserts default.APGrantedSpell[] AND re-adds each spell to the live
        // spellbook so a save-load that dropped the spell class ref recovers.
        // Sticky + idempotent mod-side; resent every HELLO and every Connected.
        class'APCardWatcher'.static.ApplyResyncSpells(Mid(line, 14));
    }
    else if (line == "RESYNC_SPELLS")
    {
        // Empty-list form (no spells received yet). Still opens the revert
        // wipe gate so vanilla-engine F/L/A get correctly reverted for a slot
        // that hasn't yet been granted any starters.
        class'APCardWatcher'.static.ApplyResyncSpells("");
    }
    else if (Left(line, 19) == "RESYNC_BLOCKERKEYS ")
    {
        // Durable bookcase-blocker-key resync. Re-asserts
        // default.APGrantedBlockerKey[] AND destroys any matching live bookcase
        // blocker in the current level, so a cold load that wiped the compiled
        // class-defaults is not soft-locked (the client's consumed-indices
        // ledger would otherwise block GRANT replay for already-applied keys).
        // Sent every Connected + HELLO. Covers both modes (open castle: per-key
        // blocker; vanilla: cumulative chain + standalone Duelling/Quidditch).
        class'APCardWatcher'.static.ApplyResyncBlockerKeys(Mid(line, 19));
    }
    else if (line == "RESYNC_BLOCKERKEYS")
    {
        // Empty-list form (no blocker keys received yet). No state change;
        // mirrors RESYNC_SPELLS's bare form so the wire is symmetric.
        class'APCardWatcher'.static.ApplyResyncBlockerKeys("");
    }
    else if (Left(line, 16) == "RESYNC_KEYITEMS ")
    {
        // Potion-key-item resync (Boomslang/Bicorn/BitOGoyle). Always empty
        // today; the three are not AP items. Wired so future randomization of
        // any of them inherits save-load survivability without further mod work.
        class'APCardWatcher'.static.ApplyResyncKeyItems(Mid(line, 16));
    }
    else if (line == "RESYNC_KEYITEMS")
    {
        class'APCardWatcher'.static.ApplyResyncKeyItems("");
    }
    else if (Left(line, 8) == "CHECKED ")
    {
        // Per-slot checked-locations resync from the client, as a
        // comma-separated list of AP location ids the server already has as
        // checked. Sticky class-default on the watcher (mirrors GOALCFG /
        // APPEARANCE); resent every HELLO so a fresh game launch / reconnect
        // re-stamps LocationChecked[] / NonCardLocationChecked[] (the mod's
        // arrays are class-default = process-lifetime, never restored from
        // the .usa). After stamping, the watcher re-sweeps the live level so
        // chests/markers whose location is already checked bean-swap /
        // destroy immediately instead of waiting for another level transition.
        class'APCardWatcher'.static.SetCheckedLocationsCSV(Mid(line, 8));
        w = class'APCardWatcher'.static.GetLatest();
        if (w != None)
        {
            w.ReSweepCheckedChests();
        }
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
    else if (line == "DEATHLINK")
    {
        // A linked player died. The IPC actor has no Harry ref or state
        // gating, so just arm the class-default flag on the watcher (mirrors
        // GOALCFG); APCardWatcher.ScanDeathLink applies the kill on the next
        // playable tick and owns the loop-prevention latch.
        class'APCardWatcher'.static.SetPendingDeathLink();
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

// RingLink poll + drain. The poll diffs whenever harry + StatusManager
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
            if (bSuppressNextRingOutDiff == 1)
            {
                // One-shot suppressor consumed: re-baseline only, do not broadcast.
                Log("[Archipelago] RingLink: suppressing one-shot diff " $ string(delta)
                    $ " - re-baselining only");
                bSuppressNextRingOutDiff = 0;
            }
            else if (delta > RING_SANITY_CAP || delta < -RING_SANITY_CAP)
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

// Shared "mutate beans without broadcasting" helper. Applies the
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

// Strip every CR/LF from a payload so a SAY line cannot be split across
// frames or truncate the newline-delimited wire. There is no Repl helper
// in this class — InStr/Left/Mid loop, the same idiom ReceivedText uses
// to split incoming lines.
function string StripNewlines(string s)
{
    local int p;

    p = InStr(s, Chr(10));
    while (p >= 0)
    {
        s = Left(s, p) $ Mid(s, p + 1);
        p = InStr(s, Chr(10));
    }
    p = InStr(s, Chr(13));
    while (p >= 0)
    {
        s = Left(s, p) $ Mid(s, p + 1);
        p = InStr(s, Chr(13));
    }
    return s;
}

// ~1/100-on-cast cosmetic chat. The watcher sends a bare ASCII spell name
// only; Python owns all flavor text (unicode/emoticons) and the random
// variant. Strip CR/LF so the gag can't split or truncate the wire frame;
// drop an empty payload. Mirrors SendCheckSpell.
function SendSay(string Msg)
{
    local string clean;

    clean = StripNewlines(Msg);
    if (clean == "") return;
    SendText("SAY " $ clean $ Chr(10));
    Log("[Archipelago] APIPCActor: sent SAY " $ clean);
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

// DeathLink out. Cause is optional flavour; the client gates on the
// DeathLink tag, so an untagged slot makes this a no-op.
function SendDeath(string Cause)
{
    // Level.TimeSeconds resets on travel; a gate more than one window ahead
    // of the current clock must be stale from a previous level.
    if (NextDeathSendTime > Level.TimeSeconds + SEND_DEATH_MIN_INTERVAL_SECS)
    {
        NextDeathSendTime = 0;
    }
    if (Level.TimeSeconds < NextDeathSendTime)
    {
        Log("[Archipelago] APIPCActor.SendDeath: rate-limited (" $ Cause
            $ ") - last send was within " $ string(SEND_DEATH_MIN_INTERVAL_SECS) $ "s");
        return;
    }
    NextDeathSendTime = Level.TimeSeconds + SEND_DEATH_MIN_INTERVAL_SECS;
    SendText("DEATH " $ Cause $ Chr(10));
    Log("[Archipelago] APIPCActor: sent DEATH " $ Cause);
}

function QueueGrant(string ItemName, int ApIndex)
{
    local int i;

    // Dedupe: if this AP index is already queued (not yet drained), drop the
    // duplicate. The client's consumed-index ledger prevents re-sends of
    // already-APPLIED items; this guards the in-flight window (e.g. a HELLO
    // re-forward racing the NEWGAME re-forward) so an index can never be
    // applied twice. ApIndex < 0 is the malformed-wire sentinel — never dedupe
    // those against each other.
    if (ApIndex >= 0)
    {
        for (i = 0; i < PendingGrantIndex.Length; i++)
        {
            if (PendingGrantIndex[i] == ApIndex)
            {
                Log("[Archipelago] APIPCActor: dropping duplicate queued grant apIndex=" $ string(ApIndex) $ " (" $ ItemName $ ")");
                return;
            }
        }
    }

    PendingGrants[PendingGrants.Length] = ItemName;
    PendingGrantIndex[PendingGrantIndex.Length] = ApIndex;
    Log("[Archipelago] APIPCActor: queued grant " $ ItemName $ " (apIndex=" $ string(ApIndex) $ " pending=" $ string(PendingGrants.Length) $ ")");
    TryDrainPendingGrants();
}

// Tell the client an item was applied to the live game so it records the AP
// index in its durable AP-Data-Storage ledger and never re-grants it. idx < 0
// means the GRANT wire was malformed (no index) — skip the ack.
function SendApplied(int idx)
{
    if (idx < 0)
    {
        return;
    }
    SendText("APPLIED " $ idx $ Chr(10));
    Log("[Archipelago] APIPCActor: sent APPLIED " $ idx);
}

// One-shot-per-new-game NEWGAME signal. Called by APCardWatcher when it
// observes iGameState 0 (a genuine new game, both vanilla and open castle). The
// client wipes its durable ledger so the fresh playthrough re-receives every
// item. Latch lives on this persistent singleton; the watcher re-arms it once
// iGameState climbs > 0.
function SendNewGame()
{
    SendText("NEWGAME" $ Chr(10));
    Log("[Archipelago] APIPCActor: sent NEWGAME (iGameState 0 - genuine new game)");
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
    local int apIdx;

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
    // HP2's in-game menu does NOT flip Level.Pauser — that case is caught
    // further down by IsPlayerInPlayableState's `menuBook.bIsOpen` check.
    // Level.Pauser is a string in HP2 (UE1 retail), not an object ref —
    // compare to "" not None. See HPConsole.uc:752.
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
    apIdx = PendingGrantIndex[0];
    PendingGrants.Remove(0, 1);
    PendingGrantIndex.Remove(0, 1);
    Log("[Archipelago] APIPCActor: draining queued grant " $ ItemName $ " (apIndex=" $ string(apIdx) $ ") to " $ string(readyHarry));
    gi.ApplyGrant(ItemName);
    // Past all the playable-state gating above, ApplyGrant has delivered (or
    // idempotently no-op'd an already-owned item) — either way the AP index is
    // accounted for in this slot's playthrough. Ack so the client records it
    // durably and never re-grants it.
    SendApplied(apIdx);
    NextGrantDrainTime = Level.TimeSeconds + 0.5;
}

defaultproperties
{
    LinkMode=MODE_Text
    ReceiveMode=RMODE_Event
    bGameRelevant=True
    bAlwaysRelevant=True
}
