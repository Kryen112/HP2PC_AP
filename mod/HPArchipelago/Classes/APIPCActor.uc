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
// One-shot latch on the persistent singleton, set by APCardWatcher when it
// fires GOAL_COMPLETE (the watcher's own WasInEndGame is per-level instance, so
// it can't anchor a cross-connect replay). Lets Opened() re-send GOAL_COMPLETE
// on every bridge connect while it holds, so a goal reached while the client
// was not connected still registers. Cleared by SendNewGame (a genuine new game
// has not goaled). Transient like the link: a fresh process re-arms it, which
// is correct because reaching the ending again re-sets WasInEndGame.
var bool bGoalReached;
// Last level name sent over the bridge (Caps form of Level.Outer.Name). The
// singleton persists across level loads, so a (re)connect can replay it: the
// tracker follows the player to the current map even if the bridge was down
// when the level loaded.
var string CurrentLevelName;
var bool bLoggedGrantDeferral;
var float NextGrantDrainTime;
// Stability gate. Bumped to `Level.TimeSeconds + N` whenever any drain check
// defers OR when the watcher first snapshots in a level. Closes the
// 0.25s-tick race where harry transiently flickers through PlayerWalking
// between cutscene segments (or the gap between watcher snapshot and the
// level's first cutscene actor entering Running state, CutScene.uc:411
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
// Recurring "not connected" reminder. Counts Timer ticks (0.25s each) while the
// link is not STATE_Connected; at NOT_CONNECTED_TOAST_TICKS it fires a toast and
// resets, so a repeating reminder shows every ~10s. Reset to 0 the moment the
// link connects, so a normal fast connect never toasts. Tick-counted (not
// Level.TimeSeconds) so it survives the per-level clock reset across travel.
// Hop-1 only: this is the mod's own TcpLink state to the client, not the
// client's link to the AP server.
var int NotConnectedToastTicks;
const NOT_CONNECTED_TOAST_TICKS = 40;
// ReceivedText delivers raw TCP chunks, not one-line-per-event. When the client
// burst-writes a resync (e.g. 39 GRANTs back-to-back), TCP coalesces them into
// one or a few packets; UE1 fires ReceivedText with the whole blob. We have to
// split on \n ourselves and carry any trailing partial line across the next
// chunk. Without this, a burst loses most resync grants and silently
// truncates the queue.
var string RecvBuffer;

// One-time startup safety save. APCardWatcher drives the trigger; these
// flags are owned by the persistent singleton so they survive level
// transitions and fire exactly once per process. The player only needs the
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
// harry + StatusManager being readable. Every save-load and level/area
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

// Drain-pass save tracker. The drain processes one queued item per Timer
// tick (0.5s spacing); a "pass" is one contiguous run from the queue first
// going non-empty until it next empties. At end-of-pass the drain fires a
// single SaveGame iff the pass moved >1 item OR included any high-stakes
// item (spell / key item / blocker key / equipment / card). A 1-item filler
// pass intentionally skips the save. Bean / ingredient / frog / trap have
// no durability contract. Counters reset on death rising-edge (APCardWatcher)
// so a post-revive resumed drain starts a clean pass.
var int DrainPassItemCount;
var byte bDrainPassHadHighStakes;

// Deferred APPLIED acks. High-stakes drains push their AP index here instead
// of acking immediately; the end-of-pass SaveGame flushes the buffer. A death
// between apply and save discards the buffer locally and fires DRAIN_ROLLBACK
// on the falling edge so the client clears the unacked indices from
// sent_this_session and re-forwards them. The post-reload drain then re-applies
// them durably. Without the defer, server-acked items applied between apply and
// save are lost on a death-revert. Filler (beans, ingredients, frog, traps)
// ignores the buffer and acks immediately.
var array<int> PendingApplyAcks;

// Per-drain-tick flag. APGameInfo.MarkGrantAsHighStakes sets it to 1; the
// drain reads it after ApplyGrant returns to decide whether the current item
// needs the deferred-ack path (high-stakes) or an immediate ack (filler/trap),
// and to record the pass as high-stakes for the end-of-pass save decision.
// Reset to 0 by the drain before every ApplyGrant call.
var byte bLastGrantWasHighStakes;

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
    Log("[Archipelago] APIPCActor.PreBeginPlay - connecting to 127.0.0.1:42779");

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
    // Off the Archipelago server default (38281) so a local AP server can't hold
    // the port and strand the game. Must match Client.py GAME_TCP_PORT.
    Addr.Port = 42779;
    if (!Open(Addr))
    {
        Log("[Archipelago] APIPCActor: Open() returned false");
        ScheduleNextReconnect();
        return;
    }
    // Open succeeded. Either Opened() fires (success path, resets backoff)
    // or Closed() fires (failure, bumps backoff). Pre-schedule the next
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
    // RingLink: a (re)connect is a boundary. Re-snapshot the baseline on
    // the next playable tick and drop any deferred remote delta so it can't
    // apply against a count that moved while the link was down.
    bBaselineValid = False;
    PendingRingDelta = 0;
    SendText("HELLO" $ Chr(10));
    // Replay locally-collected checks so any fired while the bridge was down
    // (client launched after a pickup, or client restarted) reaches AP.
    SendCheckedOut();
    // Same idea for the goal: if the player reached the ending while the bridge
    // was down, re-fire GOAL_COMPLETE on connect. Client dedupes via
    // finished_game, so a replay after the goal already registered is a no-op.
    if (bGoalReached)
    {
        SendGoalComplete();
    }
    // Replay the current map so the tracker can follow the player to it even
    // if this level loaded while the bridge was down.
    if (CurrentLevelName != "")
    {
        SendText("LEVEL " $ CurrentLevelName $ Chr(10));
        Log("[Archipelago] APIPCActor: replayed LEVEL " $ CurrentLevelName);
    }
}

// True only while the TcpLink to the client is established. Used to gate the
// one-shot NEWGAME signal so a fire into a down link does not consume the latch.
function bool IsLinkConnected()
{
    return LinkState == STATE_Connected;
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

// Match a command prefix on an IPC line. The prefix carries its own trailing
// space, so callers never hand-count its length. On a match, returns True and
// sets `rest` to the payload after the prefix; otherwise returns False and leaves
// `rest` untouched (so an earlier non-matching arm in the dispatch chain never
// clobbers a later arm's payload).
function bool MatchCmd(string line, string prefix, out string rest)
{
    if (Left(line, Len(prefix)) != prefix)
        return False;
    rest = Mid(line, Len(prefix));
    return True;
}

function HandleLine(string line)
{
    local APCardWatcher w;
    local APMorphRegistry mr;
    local string rest;
    local int sp;

    Log("[Archipelago] APIPCActor: ReceivedText: " $ line);

    if (MatchCmd(line, "GRANT ", rest))
    {
        // Wire form: `GRANT <apIndex> <payload>`. Split on the first space
        // after "GRANT ". A malformed line (no space) still applies, with
        // index -1 so the drain skips the APPLIED ack (item lands; ledger
        // just doesn't record it, graceful degradation, never a hang).
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
    else if (MatchCmd(line, "SENT ", rest))
    {
        // PrintJSON-driven "Sent X to Y" toast for items we sent to OTHER
        // slots. Client guarantees `receiving != self.slot` so own-slot
        // items don't double-toast (they go through ReceivedItems → GRANT
        // and produce a "Received X from Y" toast instead). No queueing,
        // toast is purely cosmetic, drop on the floor if no toast actor.
        HandleSent(rest);
    }
    else if (MatchCmd(line, "TOAST ", rest))
    {
        // Generic cosmetic toast in HP2's yellow system voice: DeathLink out,
        // AP server disconnect, randomizer-applied notices. Text is the full
        // literal formatted client-side. Drop on the floor if no toast actor.
        HandleToast(rest, 0);
    }
    else if (MatchCmd(line, "TOASTW ", rest))
    {
        // White lifecycle toast: another slot joined/left/finished, inbound
        // DeathLink. Mirrors how AP clients render these in neutral text.
        HandleToast(rest, 1);
    }
    else if (MatchCmd(line, "GOALCFG ", rest))
    {
        // Open castle Great Hall key thresholds from the apworld slot_data, as
        // "cards,spells,levels,duels,quidditch,mask". Sticky class-default on
        // the watcher (mirrors bOpenCastleMode); resent every HELLO so a fresh
        // launch / reconnect re-arms it. Idempotent.
        class'APGoalTracker'.static.SetGoalConfigCSV(rest);
    }
    else if (MatchCmd(line, "TRADECFG ", rest))
    {
        // Tradersanity price mode from the apworld slot_data, as a single
        // int (0 off / 1 vanilla / 2 random / 3 low). Sticky class-default
        // on the watcher (mirrors GOALCFG); resent every HELLO. Idempotent.
        class'APVendorController'.static.SetTradersanityMode(int(rest));
    }
    else if (MatchCmd(line, "TRADERPRICES ", rest))
    {
        // Per-vendor Tradersanity price factors pre-rolled in the apworld
        // from the seed, as `locId:factor,locId:factor,...` (factor = byte
        // 0..255). Sticky class-default on the watcher (mirrors TRADECFG);
        // resent every HELLO. The mod blends the factor into the active
        // price range so a vendor's AP-check price is fixed for the seed
        // across level transitions AND save/exit, instead of re-rolling on
        // every level entry.
        class'APVendorController'.static.SetTraderRolledFactors(rest);
    }
    else if (MatchCmd(line, "SKIP_VENDOR_VOICES ", rest))
    {
        // Silence all in-trade vendor voice cues by zeroing each vendor's
        // VendorDialog string ids. DoCutTalk's empty-dialog branch fires the
        // cue immediately so the trade flows without audio. Sticky byte on the
        // watcher; resent every HELLO. The watcher re-applies the silence on
        // every Snapshot so a level change picks up the right state.
        class'APVendorController'.static.SetSkipVendorVoices(byte(int(rest)));
    }
    else if (MatchCmd(line, "QUIDDITCH_UPGRADES ", rest))
    {
        // Gates whether Fred (Nimbus 2001) and George (Quidditch Armour) get
        // the Tradersanity icon / banner / hint. Those two AP locations only
        // exist when the seed has enable_quidditch_upgrades on. Sticky byte
        // on the watcher; resent every HELLO.
        class'APVendorController'.static.SetQuidditchUpgrades(byte(int(rest)));
    }
    else if (MatchCmd(line, "RUNNING_LOGIC ", rest))
    {
        // Running-in-logic flag from the apworld slot_data: when 1 the seed put
        // the Running logic flag in logic, so shift-to-run is made free (no bean
        // drain, no >0-bean gate) to keep that assumption sound. Sticky byte on
        // the watcher; resent every HELLO.
        class'APSprintController'.static.SetAllowRunningLogic(byte(int(rest)));
    }
    else if (MatchCmd(line, "CONTAINERSANITY ", rest))
    {
        // containersanity option from slot_data. When 1, the watcher swaps/
        // injects the bean-container AP tokens per level. Sticky byte; resent
        // every HELLO.
        class'APContainerManager'.static.SetContainersanity(byte(int(rest)));
    }
    else if (MatchCmd(line, "HINT ", rest))
    {
        // Tradersanity vendor hint payload: "HINT <locId> <item_name>".
        // Cached per-slot on APVendorController.TraderHintItemName so the in-trade
        // label can show the actual item name instead of generic "Archipelago
        // Item". Apworld sends one HINT per Tradersanity vendor location
        // after the scout response resolves, when hint-on-open is enabled.
        HandleHint(rest);
    }
    else if (MatchCmd(line, "CONNECTED ", rest))
    {
        // AP server address for the startup "Connected to host:port" toast,
        // client-formatted (scheme stripped). Sticky class-default on the
        // watcher (mirrors GOALCFG / TRADECFG); resent every HELLO. The toast
        // fire/arm is owned by APCardWatcher (Timer + .usa-restore re-arm),
        // so this line only records the address, idempotent on resend.
        class'APStartupFeedback'.static.SetConnectedAddress(rest);
    }
    else if (MatchCmd(line, "MODE ", rest))
    {
        // The seed's declared game_mode from apworld slot_data (sticky
        // class-default on the watcher; resent every HELLO). Recorded in BOTH
        // modes as a positive signal so the watcher can compare it against its
        // own install probe (the MGBingo package) and warn on a mismatch.
        // "open_castle" additionally latches bOpenCastleMode (a late belt
        // alongside the durable DLO probe); "MODE vanilla" only records the
        // declared mode, it never clears bOpenCastleMode (one-way invariant).
        class'APModeDetector'.static.SetSeedDeclaredMode(rest);
        if (rest == "open_castle")
        {
            class'APModeDetector'.static.EnterOpenCastleMode("IPC MODE open_castle");
        }
    }
    else if (MatchCmd(line, "RESYNC_SPELLS ", rest))
    {
        // Durable spell-grant resync from the apworld client, as a comma-
        // separated list of AP item names this slot has ever received (sourced
        // from the AP-Data-Storage `HP2PC_AP:granted_spells:{team}:{slot}` key).
        // Re-asserts default.APGrantedSpell[] AND re-adds each spell to the live
        // spellbook so a save-load that dropped the spell class ref recovers.
        // Sticky + idempotent mod-side; resent every HELLO and every Connected.
        class'APCardWatcher'.static.ApplyResyncSpells(rest);
    }
    else if (line == "RESYNC_SPELLS")
    {
        // Empty-list form (no spells received yet). Still opens the revert
        // wipe gate so vanilla-engine F/L/A get correctly reverted for a slot
        // that hasn't yet been granted any starters.
        class'APCardWatcher'.static.ApplyResyncSpells("");
    }
    else if (MatchCmd(line, "RESYNC_BLOCKERKEYS ", rest))
    {
        // Durable bookcase-blocker-key resync. Re-asserts
        // default.APGrantedBlockerKey[] AND destroys any matching live bookcase
        // blocker in the current level, so a cold load that wiped the compiled
        // class-defaults is not soft-locked (the client's consumed-indices
        // ledger would otherwise block GRANT replay for already-applied keys).
        // Sent every Connected + HELLO. Covers both modes (open castle: per-key
        // blocker; vanilla: cumulative chain + standalone Duelling/Quidditch).
        class'APCardWatcher'.static.ApplyResyncBlockerKeys(rest);
    }
    else if (line == "RESYNC_BLOCKERKEYS")
    {
        // Empty-list form (no blocker keys received yet). No state change;
        // mirrors RESYNC_SPELLS's bare form so the wire is symmetric.
        class'APCardWatcher'.static.ApplyResyncBlockerKeys("");
    }
    else if (MatchCmd(line, "RESYNC_KEYITEMS ", rest))
    {
        // Potion-key-item resync (Boomslang/Bicorn/BitOGoyle). Always empty
        // today; the three are not AP items. Wired so future randomization of
        // any of them inherits save-load survivability without further mod work.
        class'APCardWatcher'.static.ApplyResyncKeyItems(rest);
    }
    else if (line == "RESYNC_KEYITEMS")
    {
        class'APCardWatcher'.static.ApplyResyncKeyItems("");
    }
    else if (MatchCmd(line, "RESYNC_CARDS ", rest))
    {
        // Durable wizard-card resync. Re-stamps default.APGrantedCard[] AND
        // re-asserts CardOwner_Harry for any received card the live folio is
        // missing, so a save-load / death-reload that dropped a card (the
        // consumed-indices ledger would otherwise block GRANT replay) is healed.
        // Payload is the card UScript class names, comma-separated. Sent every
        // Connected + HELLO. Cards have no .usa-backed store, so this is their
        // only save-load survivability (mirrors RESYNC_SPELLS / _BLOCKERKEYS).
        class'APCardWatcher'.static.ApplyResyncCards(rest);
    }
    else if (line == "RESYNC_CARDS")
    {
        // Empty-list form (no cards received yet). No state change; mirrors the
        // bare RESYNC_SPELLS / RESYNC_BLOCKERKEYS forms so the wire is symmetric.
        class'APCardWatcher'.static.ApplyResyncCards("");
    }
    else if (MatchCmd(line, "RESYNC_BEANROOM ", rest))
    {
        // Open-castle bean-room ledger restored from AP data storage on connect
        // / HELLO. Merges dispensers + floor-collected (set, never clear) and
        // restores dropped-bean positions on a cold load. Sticky + idempotent.
        class'APBeanRoom'.static.ApplyResyncBeanRoom(rest);
    }
    else if (line == "RESYNC_BEANROOM")
    {
        // Empty-list form (nothing persisted yet). No-op; keeps the wire symmetric.
        class'APBeanRoom'.static.ApplyResyncBeanRoom("");
    }
    else if (MatchCmd(line, "CHECKED ", rest))
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
        class'APCardWatcher'.static.SetCheckedLocationsCSV(rest);
        w = class'APCardWatcher'.static.GetLatest();
        if (w != None)
        {
            w.ReSweepCheckedChests();
        }
    }
    else if (MatchCmd(line, "APPEARANCE ", rest))
    {
        // #3 per-location appearance table from the client, as
        // "apId:code,apId:code,…" (full AP location ids). Sticky class-default
        // on APMorphRegistry (mirrors GOALCFG); resent every HELLO. Sweep the live
        // registry so an async mid-level arrival converges within a tick.
        class'APMorphRegistry'.static.SetAppearanceCSV(rest);
        mr = class'APMorphRegistry'.static.GetInstance(self);
        if (mr != None)
        {
            mr.RestampMarkerAppearance();
        }
    }
    else if (MatchCmd(line, "RINGIN ", rest))
    {
        // Net remote RingLink delta. Accumulate, order is irrelevant, only
        // the sum matters. Applied by TickRingLink on the next playable tick.
        PendingRingDelta += int(rest);
        Log("[Archipelago] APIPCActor: RINGIN " $ rest $ " (PendingRingDelta=" $ string(PendingRingDelta) $ ")");
    }
    else if (line == "DEATHLINK")
    {
        // A linked player died. The IPC actor has no Harry ref or state
        // gating, so just arm the class-default flag on the watcher (mirrors
        // GOALCFG); APCardWatcher.ScanDeathLink applies the kill on the next
        // playable tick and owns the loop-prevention latch.
        class'APCardWatcher'.static.SetPendingDeathLink();
    }
    else if (MatchCmd(line, "TRAPLINK ", rest))
    {
        // Inbound TrapLink trap from another slot. Reuse the grant pipeline as
        // an index-less grant (apIndex -1): the drain's playable-state gating
        // delivers it through ApplyGrant -> TryApplyTrap once Harry is in
        // control, and the -1 index makes SendApplied skip the ack so it never
        // enters the durable ledger (a linked trap is transient, fire-once, no
        // replay). Body is `<trapname>|<source_player>`, so ApplyGrant's toast
        // reads "<trap> from <source>".
        QueueGrant(rest, -1);
    }
}

// Body is `<itemname>|<receiver_slot_name>`. Splits and forwards to the
// HUD toast actor as "Sent <item> to <receiver>".
// HINT body is `<locId> <item_name>`. Splits on the first space and forwards
// to APVendorController.SetVendorHintItemName for the in-trade label to read.
// item_name may contain spaces (e.g. "Cloak of Invisibility"), so Mid past
// the first space is the full remainder.
function HandleHint(string Body)
{
    local int spaceIdx, locId;
    local string itemName;

    spaceIdx = InStr(Body, " ");
    if (spaceIdx <= 0)
    {
        Log("[Archipelago] APIPCActor.HandleHint: malformed body '" $ Body $ "'");
        return;
    }
    locId = int(Left(Body, spaceIdx));
    itemName = Mid(Body, spaceIdx + 1);
    if (locId <= 0 || itemName == "") return;

    class'APVendorController'.static.SetVendorHintItemName(locId, itemName);
}

// `code` is the toast colour: 0 yellow (system), 1 white (lifecycle).
// When no live toast exists (the gap between a level tearing down and the next
// level's toast spawning), buffer the line on the toast class default instead of
// dropping it, so the next level replays it. Matters for a lifecycle line that
// lands mid-load.
function HandleToast(string Body, optional byte code)
{
    local APHUDToast toast;

    if (Body == "") return;
    toast = class'APHUDToast'.static.GetInstance();
    if (toast != None)
    {
        toast.EnqueuePlainToast(Body, code);
    }
    else
    {
        class'APHUDToast'.static.BufferPlainRecord(Body, code);
    }
}

// Body is the client-built colourised segment record for an item we sent to
// another slot. EnqueueSegmentToast parses it into the toast's segment pool.
// The "we sent X to Y" record is a server round trip (CHECKEDOUT -> AP ItemSend
// -> SENT) that for a level-complete check routinely lands during the loading
// gap with no live toast; buffer it for the next level rather than drop it.
function HandleSent(string Body)
{
    local APHUDToast toast;

    if (Body == "") return;
    Log("[Archipelago] APIPCActor.HandleSent: segrecord len " $ Len(Body));
    toast = class'APHUDToast'.static.GetInstance();
    if (toast != None)
    {
        toast.EnqueueSegmentToast(Body);
    }
    else
    {
        class'APHUDToast'.static.BufferSegmentRecord(Body);
    }
}

event Timer()
{
    TryReconnect();
    TryDrainPendingGrants();
    TickRingLink();
    TickNotConnectedToast();
}

// Recurring reminder while the IPC link to the client is down. Hop-1 only: keyed
// on this actor's own TcpLink state, not on the client's link to the AP server,
// so it stops the moment the mod reaches the client even if AP itself is down
// (the client pushes its own one-shot "Disconnected from AP server" toast for
// that case). GetInstance() is None before a toast actor exists and EnqueueToast
// no-ops, and toasts only render in HUD states, so this is silent at the title
// screen / menus / loading and shows once the player is in-game.
function TickNotConnectedToast()
{
    local APHUDToast toast;

    if (LinkState == STATE_Connected)
    {
        NotConnectedToastTicks = 0;
        return;
    }

    NotConnectedToastTicks++;
    if (NotConnectedToastTicks < NOT_CONNECTED_TOAST_TICKS)
    {
        return;
    }
    NotConnectedToastTicks = 0;

    toast = class'APHUDToast'.static.GetInstance();
    if (toast != None)
    {
        toast.EnqueueToast("Not connected to Archipelago. Is the client running?");
    }
}

// RingLink poll + drain. The poll diffs whenever harry + StatusManager
// are readable, NOT gated on IsPlayerInPlayableState, because a vendor
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
        // No readable harry/StatusManager, the load gap every save-load
        // and level/area transition passes through. Re-snapshot the
        // baseline on the next readable tick so the load's bean jump is
        // absorbed and never broadcast, and drop any pending remote delta
        // so a delta that arrived just before the load can't apply against
        // the post-load total. Beans are filler, a dropped inbound delta
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
    // delta is never applied mid-cutscene / mid-vendor. It stays deferred
    // in PendingRingDelta until safe. bAllowInGameMenu=True: a bean apply
    // is pure data, safe with the pause menu open (unlike GRANT drain).
    if (PendingRingDelta != 0
        && class'APGameInfo'.static.IsPlayerInPlayableState(h, deferReason, true))
    {
        // Local clamp at zero so beans never display negative or break
        // vendor affordability (belt-and-suspenders: StatusItem.SetCount
        // already floors at 0). We still broadcast our own true deltas
        // unclamped, only what we apply from inbound is clamped.
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
// read truth so the next poll diff is zero. This is the linchpin that
// kills the feedback loop and self-heals if AddBeans clamps. Every
// non-organic bean mutation must route through here: AP-granted bean filler
// (APGameInfo.ApplyGrant) and the #9 Bean Thief trap. Organic pickups /
// vendor spend must NOT. They are exactly what RingLink broadcasts.
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
    // garbage, drop it.
    RecvBuffer = "";
    bWantsReconnect = True;
    // First retry after Closed: short delay so a graceful client restart
    // reconnects fast. Subsequent failures back off via ScheduleNextReconnect.
    NextReconnectAttempt = Level.TimeSeconds + 1.0;
}

function SendCheck(int CardId)
{
    // SendText is a silent no-op on a non-Connected link, so a fire into a down
    // or mid-connect link would log a false "sent". Log it as deferred instead;
    // the caller still latches the dedup, so the next (re)connect SendCheckedOut
    // replays it to AP.
    if (!IsLinkConnected())
    {
        Log("[Archipelago] APIPCActor: CHECK " $ CardId $ " deferred (link down) - replayed on reconnect");
        return;
    }
    SendText("CHECK " $ CardId $ Chr(10));
    Log("[Archipelago] APIPCActor: sent CHECK " $ CardId);
}

// CHECK_LOCID carries a raw AP location id (e.g. 5760318) instead of a game-side
// card id (1..101). Used by the secret/star pollers; those locations have no
// game-side numeric handle, so the watcher resolves marker → AP id via the
// generated APLocationRegistry and ships the resulting AP id directly. Client
// passes it straight to LocationChecks without a card-table lookup.
function SendCheckLocationId(int LocationId)
{
    // See SendCheck: a down-link SendText silently drops, so log deferred (not
    // "sent"). The caller's NonCardLocationChecked latch keeps the id in the
    // checked-out ledger, so the next (re)connect SendCheckedOut replays it.
    if (!IsLinkConnected())
    {
        Log("[Archipelago] APIPCActor: CHECK_LOCID " $ LocationId $ " deferred (link down) - replayed on reconnect");
        return;
    }
    SendText("CHECK_LOCID " $ LocationId $ Chr(10));
    Log("[Archipelago] APIPCActor: sent CHECK_LOCID " $ LocationId);
}

function SendCheckSpell(string SpellName)
{
    SendText("CHECK_SPELL " $ SpellName $ Chr(10));
    Log("[Archipelago] APIPCActor: sent CHECK_SPELL " $ SpellName);
}

// Current map the player is in (Caps form of Level.Outer.Name). The tracker
// uses it to switch to the matching map tab. Remembered on the singleton so
// Opened() can replay it after a (re)connect. Strip CR/LF so a map name can
// never split the newline-delimited wire.
function SendLevel(string LevelName)
{
    local string clean;

    clean = StripNewlines(LevelName);
    if (clean == "") return;
    CurrentLevelName = clean;
    SendText("LEVEL " $ clean $ Chr(10));
    Log("[Archipelago] APIPCActor: sent LEVEL " $ clean);
}

// Strip every CR/LF from a payload so a SAY line cannot be split across
// frames or truncate the newline-delimited wire. There is no Repl helper
// in this class, InStr/Left/Mid loop, the same idiom ReceivedText uses
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

// Tradersanity hint-on-open: the player engaged a Tradersanity vendor's
// dialogue. Client publishes a broadcast hint for that vendor's AP location
// (deduped per-seed in Data Storage). No-op when the client side has the
// option disabled.
function SendVendorOpened(int LocationId)
{
    SendText("VENDOR_OPENED " $ LocationId $ Chr(10));
    Log("[Archipelago] APIPCActor: sent VENDOR_OPENED " $ LocationId);
}

function SendGoalComplete()
{
    SendText("GOAL_COMPLETE" $ Chr(10));
    Log("[Archipelago] APIPCActor: sent GOAL_COMPLETE");
}

// Push the open-castle bean-room ledger to the client to persist in AP data
// storage (the only store that survives a restart here). Sent when the player
// leaves the bean room. Payload is APBeanRoom.BuildBeanRoomState's flat list.
function SendBeanRoomState(string payload)
{
    SendText("BEANSTATE " $ payload $ Chr(10));
    Log("[Archipelago] APIPCActor: sent BEANSTATE (len " $ Len(payload) $ ")");
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
    // applied twice. ApIndex < 0 is the malformed-wire sentinel, never dedupe
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
// means the GRANT wire was malformed (no index), skip the ack.
function SendApplied(int idx)
{
    if (idx < 0)
    {
        return;
    }
    SendText("APPLIED " $ idx $ Chr(10));
    Log("[Archipelago] APIPCActor: sent APPLIED " $ idx);
}

// Flush every buffered APPLIED ack to the client. Called by the drain right
// after the end-of-pass h.SaveGame() so acks only persist once the game has
// durably captured the items they correspond to.
function FlushApplyAcks()
{
    local int i, n;

    n = PendingApplyAcks.Length;
    if (n == 0) return;
    Log("[Archipelago] APIPCActor.FlushApplyAcks: flushing " $ string(n) $ " ack(s) after SaveGame");
    for (i = 0; i < n; i++)
    {
        SendApplied(PendingApplyAcks[i]);
    }
    // Use Remove (canonical UScript clear) instead of `.Length = 0`. The
    // property-setter form works on most UScript variants but is not used
    // anywhere else in vanilla or this mod, and a buggy resize would leave
    // a subsequent `arr[arr.Length] = x` append accessing a freed buffer.
    PendingApplyAcks.Remove(0, n);
}

// One-shot-per-new-game NEWGAME signal. Called by APCardWatcher when it
// observes iGameState 0 (a genuine new game, both vanilla and open castle). The
// client wipes its durable ledger so the fresh playthrough re-receives every
// item. Latch lives on this persistent singleton; the watcher re-arms it once
// iGameState climbs > 0.
function SendNewGame()
{
    // A genuine new game has not reached the ending; drop the goal-replay latch
    // so a goal from a prior playthrough in this process isn't re-fired.
    bGoalReached = False;
    SendText("NEWGAME" $ Chr(10));
    Log("[Archipelago] APIPCActor: sent NEWGAME (iGameState 0 - genuine new game)");
}

// On (re)connect, replay the mod's locally-collected checks to the client (the
// inverse of the CHECKED resync the client sends us). Covers checks fired into
// a down bridge: the client launched after the pickup, or restarted
// mid-session. The client forwards any the AP server is missing; empty payload
// (nothing collected yet) is suppressed so the client sees no line. Reconnect is
// the only replay trigger: on a live link each pickup ships its own CHECK_LOCID,
// so there is no periodic resend of the full set.
function SendCheckedOut()
{
    local string chunk;
    local int cursor, nLines;

    // One line per chunk. The full id list outgrows the per-line TcpLink
    // transmit limit, and an over-length SendText truncates mid-id and corrupts
    // the next IPC line, so NextCheckedOutChunk hands back sub-limit pieces. The
    // client treats each CHECKEDOUT line as additive, so N lines = one snapshot.
    cursor = 1;
    nLines = 0;
    while (class'APCardWatcher'.static.NextCheckedOutChunk(cursor, chunk))
    {
        if (chunk != "")
        {
            SendText("CHECKEDOUT " $ chunk $ Chr(10));
            nLines++;
        }
    }
    if (nLines == 0)
    {
        return;
    }
    Log("[Archipelago] APIPCActor: sent CHECKEDOUT (" $ string(nLines) $ " chunk(s))");
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

    // Hold the drain while Harry is dying / reloading from Save0. Applying an
    // item between rising-edge stateDead and post-reload PlayerWalking would
    // be reverted by the LoadGame, but the APPLIED buffer flush at the next
    // save would still mark it consumed on the server, exactly the bug the
    // defer + DRAIN_ROLLBACK pair is fixing. The watcher clears bWasDead on
    // the falling edge once the post-reload PlayerWalking arrives.
    if (class'APCardWatcher'.default.bWasDead == 1)
    {
        return;
    }

    // Stability cooldown. Set whenever anything below defers, or by
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
    // HP2's in-game menu does NOT flip Level.Pauser. That case is caught
    // further down by IsPlayerInPlayableState's `menuBook.bIsOpen` check.
    // Level.Pauser is a string in HP2 (UE1 retail), not an object ref,
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
    bLastGrantWasHighStakes = 0;
    gi.ApplyGrant(ItemName);

    // Drain-pass bookkeeping: count items in this pass and remember if any
    // were high-stakes. The end-of-pass save below uses both.
    DrainPassItemCount++;
    if (bLastGrantWasHighStakes == 1)
    {
        bDrainPassHadHighStakes = 1;
    }

    // Routing of the APPLIED ack:
    //   - High-stakes (spell / key item / blocker key / equipment / card):
    //     buffer the idx; the end-of-pass SaveGame flushes the buffer.
    //   - Filler / trap: ack immediately, no buffering. These items have
    //     no durability contract (a death-revert losing a re-grantable
    //     bean / trap is acceptable; high-stakes items are not).
    if (apIdx >= 0)
    {
        if (bLastGrantWasHighStakes == 1)
        {
            PendingApplyAcks[PendingApplyAcks.Length] = apIdx;
        }
        else
        {
            SendApplied(apIdx);
        }
    }

    // End-of-pass save. Fires once the queue is empty AND the pass moved
    // more than one item OR included any high-stakes grant. A 1-item filler
    // pass intentionally skips the save (no durability contract). Resets
    // the counters either way so the next pass starts fresh.
    if (PendingGrants.Length == 0)
    {
        if (DrainPassItemCount > 1 || bDrainPassHadHighStakes == 1)
        {
            Log("[Archipelago] APIPCActor: drain pass complete - SaveGame (count="
                $ string(DrainPassItemCount) $ ", highStakes=" $ string(bDrainPassHadHighStakes) $ ")");
            readyHarry.SaveGame();
            FlushApplyAcks();
        }
        DrainPassItemCount = 0;
        bDrainPassHadHighStakes = 0;
    }

    NextGrantDrainTime = Level.TimeSeconds + 0.5;
}

defaultproperties
{
    LinkMode=MODE_Text
    ReceiveMode=RMODE_Event
    bGameRelevant=True
    bAlwaysRelevant=True
}
