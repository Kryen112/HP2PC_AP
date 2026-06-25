// Per-session / per-level startup AP feedback, driven from the watcher's tick:
// the durable-ledger NEWGAME signal + one-time safety save, and the connection /
// seed-mismatch / goal-unlock toasts. Per-level singleton (GetInstance) so the
// "re-show once per level" toast latches reset with the fresh per-level instance;
// the connection-toast latch + the server address are class-default and persist
// for the process. The watcher passes the few inputs it owns (live harry, the
// at-Snapshot folio-empty sample, WasGoalUnlocked / WasInEndGame) as args, so no
// watcher state is reached back into cross-class.
class APStartupFeedback extends Info;

// The Great Hall arrival story-state (both modes climb to it). The safety save
// fires at/after this; below it scopes the new-game window.
const STARTUP_SAFETY_SAVE_GAMESTATE = 180;
// ~1s delay (in 0.25s ticks) between the first playable tick the AP address is
// known and the connection toast firing, so it does not pop the instant control
// returns.
const CONN_TOAST_DELAY_TICKS = 4;

// Process-wide singleton pointer (class-default). Instance copy kept None for
// save-graph hygiene.
var APStartupFeedback LatestInstance;

// AP server address for the connection toast (set by SetConnectedAddress from the
// CONNECTED IPC line). Class-default + sticky.
var string ConnectedAddress;
// Connection-toast fire latch (class-default, once per process; re-armed on a
// save-load by EnsureFreshToast). bConnToastScheduled + ConnToastTicksLeft run
// the delay countdown.
var byte bConnToastShown;
var byte bConnToastScheduled;
var int ConnToastTicksLeft;
// Seed/install mismatch warning latch. INSTANCE (compiled-0 on each fresh
// per-level instance) so the warning re-shows once per level until the player
// runs the matching install.
var byte bModeMismatchToastShown;
// Open-castle goal-unlock pointer latch. INSTANCE like the mismatch latch, so it
// re-shows once per level until the player reaches the Great Hall and the credits
// fire (WasInEndGame).
var byte bGoalUnlockToastShown;

// Found-or-spawned singleton accessor. Logic-only (no mesh) so runtime spawn is
// safe.
static function APStartupFeedback GetInstance(Actor ctx)
{
    if (default.LatestInstance != None && !default.LatestInstance.bDeleteMe)
        return default.LatestInstance;
    if (ctx == None) return None;
    return ctx.Spawn(class'APStartupFeedback');
}

event PreBeginPlay()
{
    Super.PreBeginPlay();
    LatestInstance = None;
    default.LatestInstance = self;
}

// AP server address for the connection toast (CONNECTED IPC line, client-
// formatted with scheme stripped). Class-default + sticky; idempotent. Does NOT
// touch bConnToastShown - arming/firing is owned by the tick path so a resend of
// the same address on a mid-session HELLO can never re-trigger the toast.
static function SetConnectedAddress(string addr)
{
    if (addr == "") return;
    default.ConnectedAddress = addr;
    Log("[Archipelago] APStartupFeedback.SetConnectedAddress: '" $ default.ConnectedAddress $ "'");
}

// Durable-ledger new-game signal + one-time startup safety save. `bFolioEmpty` is
// the watcher's folio-empty sample taken at Snapshot entry (before the AP
// re-assert): it reads empty only on a genuine new game, separating a real new
// game from the transient iGameState==0 window a freshly-loaded save shows before
// harry.SetGameState applies its real value. Without that guard, firing NEWGAME on
// a loaded game would wipe the ledger and re-grant the whole item history
// (re-adding additive filler). The safety save mirrors vanilla's SmartStart save
// that the open-castle flow can bypass: once the player holds control at/after the
// Great Hall state, write the autosave once per process.
function EmitStartupSignals(harry h, bool bFolioEmpty, APIPCActor ipc)
{
    local harry saveHarry;
    local string deferReason;

    if (ipc != None && h.iGameState < STARTUP_SAFETY_SAVE_GAMESTATE
        && bFolioEmpty)
    {
        ipc.bSawStateBelowGreatHall = True;
    }

    if (ipc != None && h.iGameState == 0
        && bFolioEmpty)
    {
        // Only consume the one-shot latch once the signal actually goes out, so a
        // client that connects later in this same gstate-0 window still gets the
        // ledger wipe; retry each tick until connected, then send exactly once.
        if (!ipc.bNewGameSignalled && ipc.IsLinkConnected())
        {
            ipc.SendNewGame();
            ipc.bNewGameSignalled = True;
            // Fresh playthrough: clear the bean-room ledger so its room starts
            // full (the client wipes its persisted copy on NEWGAME in lockstep).
            class'APBeanRoom'.static.WipeBeanRoomState();
        }
    }
    else if (ipc != None && h.iGameState > 0)
    {
        ipc.bNewGameSignalled = False;
    }

    // Per-tick retry until a safe tick: alive, PlayerWalking, no cutscene/menu.
    if (ipc != None && !ipc.bStartupSafetySaveDone && ipc.bSawStateBelowGreatHall
        && h.iGameState >= STARTUP_SAFETY_SAVE_GAMESTATE)
    {
        saveHarry = harry(Level.PlayerHarryActor);
        if (saveHarry != None && saveHarry.GetHealthCount() > 0
            && class'APGameInfo'.static.IsPlayerInPlayableState(saveHarry, deferReason))
        {
            ipc.bStartupSafetySaveDone = True;
            Log("[Archipelago] APStartupFeedback: startup safety save (iGameState=" $ h.iGameState $ ")");
            saveHarry.SaveGame();
        }
    }
}

// Guarantee a rendering toast actor before any toast consumer resolves one via
// GetInstance(): on a save-load the toast is a stale cross-package actor that
// never renders. Replace on a Level mismatch (the only reliable stale signal) and
// re-arm the connection toast so the loaded game re-shows it. Idempotent: an
// InitGame-spawned toast is already in the live level and this returns immediately.
function EnsureFreshToast()
{
    local APHUDToast existing;
    local harry h;

    h = harry(Level.PlayerHarryActor);
    if (h == None)
    {
        return;
    }

    existing = class'APHUDToast'.static.GetInstance();
    if (existing != None && existing.Level == h.Level)
    {
        return;
    }

    if (existing != None)
    {
        existing.Destroy();
    }
    if (h.Spawn(class'APHUDToast') == None)
    {
        Log("[Archipelago] APStartupFeedback.EnsureFreshToast: Spawn(APHUDToast) FAILED");
        return;
    }
    Log("[Archipelago] APStartupFeedback.EnsureFreshToast: replaced stale toast - fresh APHUDToast in " $ string(h.Level));

    default.bConnToastShown = 0;
    default.bConnToastScheduled = 0;
}

// The three startup toasts: the delayed "Connected to host:port" (class-default
// fire latch, once per process), the seed/install mismatch warning, and the
// open-castle goal-unlock pointer (both INSTANCE latches, re-show once per level).
// The connection toast schedules a short countdown on the first playable tick the
// address is known. wasGoalUnlocked / wasInEndGame are the watcher's goal latches.
function DriveStartupToasts(byte wasGoalUnlocked, byte wasInEndGame)
{
    local harry saveHarry;
    local string deferReason;
    local APHUDToast connToast;
    local bool seedIsOpenCastle;

    if (default.bConnToastShown == 0 && default.ConnectedAddress != "")
    {
        if (default.bConnToastScheduled == 0)
        {
            saveHarry = harry(Level.PlayerHarryActor);
            if (saveHarry != None && saveHarry.GetHealthCount() > 0
                && class'APGameInfo'.static.IsPlayerInPlayableState(saveHarry, deferReason))
            {
                default.bConnToastScheduled = 1;
                default.ConnToastTicksLeft = CONN_TOAST_DELAY_TICKS;
            }
        }
        else
        {
            default.ConnToastTicksLeft -= 1;
            if (default.ConnToastTicksLeft <= 0)
            {
                connToast = class'APHUDToast'.static.GetInstance();
                if (connToast != None)
                {
                    connToast.EnqueueToast("Connected to " $ default.ConnectedAddress);
                    default.bConnToastShown = 1;
                    default.bConnToastScheduled = 0;
                    Log("[Archipelago] APStartupFeedback: connection toast shown ('"
                        $ default.ConnectedAddress $ "')");
                }
            }
        }
    }

    // Seed/install mismatch warning: the seed's declared mode disagrees with what
    // the install physically is. A mismatched seed is at best un-completable, so
    // the warning is loud and repeats once per level. Same delayed/playable guard
    // as the connection toast.
    if (class'APModeDetector'.default.bInstallProbed == 1 && class'APModeDetector'.default.SeedDeclaredMode != 0
        && bModeMismatchToastShown == 0)
    {
        seedIsOpenCastle = (class'APModeDetector'.default.SeedDeclaredMode == 2);
        if (seedIsOpenCastle != (class'APModeDetector'.default.bInstallIsOpenCastle == 1))
        {
            saveHarry = harry(Level.PlayerHarryActor);
            if (saveHarry != None && saveHarry.GetHealthCount() > 0
                && class'APGameInfo'.static.IsPlayerInPlayableState(saveHarry, deferReason))
            {
                connToast = class'APHUDToast'.static.GetInstance();
                if (connToast != None)
                {
                    if (seedIsOpenCastle)
                    {
                        connToast.EnqueueToast("AP: WRONG INSTALL - open castle seed on vanilla maps!");
                    }
                    else
                    {
                        connToast.EnqueueToast("AP: WRONG INSTALL - vanilla seed on open castle maps!");
                    }
                    bModeMismatchToastShown = 1;
                    Log("[Archipelago] APStartupFeedback: mode mismatch toast shown (seed="
                        $ class'APModeDetector'.default.SeedDeclaredMode $ " installOpenCastle="
                        $ class'APModeDetector'.default.bInstallIsOpenCastle $ ")");
                }
            }
        }
    }

    // Open-castle goal-unlock pointer: the 5-clause goal opening the Great Hall is
    // silent, so point the player at it. Re-shows once per level until they walk in
    // and the credits fire.
    if (class'APModeDetector'.default.bOpenCastleMode == 1 && wasGoalUnlocked == 1
        && wasInEndGame == 0 && bGoalUnlockToastShown == 0)
    {
        saveHarry = harry(Level.PlayerHarryActor);
        if (saveHarry != None && saveHarry.GetHealthCount() > 0
            && class'APGameInfo'.static.IsPlayerInPlayableState(saveHarry, deferReason))
        {
            connToast = class'APHUDToast'.static.GetInstance();
            if (connToast != None)
            {
                connToast.EnqueueToast("Goal complete! Go to the Great Hall.");
                bGoalUnlockToastShown = 1;
                Log("[Archipelago] APStartupFeedback: goal-unlock toast shown");
            }
        }
    }
}

defaultproperties
{
    bHidden=True
    bGameRelevant=False
    bCollideActors=False
    bBlockActors=False
}
