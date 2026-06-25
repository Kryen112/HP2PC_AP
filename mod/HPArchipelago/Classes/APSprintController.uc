// Shift-to-run (sprint) + game-slowdown upkeep. A logic-only singleton
// (GetInstance), per-level (bGameRelevant=False) so the per-frame edge-detection
// cache (bSprintApplied, SprintBaseJumpSpeed, SprintLastVel/Speed, bWasCasting) is
// INSTANCE state that resets with each level's fresh singleton, exactly like the
// per-level watcher: a stale cache must never apply to a fresh pawn. The
// running-in-logic flag is class-default + sticky. The watcher's Tick/Timer drive
// the runtime with its bound HarryRef.
//
// While Shift is held and Harry is actually running with beans to spend, both
// speed caps (GroundSpeed and GroundJumpSpeed) are scaled by
// SPRINT_SPEED_MULTIPLIER every frame, and SPRINT_BEAN_COST beans are spent per
// 0.25s watcher tick. The spend goes through the organic managerStatus.AddBeans
// path so APIPCActor.TickRingLink mirrors it to RingLink automatically.
// SPRINT_MIN_SPEED is the velocity floor (uu/s) that distinguishes "running" from
// standing still, so idling on Shift costs nothing. SPRINT_RECOVER_EPSILON is the
// near-zero speed that flags a one-frame velocity collapse: the game hard-zeroes
// Velocity for the duration of a spell cast (ProcessMove, while
// bJustFired/bJustAltFired is set), and SprintApply restores the cached run
// velocity so the run resumes with no acceleration ramp.
class APSprintController extends Info;

const SPRINT_SPEED_MULTIPLIER = 1.5;
const SPRINT_BEAN_COST = 1;
const SPRINT_MIN_SPEED = 10.0;
const SPRINT_RECOVER_EPSILON = 1.0;

// Process-wide singleton pointer (class-default). Instance copy kept None for
// save-graph hygiene, mirroring APBeanRoom / APMorphRegistry.
var APSprintController LatestInstance;

// Running-in-logic flag from the apworld slot_data (RUNNING_LOGIC IPC). When 1,
// generation precollected the Running logic flag and assumes Running-tagged
// locations are reachable by sprinting, so shift-to-run is made free: SprintTick
// skips the bean drain and SprintContext drops its >0-bean availability gate, so
// the sprint stays usable even at 0 beans and the logic assumption holds. When 0
// (default) the sprint costs SPRINT_BEAN_COST beans per tick and needs beans to
// engage. Sticky byte; resent every HELLO.
var byte bAllowRunningLogic;

// Shift-to-run falling-edge latch. 1 while SprintApply has the speed caps scaled
// up; lets the restore write the base caps back exactly once when sprint ends,
// instead of every frame. Slowdowns (sleepy / ectoplasm / web) are gated out of
// sprint entirely (SprintContext) and re-pinned each frame by SlowdownClamp, so
// shift never outruns one.
var byte bSprintApplied;
// Base GroundJumpSpeed captured on the sprint rising edge, before SprintApply
// overwrites it, so the falling-edge restore is exact even for a harry subclass.
// The game never writes GroundJumpSpeed at runtime, so the value seen at the
// rising edge is always the pawn default.
var float SprintBaseJumpSpeed;
// Cast-recovery cache for shift-to-run. SprintLastVel holds the last healthy
// horizontal run velocity (Z zeroed); SprintLastSpeed is the previous frame's
// horizontal speed; bWasCasting is 1 if a cast was in progress last frame. When
// a spell cast hard-zeroes Velocity, SprintApply re-applies SprintLastVel so the
// run continues at speed instead of ramping back up from a standstill.
// bWasCasting extends recovery one frame past the cast (the resume frame, where
// the fire flags have already cleared) so the restore lands regardless of tick
// order versus the pawn's movement code. Cleared when the sprint genuinely ends.
var vector SprintLastVel;
var float SprintLastSpeed;
var byte bWasCasting;

// Found-or-spawned singleton accessor. Lazily spawns one via the caller's context
// on first use of a level. Logic-only (no mesh) so runtime spawn is safe.
static function APSprintController GetInstance(Actor ctx)
{
    if (default.LatestInstance != None && !default.LatestInstance.bDeleteMe)
        return default.LatestInstance;
    if (ctx == None) return None;
    return ctx.Spawn(class'APSprintController');
}

event PreBeginPlay()
{
    Super.PreBeginPlay();
    // Only default.LatestInstance is the singleton pointer; Spawn seeds the
    // instance copy from the class default, so clear it.
    LatestInstance = None;
    default.LatestInstance = self;
}

// Running-in-logic flag from the apworld slot_data (RUNNING_LOGIC IPC).
// Class-default + sticky. SprintTick reads it to suppress the shift-to-run bean
// drain and SprintContext reads it to drop the >0-bean availability gate, so the
// sprint is free and always usable when the seed put Running in logic.
static function SetAllowRunningLogic(byte v)
{
    default.bAllowRunningLogic = v;
    Log("[Archipelago] APSprintController.SetAllowRunningLogic: enabled=" $ string(default.bAllowRunningLogic));
}

// True when shift-to-run is eligible this frame independent of how fast Harry is
// moving: Shift held, beans to spend, on the ground or airborne, and Harry is
// player-controllable. The playable check is deliberately leaner than
// IsPlayerInPlayableState - it allows a dialogue popup (bCutPopupMode, where the
// player can still walk) and only blocks a real cutscene (bIsCaptured, which is
// the exact condition StartCutScene uses to pick bCutSceneMode over the popup).
// bKeepStationary still blocks (vendor lure). Omitting the velocity floor is
// what lets the cast-recovery branch in SprintApply fire while a spell cast has
// Velocity pinned at zero. PHYS_Falling is included so a sprint carries through
// a jump.
function bool SprintContext(harry h)
{
    local HPConsole console;

    if (h == None || h.managerStatus == None)
    {
        return False;
    }

    console = HPConsole(h.Player.Console);
    return console != None
        && console.bShiftDown
        && (h.Physics == PHYS_Walking || h.Physics == PHYS_Falling)
        // Running-in-logic makes the sprint free, so it must engage at 0 beans
        // too; otherwise the bean count gates a movement the seed's logic assumes
        // is always available.
        && (default.bAllowRunningLogic == 1 || h.managerStatus.GetBeanCount() > 0)
        && string(h.GetStateName()) == "PlayerWalking"
        && !h.bIsCaptured
        && !h.bKeepStationary
        // No sprint while any game slowdown (sleepy / ectoplasm / spider web) is
        // active, so shift can't outrun it: this stops the cap pin, the velocity
        // injection and the bean drain. SlowdownClamp re-pins GroundSpeed for the
        // slow's whole duration.
        && !IsSlowdownActive(h);
}

// True when Harry is actively sprinting (eligible AND moving). Drives the bean
// drain on the Timer; SprintApply uses SprintContext directly so it can also act
// during the zero-velocity cast window.
function bool WantSprint(harry h)
{
    return SprintContext(h) && VSize2D(h.Velocity) > SPRINT_MIN_SPEED;
}

// Called every frame from the watcher Tick (NOT the 0.25s Timer). Three jobs:
//
// 1. Pin both speed caps to the sprint target while running: GroundSpeed so
//    PlayerWalking does not decelerate after the game resets it on
//    StopAiming/Landed, and GroundJumpSpeed so the DoJump/Falling clamp
//    (S > GroundJumpSpeed) never fires and the jump keeps its momentum. Per-frame
//    closes the up-to-0.25s window the Timer poll left open.
//
// 2. Suppress the cast "plant". ProcessMove zeroes Velocity every frame while
//    bJustFired/bJustAltFired is set, and the game leaves them set from the cast
//    trigger until AnimEnd, which is what stalls the run for the whole cast
//    animation. Those flags are set once per cast (not re-armed each frame) and
//    are read nowhere else - the spell is emitted by the anim channel's
//    stateCast, not by these flags - so clearing them while sprinting stops the
//    plant without touching the cast. Harry keeps run speed through the cast.
//    Non-sprint casts are untouched and still plant.
//
// 3. Restore momentum as a backstop. The flags are set inside PlayerTick, so the
//    trigger frame can still zero Velocity once before the clear in job 2 lands;
//    re-applying the cached run velocity covers that one frame (and anything else
//    that zeroes Velocity mid-sprint) so the run never ramps up from a stop. The
//    trigger is a one-frame collapse while still eligible - a real stop decays
//    gradually and never trips it.
//
// Both caps are restored to base exactly once on the falling edge via
// bSprintApplied. Game slowdowns (sleepy / ectoplasm / web) are handled
// separately: SprintContext makes sprint ineligible while one is active, and
// SlowdownClamp re-pins GroundSpeed for its duration (any one-frame GroundRunSpeed
// write here is corrected the same Tick).
function SprintApply(harry h)
{
    local float target, curSpeed, incomingGS;
    local vector horizVel;
    local bool bCtx, bCasting, bRecovering;

    if (h == None)
    {
        return;
    }

    target = h.GroundRunSpeed * SPRINT_SPEED_MULTIPLIER;
    curSpeed = VSize2D(h.Velocity);
    incomingGS = h.GroundSpeed;
    bCtx = SprintContext(h);
    bCasting = h.bJustFired || h.bJustAltFired;

    // While sprinting, clear the cast-plant flags so ProcessMove never zeroes
    // Velocity through a cast animation. Harmless when the flags are already
    // clear (the common case here); only matters for casts that set them.
    if (bCtx)
    {
        h.bJustFired = False;
        h.bJustAltFired = False;
    }

    // Recovery re-applies the cached run velocity to erase a momentum dip. It
    // fires on three signals, all needing a healthy cached velocity:
    //  - GroundSpeed reset on the ground: the game reset GroundSpeed to the base
    //    run speed this frame (StopAiming/TurnOffSpellCursor, Landed, cast-end).
    //    On that frame PlayerWalking physics decelerates toward the base cap
    //    before the per-frame pin below restores it - the one-frame dip felt when
    //    casting or stopping aim at full sprint. Gated to PHYS_Walking: GroundSpeed
    //    only governs ground movement (airborne uses AirSpeed), so a midair reset
    //    is harmless and restoring there would fight the fall. A normal slow-down
    //    never resets GroundSpeed (the pin holds it at target), so this cannot
    //    fire when genuinely halting.
    //  - a near-zero one-frame collapse (a cast that hard-zeroes Velocity).
    //  - the post-cast resume frame (bWasCasting), order-independent of the pawn.
    bRecovering = VSize(SprintLastVel) > SPRINT_MIN_SPEED
        && ((h.Physics == PHYS_Walking && incomingGS < target - 1.0)
            || bCasting
            || bWasCasting == 1
            || (curSpeed < SPRINT_RECOVER_EPSILON && SprintLastSpeed > SPRINT_MIN_SPEED));

    if (bCtx && (curSpeed > SPRINT_MIN_SPEED || bRecovering))
    {
        // Capture the base jump cap on the rising edge (both caps sit at their
        // base values here) and pin both caps.
        if (bSprintApplied == 0)
        {
            SprintBaseJumpSpeed = h.GroundJumpSpeed;
        }
        h.GroundSpeed = target;
        h.GroundJumpSpeed = target;

        if (bRecovering)
        {
            // Re-apply the cached horizontal run velocity so the run resumes with
            // no acceleration ramp. Keep the current vertical velocity: SprintLastVel
            // has Z zeroed, and overwriting Z would cancel a fall, so tapping cast
            // while airborne could otherwise let Harry hover.
            horizVel = SprintLastVel;
            horizVel.Z = h.Velocity.Z;
            h.Velocity = horizVel;
        }
        else
        {
            // Healthy run frame: remember the horizontal velocity for recovery.
            horizVel = h.Velocity;
            horizVel.Z = 0.0;
            SprintLastVel = horizVel;
        }
        bSprintApplied = 1;
    }
    else if (bSprintApplied == 1)
    {
        // Sprint genuinely ended (Shift up, stopped, left a playable state):
        // restore the caps once and drop the recovery cache.
        h.GroundSpeed = h.GroundRunSpeed;
        h.GroundJumpSpeed = SprintBaseJumpSpeed;
        SprintLastVel = vect(0, 0, 0);
        bSprintApplied = 0;
    }

    if (bCasting)
    {
        bWasCasting = 1;
    }
    else
    {
        bWasCasting = 0;
    }
    // Post-restore horizontal speed, so a multi-frame cast keeps the recovery
    // trigger satisfied (the restore above leaves Velocity healthy again).
    SprintLastSpeed = VSize2D(h.Velocity);
}

// Called once per 0.25s Timer tick. Shift-to-run bean drain only. The speed-cap
// application lives in SprintApply (per-frame). Spends SPRINT_BEAN_COST beans
// while sprinting via the organic managerStatus.AddBeans path (NOT
// MutateBeansNoBroadcast) so APIPCActor.TickRingLink picks up the delta and
// mirrors it to RingLink. AddBeans floors at 0, so the drain self-stops when
// beans run out (WantSprint then returns False and SprintApply restores the caps
// within a frame). When running-in-logic is on the sprint is free, so the drain
// is suppressed (the speed-cap pin in SprintApply still runs).
function SprintTick(harry h)
{
    if (WantSprint(h) && default.bAllowRunningLogic == 0)
    {
        h.managerStatus.AddBeans(-SPRINT_BEAN_COST);
    }
}

// True while any game slowdown is lowering GroundSpeed: the Drowsiness Draught
// Trap / organic pixie-dust sleepy effect (iSleepyAnimTimer), Skurge ectoplasm
// (iEctoRefCount), or a spider web (iWebAnimRefCount). Each drives its own field
// and is the eligibility gate for both sprint suppression and SlowdownClamp.
function bool IsSlowdownActive(harry h)
{
    return h != None
        && (h.iSleepyAnimTimer > 0
            || h.iEctoRefCount > 0
            || h.iWebAnimRefCount > 0);
}

// Slowdown upkeep, called every frame from the watcher Tick. Each slow sets
// GroundSpeed once on its rising edge (SleepyAnimTimerAdd / EctoRefAdd /
// WebAnimRefCountAdd) and the game never re-asserts it, so any later reset escapes
// the slow: the shift-to-run pin in SprintApply, or a cast-end TurnOffSpellCursor
// writing GroundSpeed = GroundRunSpeed. Re-pin the active slow's cap each grounded
// frame; when several overlap, take the most restrictive (lowest). The game's own
// *Sub helpers restore GroundRunSpeed when each ref/timer reaches 0, so this
// self-terminates with no extra bookkeeping. The IsSlowdownActive gate means a
// normal (un-slowed) sprint is never touched here.
function SlowdownClamp(harry h)
{
    local float cap;

    if (h == None || h.Physics != PHYS_Walking || !IsSlowdownActive(h))
    {
        return;
    }
    cap = h.GroundRunSpeed;
    if (h.iSleepyAnimTimer > 0 && h.fSleepySpeed < cap)
    {
        cap = h.fSleepySpeed;
    }
    if (h.iEctoRefCount > 0 && h.GroundEctoSpeed < cap)
    {
        cap = h.GroundEctoSpeed;
    }
    if (h.iWebAnimRefCount > 0 && h.fWebSpeed < cap)
    {
        cap = h.fWebSpeed;
    }
    if (h.GroundSpeed > cap)
    {
        h.GroundSpeed = cap;
    }
}

defaultproperties
{
    // Logic-only, no render/collision. bGameRelevant=False so each level
    // transition destroys this singleton: the per-frame sprint cache (instance)
    // resets on the next level's fresh instance, so a stale cap/velocity can never
    // apply to a fresh pawn. bAllowRunningLogic is class-default and persists.
    bHidden=True
    bGameRelevant=False
    bCollideActors=False
    bBlockActors=False
}
