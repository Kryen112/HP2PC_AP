// Per-tick orchestrator. APCardWatcher's Timer bootstraps the per-level lifecycle
// (registration, Bind, Snapshot, viewport rebind) and then hands the steady-state
// tick here, so the card watcher no longer drives the trap / sprint / container /
// scanner / vendor / bean-room / morph subsystems or knows their order. This class
// owns that sequence: it calls each subsystem controller and the watcher's own
// card / spell / key / goal / toast methods in the exact order the engine needs.
// Pure static (no state); the watcher passes itself as `w` for HarryRef / Level
// and its domain methods. The order below is load-bearing (e.g. TrapTick must run
// before the spell-revert reconcile); do not reorder without checking the inline
// notes that travelled with each block.
class APTickDriver extends Object;

// Cadence for the event-backed safety-net scanners (ScanSecretMarkers,
// ReconcileVanillaCardPickups). Their primary detection is now event-driven
// (APSecretMarker.OnFound / APCardMarker.Touch), so they only back those up and
// run every Nth tick instead of every tick, to shave per-tick AllActors work.
// 4 ticks == ~1s at the 0.25s Timer; a missed event is still caught within that
// window. Does NOT cover the vendor pickup polls: their pass must run every tick
// to detect a sale and swap the dropped prop before the player grabs it.
const SAFETY_NET_INTERVAL = 4;

// Process-wide phase counter for the cadence above. Class default (this class is
// never instantiated); a plain int, so no save-graph or teardown-GC concern.
var int SafetyNetTick;

static function DriveTick(APCardWatcher w)
{
    local APIPCActor ipc;
    local APBeanRoom br;
    local APContainerManager cm;
    local APMorphRegistry mr;
    local APSprintController sc;
    local APLocationScanner ls;
    local APVendorController vc;
    local APStartupFeedback sf;
    local bool bRunSafetyNets;

    // Use the singleton directly instead of Level.Game.IPCActor: save-load skips
    // APGameInfo.InitGame, leaving the post-save GameInfo with IPCActor=None even
    // though the persistent singleton is alive.
    ipc = class'APIPCActor'.static.GetInstance();

    // Reduced cadence for the event-backed safety-net scanners (see
    // SAFETY_NET_INTERVAL): their primary paths fire instantly, so this only sets
    // how fast the backstop catches a missed event.
    bRunSafetyNets = (default.SafetyNetTick == 0);
    default.SafetyNetTick = (default.SafetyNetTick + 1) % SAFETY_NET_INTERVAL;

    // Cheap once-per-process menu patch (no-op after the first inject).
    class'APMenuCutsceneAid'.static.EnsureHomeMenuInjected(w.HarryRef);

    // containersanity: swap/inject the bean-container AP tokens once per level,
    // as soon as the option flag has arrived. The helper self-guards.
    if (class'APContainerManager'.default.bContainersanity == 1)
    {
        cm = class'APContainerManager'.static.GetInstance(w);
        if (cm != None) cm.ReplaceContainers();
    }

    // Terminate the Polyjuice / Obliviate traps on timer / level change. Runs
    // before the spell-revert reconcile so a same-tick restore is visible to it.
    class'APTrapController'.static.TrapTick(w.HarryRef);

    // Shift-to-run upkeep: scale GroundSpeed + drain beans while sprinting.
    sc = class'APSprintController'.static.GetInstance(w);
    if (sc != None) sc.SprintTick(w.HarryRef);

    // Jelly-Legs Jinx upkeep: count the hijack down and inject random jumps.
    class'APTrapController'.static.JellyLegsTick(w.HarryRef);

    // Free pixies from the 3s fly-in invulnerability the moment a cutscene ends.
    w.PixieCutsceneTick();

    // Vanilla wizard-card pickups -> CHECK + revert + stamp checked. Backs up the
    // primary APCardMarker.Touch path, so it runs on the safety-net cadence.
    if (bRunSafetyNets) w.ReconcileVanillaCardPickups(ipc);

    // Tradersanity + Fred/George equipment, then card-vendor card replacement.
    // Independent of each other, so order does not matter.
    vc = class'APVendorController'.static.GetInstance(w);
    if (vc != None) vc.ReplaceVendorEquipment(w.HarryRef);
    w.ReplaceVendorSpawnedCards();

    // Runtime check-detection pollers (secrets / duels / matches / challenges /
    // bosses / final star / stuck ectoplasm).
    ls = class'APLocationScanner'.static.GetInstance(w);
    if (ls != None)
    {
        if (bRunSafetyNets) ls.ScanSecretMarkers(ipc);  // backs up APSecretMarker.OnFound
        ls.ScanDuelWins(ipc, w.HarryRef);
        ls.ScanMatchWins(ipc, w.HarryRef);
        ls.EnforceGenuineChallengeScores(w.HarryRef);
        ls.ScanChallengeMastery(ipc, w.HarryRef);
        ls.ScanBossKills(w.HarryRef);
        ls.ScanFinalStarCompletion();
        ls.ScanStuckEctoplasm();
    }
    w.ScanDeathLink(ipc);

    // Spell-tutorial lesson-end check, then the open-castle Gryffindor
    // bNoSpellBookCheck clear.
    w.SpellLessonEndHook(ipc);
    w.ClearGryffindorSpellBookFlag();

    // Open-castle bean room runs with NO timer: re-assert the stop each tick. The
    // helper self-gates to BeanRewardRoom + open castle and no-ops elsewhere.
    if (class'APModeDetector'.default.bOpenCastleMode == 1
        && Caps(string(w.Level.Outer.Name)) == "BEANREWARDROOM"
        && APGameInfo(w.Level.Game) != None)
    {
        APGameInfo(w.Level.Game).StopBeanRoomTimer();
    }
    // Per-bean persistence sweep + chest/gargoyle dropped-bean snapshot.
    br = class'APBeanRoom'.static.GetInstance(w);
    if (br != None)
    {
        br.ScanBeanRoom();
        br.ManageBeanDrops();
    }

    // Vanilla spell-learn reconcile, key-item pickups, spell-cast flavor.
    w.ReconcileVanillaSpells(ipc);
    w.ReconcileKeyItems(ipc);
    w.SaySpellCastFlavor();

    // Goal tracking: clause-3 key-item objectives, open-castle Great Hall unlock,
    // M7 credits-completion, story-progression-gated blockers / vendor assignment.
    w.CheckKeyItemObjectives();
    w.DetectGoalUnlock();
    w.DetectGoalCompletion(ipc);
    w.DriveStoryProgression();

    // Startup AP feedback: NEWGAME ledger wipe + safety save, a guaranteed fresh
    // toast actor, then the connection / mismatch / goal-unlock toasts. The
    // watcher owns the few inputs (live harry, the at-Snapshot folio sample, the
    // goal latches), passed in.
    sf = class'APStartupFeedback'.static.GetInstance(w);
    if (sf != None)
    {
        sf.EmitStartupSignals(w.HarryRef, w.bFolioEmptyAtSnapshot, ipc);
        sf.EnsureFreshToast();
        sf.DriveStartupToasts(class'APCardWatcher'.default.WasGoalUnlocked, w.WasInEndGame);
    }

    // Card-count change log, one appearance convergence sweep per level, heartbeat.
    w.LogCardCountChange();
    if (class'APMorphRegistry'.default.bAppearanceReceived == 1)
    {
        mr = class'APMorphRegistry'.static.GetInstance(w);
        if (mr != None) mr.RestampOncePerLevel();
    }
    w.TickHeartbeat();
}
