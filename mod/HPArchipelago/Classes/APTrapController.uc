// AP trap subsystem: the trap activators (called from APGameInfo.TryApplyTrap)
// and the per-tick runtime that terminates them. All static and class-default so
// a trap applied with no live watcher instance still survives the per-level
// watcher respawn and save-load (a cleared spellbook or forced setting must be
// restorable across a level boundary). Each function operates on the pawn handed
// to it; the watcher's Tick/Timer drive the runtime with its bound HarryRef. The
// pure input/light helpers live in APTrapKit.
class APTrapController extends Object;

// Obliviate Trap: SpellTrapBackup holds harry.SpellBook[0..31] (the engine array
// is class<baseSpell> SpellBook[32], harry.uc:156). bSpellTrapActive==1 while
// spells are withheld; restored when Level.TimeSeconds reaches SpellTrapExpiry OR
// the level changes, whichever comes first, so spells are never permanently lost.
const SPELL_TRAP_DURATION = 30.0;
var byte bSpellTrapActive;
var float SpellTrapExpiry;
var class<baseSpell> SpellTrapBackup[32];
// Polyjuice Potion Trap: the pawn reverts naturally on the next level's fresh
// (bIsGoyle=false) pawn; this sticky just records the active state and is cleared
// on the level change so it stays accurate.
var byte bPolyjuiceTrapActive;
// Level the pawn last observed (Level.Outer.Name). Every activation of a
// level-bounded trap (fresh or stacked) stamps the apply-level here; TrapTick
// compares each tick and treats any change as the "left the level" boundary that
// ends the Polyjuice/spell/size/confundus/wand-size/levicorpus traps. Drowsiness
// never stamps: the engine's own countdown ends it and a fresh pawn spawns
// awake. Level NAME (not watcher instance) is the discriminator so open castle's
// streamed-sublevel watcher churn never false-triggers.
var name TrapLastLevelName;
// Engorgio / Reducio Traps: bSizeTrapActive==1 while harry.DrawScale and the
// collision cylinder are scaled away from normal (JumpZ stays at its default so
// the world-space jump apex is vanilla and level logic holds). Restored to the
// pawn defaults when Level.TimeSeconds reaches SizeTrapExpiry OR the level
// changes (the fresh pawn already loads its default scale and collision),
// whichever comes first, so a bad scale can never soft-lock a level.
// SizeTrapScale records the trap's target scale; the HUD countdown labels its
// row Engorgio or Reducio from it.
const SIZE_TRAP_DURATION = 30.0;
var byte bSizeTrapActive;
var float SizeTrapExpiry;
var float SizeTrapScale;
// Confundus Trap: bConfundusTrapActive==1 while harry.bInvertMouse is forced on.
// bConfundusOrigInvertMouse holds the player's real setting so the restore returns
// it rather than blindly clearing; restored on the timer OR a level change (the
// fresh pawn re-reads bInvertMouse from the ini), whichever first.
const CONFUNDUS_TRAP_DURATION = 20.0;
var byte bConfundusTrapActive;
var float ConfundusTrapExpiry;
var byte bConfundusOrigInvertMouse;
// Overcompensation Trap: bWandSizeTrapActive==1 while the held wand wears the
// enlarged APWandGiant mesh instead of HPModels.WandMesh. This build's renderer
// ignores a bone-attached actor's own DrawScale, so the wand is enlarged by
// swapping baseWand.Mesh/ThirdPersonMesh to the baked-scale giant mesh (see
// APWandMesh.uc). Like the Polyjuice/Goyle trap it lasts the rest of the level and
// reverts on the next level change, but because the wand is inventory and may
// travel across the boundary, TrapTick reassigns the canonical HPModels.WandMesh
// actively rather than relying on a fresh-spawned wand. APLumosLight reads this
// flag (cross-class) to gate its giant-tip rescale.
var byte bWandSizeTrapActive;
// Levicorpus Trap: bLevicorpusTrapActive==1 while Harry hangs upside down
// (Rotation/DesiredRotation Roll forced to 32768 = 180 degrees). Ends when
// Level.TimeSeconds reaches LevicorpusTrapExpiry OR the level changes, whichever
// comes first: the timer path un-rolls the pawn itself, the fresh level-change
// pawn spawns upright, so a flipped Harry can never soft-lock a level. The native
// walking physics rights the pawn every frame, so the roll is re-pinned per frame
// in the watcher's Tick (LevicorpusHold), not on the 0.25s Timer. The 180 roll
// flips the right-axis the native PlayerMove strafes along, so the strafe keys are
// rebound to inverted raw axis commands on activation (APTrapKit.SwapStrafeKeys)
// and reverted to the StrafeLeft/StrafeRight aliases when the trap ends
// (APTrapKit.RestoreStrafeKeys). Bindings persist in User.ini, so a save/quit while
// flipped would otherwise strand the swap; the swapped binding is self-identifying
// (a raw `Axis aStrafe` command, which the player config never uses), so
// HealOrphanedStrafe reverts it on the first bind when no trap is live. The roll
// also flips the root motion of a ledge pull-up, so LevicorpusHold rights the pawn
// for the duration of the climb (Mounting/MountFinish) and re-flips it afterwards.
const LEVICORPUS_TRAP_DURATION = 30.0;
var byte bLevicorpusTrapActive;
var float LevicorpusTrapExpiry;
// Jelly-Legs Jinx Trap: bJellyLegsTrapActive==1 while jumping is hijacked. Manual
// and auto jump are both suppressed by pinning harry.bCorraledByMover (the only
// DoJump gate with no movement side effects), re-pinned each frame in the watcher's
// Tick (JellyLegsHold) so a stray mover write cannot lift it for long. The runtime
// injects its own random jumps via JellyLegsTick, momentarily lifting the gate so
// the forced DoJump lands. Duration and jump cadence are TICK countdowns, never
// Level.TimeSeconds, so a reload that resets the level clock cannot strand the trap
// far-future. On a full quit the class-default flag resets to 0, so
// HealOrphanedJellyLegs clears the orphaned gate on the first bind, mirroring
// HealOrphanedStrafe. JellyLegsTicksLeft counts the ~20s lifetime; NextJumpTicksLeft
// counts down to each forced jump, reseeded to a random interval after one fires.
const JELLYLEGS_TRAP_TICKS     = 80;   // ~20s at 0.25s per Timer tick
const JELLYLEGS_JUMP_MIN_TICKS = 6;    // ~1.5s, shortest gap between forced jumps
const JELLYLEGS_JUMP_MAX_TICKS = 14;   // ~3.5s, longest gap between forced jumps
var byte bJellyLegsTrapActive;
var int JellyLegsTicksLeft;
var int NextJumpTicksLeft;
// Drowsiness Draught Trap: the effect and its revert are the game's own sleepy
// status (harry.iSleepyAnimTimer counts down once per second in harry.Timer,
// restoring speed/anim at zero). bDrowsinessTrapActive only gates the HUD
// countdown row; TrapTick clears it when the engine countdown reaches zero.
const DROWSINESS_TRAP_DURATION = 20;
var byte bDrowsinessTrapActive;

// ---------------------------------------------------------------------------
// Activators (called from APGameInfo.TryApplyTrap)
// ---------------------------------------------------------------------------

// Obliviate Trap entry point. Backs the full spellbook up into the class-default
// array, arms the restore timer + level-change record, then clears Harry's
// spellbook. TrapTick does the matching restore.
static function BackupAndClearSpellBook(harry h)
{
    local int i;

    if (h == None)
    {
        return;
    }
    // Stacking guard: a second Obliviate while one is still active must NOT
    // re-snapshot the spellbook (it is already cleared, so backing it up again
    // would capture an empty book and the timer would "restore" nothing, losing
    // the spells permanently). Just extend the expiry; the original backup (the
    // real spells) is preserved and restored when it finally ends.
    if (default.bSpellTrapActive == 1)
    {
        default.SpellTrapExpiry   = h.Level.TimeSeconds + SPELL_TRAP_DURATION;
        default.TrapLastLevelName = h.Level.Outer.Name;
        Log("[Archipelago] APTrapController.BackupAndClearSpellBook: already active - extended expiry to Level.TimeSeconds " $ string(default.SpellTrapExpiry) $ ", original backup preserved");
        return;
    }
    // 32 == harry.MAX_NUM_SPELLS / the SpellBook[32] dimension. Back up all slots
    // (a superset of what ClearSpellBook wipes) so the restore is exact.
    for (i = 0; i < 32; i++)
    {
        default.SpellTrapBackup[i] = h.SpellBook[i];
    }
    default.bSpellTrapActive  = 1;
    default.SpellTrapExpiry   = h.Level.TimeSeconds + SPELL_TRAP_DURATION;
    default.TrapLastLevelName = h.Level.Outer.Name;
    h.ClearSpellBook();
    Log("[Archipelago] APTrapController.BackupAndClearSpellBook: spellbook backed up + cleared (expires at Level.TimeSeconds " $ string(default.SpellTrapExpiry) $ " or on level change)");
}

// Polyjuice Potion Trap bookkeeping (called after APGameInfo flips bIsGoyle +
// SetNewMesh). The mesh reverts for free on the next level's fresh pawn; this
// sticky just records the active state and the apply-level so TrapTick can clear
// it on the level change.
static function MarkPolyjuiceTrapActiveDefault(harry h)
{
    default.bPolyjuiceTrapActive = 1;
    if (h != None)
    {
        default.TrapLastLevelName = h.Level.Outer.Name;
    }
    Log("[Archipelago] APTrapController.MarkPolyjuiceTrapActiveDefault: Polyjuice trap active (reverts on next level)");
}

// Engorgio / Reducio Trap entry point. Scales the model and the collision cylinder
// together via ApplySizeScale, then arms the restore timer + level-change record.
// JumpZ is left at its default on purpose: the world-space jump apex must stay
// vanilla or level traversal logic breaks, so a shrunk Harry only appears to
// out-jump his height and a giant to under-jump it while both reach the same
// ledges as normal. TrapTick does the matching restore on the timer or the level
// change, whichever comes first. Stacking guard: a second size trap while one is
// active re-applies the new scale and extends the expiry, and because
// radius/height derive from the pawn defaults a later Reducio cleanly overrides
// an earlier Engorgio.
static function MarkSizeTrapActive(harry h, float newScale)
{
    if (h == None)
    {
        return;
    }

    if (!ApplySizeScale(h, newScale))
    {
        // No headroom for a grow (e.g. a shrunk Harry beneath a ledge). Arm the
        // trap anyway: the scale stays put and the expiry restore self-heals.
        Log("[Archipelago] APTrapController.MarkSizeTrapActive: resize to DrawScale " $ string(newScale) $ " refused (no headroom) - scale unchanged");
    }

    if (default.bSizeTrapActive == 1)
    {
        default.SizeTrapExpiry    = h.Level.TimeSeconds + SIZE_TRAP_DURATION;
        default.SizeTrapScale     = newScale;
        default.TrapLastLevelName = h.Level.Outer.Name;
        Log("[Archipelago] APTrapController.MarkSizeTrapActive: already active - rescaled to DrawScale " $ string(newScale) $ ", extended expiry to Level.TimeSeconds " $ string(default.SizeTrapExpiry));
        return;
    }
    default.bSizeTrapActive   = 1;
    default.SizeTrapExpiry    = h.Level.TimeSeconds + SIZE_TRAP_DURATION;
    default.SizeTrapScale     = newScale;
    default.TrapLastLevelName = h.Level.Outer.Name;
    Log("[Archipelago] APTrapController.MarkSizeTrapActive: DrawScale + hitbox -> " $ string(newScale) $ " (expires at Level.TimeSeconds " $ string(default.SizeTrapExpiry) $ " or on level change)");
}

// Scale the model and the collision cylinder together (the game's own
// DrawScale-coupled SetCollisionSize idiom) so the hitbox always bounds the
// visible mesh. Radius/height derive from the pawn defaults, so any scale lands
// exactly; passing h.Default.DrawScale is the restore. A grow can be refused
// under low geometry (SetCollisionSize will not encroach): the lift is undone
// and DrawScale is left untouched so mesh and cylinder never diverge, and False
// reports the miss so the caller can retry. Success is read off the resulting
// CollisionHeight, not a native return value.
static function bool ApplySizeScale(harry h, float newScale)
{
    local float newRadius, newHeight, deltaHeight;
    local vector lift;

    newRadius   = h.Default.CollisionRadius * newScale;
    newHeight   = h.Default.CollisionHeight * newScale;
    deltaHeight = newHeight - h.CollisionHeight;
    lift.Z      = deltaHeight;
    if (deltaHeight >= 0.0)
    {
        // Grow: lift first so the taller cylinder grows up into open air, not down
        // into the floor.
        h.Move(lift);
        h.SetCollisionSize(newRadius, newHeight);
        if (h.CollisionHeight < newHeight - 0.1)
        {
            lift.Z = -lift.Z;
            h.Move(lift);
            return False;
        }
    }
    else
    {
        // Shrink: a smaller cylinder always fits, then drop the feet back down.
        h.SetCollisionSize(newRadius, newHeight);
        h.Move(lift);
    }
    h.DrawScale = newScale;
    return True;
}

// Overcompensation Trap entry point. Swaps the held wand to the enlarged APWandGiant
// mesh (DrawScale does not render on the bone-attached wand, so a baked-scale mesh
// is the only lever). Lasts the rest of the level; TrapTick reassigns
// HPModels.WandMesh on the next level change. No-op when no wand is equipped or the
// mesh fails to load.
static function MarkWandSizeTrapActive(harry h)
{
    local baseWand wand;
    local Mesh giant;

    if (h == None)
    {
        return;
    }
    wand = baseWand(h.Weapon);
    if (wand == None)
    {
        Log("[Archipelago] APTrapController.MarkWandSizeTrapActive: no wand equipped - no-op");
        return;
    }
    giant = Mesh(DynamicLoadObject("HPArchipelago.APWandGiant", class'Mesh'));
    if (giant == None)
    {
        Log("[Archipelago] APTrapController.MarkWandSizeTrapActive: APWandGiant failed to load - no-op");
        return;
    }
    wand.Mesh = giant;
    wand.ThirdPersonMesh = giant;
    // The giant tip lands at 3x the retail 20-unit light offset, so the Lumos light
    // and spell-charge glow would otherwise float a third of the way up the shaft.
    // Swap in an APLumosLight that re-places them at the giant tip from inside
    // baseWand's own per-frame UpdateLocation call (race-free).
    class'APTrapKit'.static.SwapInWandTipLumosLight(wand);
    if (default.bWandSizeTrapActive == 1)
    {
        default.TrapLastLevelName = h.Level.Outer.Name;
        Log("[Archipelago] APTrapController.MarkWandSizeTrapActive: already active - wand kept enlarged");
        return;
    }
    default.bWandSizeTrapActive = 1;
    default.TrapLastLevelName    = h.Level.Outer.Name;
    Log("[Archipelago] APTrapController.MarkWandSizeTrapActive: wand enlarged (reverts on next level)");
}

// Confundus Trap entry point. Backs the player's real bInvertMouse setting up, arms
// the restore timer + level-change record, then forces inverted look. TrapTick
// restores. Stacking guard extends the expiry without re-snapshotting (the live
// value is already forced, so a re-backup would capture the forced state and the
// restore would never undo it).
static function MarkConfundusTrapActive(harry h)
{
    if (h == None)
    {
        return;
    }
    if (default.bConfundusTrapActive == 1)
    {
        default.ConfundusTrapExpiry = h.Level.TimeSeconds + CONFUNDUS_TRAP_DURATION;
        default.TrapLastLevelName   = h.Level.Outer.Name;
        h.bInvertMouse = True;
        Log("[Archipelago] APTrapController.MarkConfundusTrapActive: already active - extended expiry to Level.TimeSeconds " $ string(default.ConfundusTrapExpiry) $ ", original setting preserved");
        return;
    }
    if (h.bInvertMouse)
    {
        default.bConfundusOrigInvertMouse = 1;
    }
    else
    {
        default.bConfundusOrigInvertMouse = 0;
    }
    default.bConfundusTrapActive = 1;
    default.ConfundusTrapExpiry  = h.Level.TimeSeconds + CONFUNDUS_TRAP_DURATION;
    default.TrapLastLevelName    = h.Level.Outer.Name;
    h.bInvertMouse = True;
    Log("[Archipelago] APTrapController.MarkConfundusTrapActive: bInvertMouse forced on (orig=" $ string(default.bConfundusOrigInvertMouse) $ ", expires at Level.TimeSeconds " $ string(default.ConfundusTrapExpiry) $ " or on level change)");
}

// Levicorpus Trap entry point. Flips Harry upside down, arms the restore timer
// and records the apply-level. Rotation is a const native var so the flip goes
// through SetRotation; DesiredRotation.Roll is set directly so the pawn wants to
// stay flipped. The watcher's Tick (LevicorpusHold) re-pins the roll each frame;
// TrapTick ends the trap on the timer or the level change, whichever comes first.
// The flip also inverts strafe (the native PlayerMove builds movement from the
// rolled Rotation), so SwapStrafeKeys rebinds the strafe keys to inverted raw
// axis commands on this fresh activation; TrapTick reverts them when the trap
// ends. The stacking guard extends the expiry without a second flag-set
// (SwapStrafeKeys is itself a no-op once the keys are raw).
static function MarkLevicorpusTrapActive(harry h)
{
    local Rotator R;

    if (h == None)
    {
        return;
    }
    R = h.Rotation;
    R.Roll = 32768;
    h.SetRotation(R);
    h.DesiredRotation.Roll = 32768;
    if (default.bLevicorpusTrapActive == 1)
    {
        default.LevicorpusTrapExpiry = h.Level.TimeSeconds + LEVICORPUS_TRAP_DURATION;
        default.TrapLastLevelName    = h.Level.Outer.Name;
        Log("[Archipelago] APTrapController.MarkLevicorpusTrapActive: already active - extended expiry to Level.TimeSeconds " $ string(default.LevicorpusTrapExpiry));
        return;
    }
    default.bLevicorpusTrapActive = 1;
    default.LevicorpusTrapExpiry  = h.Level.TimeSeconds + LEVICORPUS_TRAP_DURATION;
    default.TrapLastLevelName     = h.Level.Outer.Name;
    class'APTrapKit'.static.SwapStrafeKeys(h);
    Log("[Archipelago] APTrapController.MarkLevicorpusTrapActive: Harry flipped upside down (expires at Level.TimeSeconds " $ string(default.LevicorpusTrapExpiry) $ " or on level change)");
}

// Jelly-Legs Jinx Trap entry point. Pins harry.bCorraledByMover so DoJump no-ops
// (blocks manual and, if it routes through DoJump, auto jump) and arms the tick
// countdowns. The stacking guard refreshes the lifetime without re-seeding the jump
// schedule, so a second Jelly-Legs simply extends the hijack.
static function MarkJellyLegsTrapActive(harry h)
{
    if (h == None)
    {
        return;
    }
    h.bCorraledByMover = True;
    if (default.bJellyLegsTrapActive == 1)
    {
        default.JellyLegsTicksLeft = JELLYLEGS_TRAP_TICKS;
        default.TrapLastLevelName  = h.Level.Outer.Name;
        Log("[Archipelago] APTrapController.MarkJellyLegsTrapActive: already active - lifetime refreshed");
        return;
    }
    default.bJellyLegsTrapActive = 1;
    default.JellyLegsTicksLeft   = JELLYLEGS_TRAP_TICKS;
    default.NextJumpTicksLeft    = JELLYLEGS_JUMP_MIN_TICKS + Rand(JELLYLEGS_JUMP_MAX_TICKS - JELLYLEGS_JUMP_MIN_TICKS + 1);
    default.TrapLastLevelName    = h.Level.Outer.Name;
    Log("[Archipelago] APTrapController.MarkJellyLegsTrapActive: jump hijacked for " $ string(JELLYLEGS_TRAP_TICKS) $ " ticks, random jumps armed");
}

// Drowsiness Draught Trap entry point. Reuses the game's own sleepy status
// effect: GroundSpeed drops to fSleepySpeed with the sleepy walk animation set,
// and harry.Timer()'s SleepyAnimTimerSub counts it back down once per second,
// restoring speed/anim at zero, so the engine owns the revert.
// SleepyAnimTimerAdd clamps to iMaxSleepyAnim (default 6, the cap organic pixie
// dust relies on), so it only triggers the slow/anim; the countdown is then set
// to the trap duration directly. Sub only decrements and never re-clamps, so the
// longer timer rides down cleanly, but an organic pixie-dust touch mid-trap runs
// Add's unconditional clamp and truncates the countdown to the 6s cap (accepted:
// the HUD reads the same timer, so the display stays truthful, and raising the
// cap would serialize a lie into the save). A second Drowsiness simply re-arms
// the full countdown.
static function MarkDrowsinessTrapActive(harry h)
{
    if (h == None)
    {
        return;
    }
    h.SleepyAnimTimerAdd(h.iMaxSleepyAnim);
    h.iSleepyAnimTimer = DROWSINESS_TRAP_DURATION;
    default.bDrowsinessTrapActive = 1;
    Log("[Archipelago] APTrapController.MarkDrowsinessTrapActive: sleepy slow applied for " $ string(DROWSINESS_TRAP_DURATION) $ "s (engine countdown reverts)");
}

// ---------------------------------------------------------------------------
// Runtime (driven by the watcher's Tick/Timer, passing its bound pawn)
// ---------------------------------------------------------------------------

// End the Jelly-Legs trap and restore normal jumping. Clears the bCorraledByMover
// gate on the passed pawn (a no-op on a fresh level-change pawn, which spawns
// un-corralled) and zeroes the countdowns. Called from TrapTick on a level change
// and from JellyLegsTick when the lifetime runs out.
static function EndJellyLegsTrap(harry h)
{
    if (h != None)
    {
        h.bCorraledByMover = False;
    }
    default.bJellyLegsTrapActive = 0;
    default.JellyLegsTicksLeft   = 0;
    default.NextJumpTicksLeft    = 0;
}

// First-bind heal for a jump-suppression gate orphaned by a save/quit while the
// trap was active. The grant drain saves right after a trap applies, so a reload
// can restore a pawn with bCorraledByMover set, but the class-default trap flag
// resets to 0 on the relaunch, so nothing in TrapTick would clear it. Mirrors
// HealOrphanedStrafe: revert whenever no trap is live. A legit mover-corral
// re-asserts itself within a frame, so clearing here is safe.
static function HealOrphanedJellyLegs(harry h)
{
    if (h == None || default.bJellyLegsTrapActive == 1)
    {
        return;
    }
    if (h.bCorraledByMover)
    {
        h.bCorraledByMover = False;
        Log("[Archipelago] APTrapController.HealOrphanedJellyLegs: cleared orphaned jump-suppression gate (no trap live)");
    }
}

// Per-frame re-pin of the jump-suppression gate (watcher Tick, like LevicorpusHold).
// A mover could write bCorraledByMover during the frame; re-asserting it each frame
// keeps DoJump blocked. Only acts while the trap is active and Harry is bound.
static function JellyLegsHold(harry h)
{
    if (default.bJellyLegsTrapActive == 0 || h == None)
    {
        return;
    }
    h.bCorraledByMover = True;
}

// Inject one forced jump, bypassing our own gate. DoJump checks bCorraledByMover,
// so lift it for this single call and re-assert immediately (the watcher Tick
// re-pins it too). Only fires from PHYS_Walking: DoJump's own guards no-op a
// mid-air or cutscene call, but checking here avoids wasting a scheduled jump.
static function ForceJellyJump(harry h)
{
    if (h == None || h.Physics != PHYS_Walking)
    {
        return;
    }
    h.bCorraledByMover = False;
    h.DoJump();
    h.bCorraledByMover = True;
}

// Per-Timer-tick driver for the Jelly-Legs trap (called from the main Timer body,
// not the first-bind path, so a reload tick never forces a jump). Counts the
// lifetime down and ends the trap at zero, and counts down to each random jump,
// firing only when grounded so a pending jump lands the moment Harry touches down.
static function JellyLegsTick(harry h)
{
    if (default.bJellyLegsTrapActive != 1)
    {
        return;
    }
    default.JellyLegsTicksLeft -= 1;
    if (default.JellyLegsTicksLeft <= 0)
    {
        EndJellyLegsTrap(h);
        Log("[Archipelago] APTrapController.JellyLegsTick: Jelly-Legs trap ended on lifetime countdown - jump restored");
        return;
    }
    default.NextJumpTicksLeft -= 1;
    if (default.NextJumpTicksLeft <= 0 && h != None && h.Physics == PHYS_Walking)
    {
        ForceJellyJump(h);
        default.NextJumpTicksLeft = JELLYLEGS_JUMP_MIN_TICKS + Rand(JELLYLEGS_JUMP_MAX_TICKS - JELLYLEGS_JUMP_MIN_TICKS + 1);
    }
}

// First-bind heal for a strafe swap orphaned by a save/quit while flipped. The
// swapped bindings persist in User.ini but bLevicorpusTrapActive reset to 0 on
// reboot, so nothing would revert them. The swapped binding is self-identifying, so
// just revert whenever no trap is live: RestoreStrafeKeys is a no-op on a clean
// config, and the trap-active guard keeps a genuine mid-flip re-bind (e.g. an open
// castle sublevel transition) from undoing a live swap.
static function HealOrphanedStrafe(harry h)
{
    if (h == None || default.bLevicorpusTrapActive == 1)
    {
        return;
    }
    class'APTrapKit'.static.RestoreStrafeKeys(h);
}

// Reload guard for a Level.TimeSeconds expiry. Loading a save resets the level
// clock to near zero while the class-default trap state survives the session, so
// an armed expiry stamped on the old clock can strand a trap far-future. Every
// arm/extend sets exactly now + duration, so any expiry further out than that is
// stale; re-arm it to a fresh full duration.
static function float ClampTrapExpiry(harry h, float expiry, float duration)
{
    if (expiry - h.Level.TimeSeconds > duration)
    {
        return h.Level.TimeSeconds + duration;
    }
    return expiry;
}

// Called once per Timer tick (after Snapshot, the pawn valid). Terminates every
// trap the runtime owns. The timed traps (Obliviate, size, Confundus, Levicorpus)
// end on their Level.TimeSeconds expiry OR the level change, whichever comes
// first: the timeout path actively restores what the trap altered, the
// level-change path leans on the fresh pawn where it can. The rest-of-level
// traps (Polyjuice, wand size) end on the level change alone, and Jelly-Legs
// counts its same-level lifetime down in JellyLegsTick so only its level-change
// early end lives here. Level NAME is the change discriminator, robust against
// open castle's per-sublevel watcher respawn (Level.Outer.Name is stable across
// those).
static function TrapTick(harry h)
{
    local int i;
    local name curLevel;
    local bool bLevelChanged;
    local Rotator R;

    if (h == None)
    {
        return;
    }
    default.SpellTrapExpiry      = ClampTrapExpiry(h, default.SpellTrapExpiry,      SPELL_TRAP_DURATION);
    default.SizeTrapExpiry       = ClampTrapExpiry(h, default.SizeTrapExpiry,       SIZE_TRAP_DURATION);
    default.ConfundusTrapExpiry  = ClampTrapExpiry(h, default.ConfundusTrapExpiry,  CONFUNDUS_TRAP_DURATION);
    default.LevicorpusTrapExpiry = ClampTrapExpiry(h, default.LevicorpusTrapExpiry, LEVICORPUS_TRAP_DURATION);
    curLevel = h.Level.Outer.Name;
    // Only meaningful while a trap is active, where a helper has stamped
    // TrapLastLevelName to a real apply-level; the pre-trap '' -> levelname
    // transition is harmless because both guarded blocks check their flag.
    bLevelChanged = (default.TrapLastLevelName != curLevel);

    if (default.bPolyjuiceTrapActive == 1 && bLevelChanged)
    {
        default.bPolyjuiceTrapActive = 0;
        Log("[Archipelago] APTrapController.TrapTick: Polyjuice trap cleared on level change (pawn already reverted)");
    }

    if (default.bSpellTrapActive == 1
        && (bLevelChanged || h.Level.TimeSeconds >= default.SpellTrapExpiry))
    {
        for (i = 0; i < 32; i++)
        {
            h.SpellBook[i] = default.SpellTrapBackup[i];
        }
        default.bSpellTrapActive = 0;
        if (bLevelChanged)
        {
            Log("[Archipelago] APTrapController.TrapTick: Obliviate trap ended on level change - spellbook restored");
        }
        else
        {
            Log("[Archipelago] APTrapController.TrapTick: Obliviate trap ended on timer - spellbook restored");
        }
    }

    if (default.bSizeTrapActive == 1
        && (bLevelChanged || h.Level.TimeSeconds >= default.SizeTrapExpiry))
    {
        // On a level change the fresh pawn already loaded its default DrawScale
        // and collision, so only the same-level timeout needs the active restore.
        if (bLevelChanged)
        {
            default.bSizeTrapActive = 0;
            Log("[Archipelago] APTrapController.TrapTick: size trap cleared on level change (pawn already at default scale)");
        }
        else
        {
            // A refused grow-back (no headroom) leaves the pawn at the trap
            // scale, and the expired timer retries here every tick until the
            // full-size cylinder fits.
            if (ApplySizeScale(h, h.Default.DrawScale))
            {
                default.bSizeTrapActive = 0;
                Log("[Archipelago] APTrapController.TrapTick: size trap ended on timer - DrawScale + hitbox restored");
            }
        }
    }

    if (default.bConfundusTrapActive == 1
        && (bLevelChanged || h.Level.TimeSeconds >= default.ConfundusTrapExpiry))
    {
        // On a level change the fresh pawn re-reads bInvertMouse from the ini, so
        // only the same-level timeout needs to actively restore it.
        if (!bLevelChanged)
        {
            h.bInvertMouse = (default.bConfundusOrigInvertMouse == 1);
        }
        default.bConfundusTrapActive = 0;
        // Drop the screen tint. On a level change the fresh pawn already has a
        // zero FlashFog, so this only matters for the same-level timeout, but it
        // is a harmless no-op on the new pawn either way.
        ClearConfundusTint(h);
        if (bLevelChanged)
        {
            Log("[Archipelago] APTrapController.TrapTick: confundus trap cleared on level change (pawn re-reads ini setting)");
        }
        else
        {
            Log("[Archipelago] APTrapController.TrapTick: confundus trap ended on timer - bInvertMouse restored");
        }
    }

    if (default.bWandSizeTrapActive == 1 && bLevelChanged)
    {
        // Lasts the rest of the level like Polyjuice. The wand is inventory and may
        // travel across the boundary, so restore the canonical wand mesh actively
        // rather than relying on a fresh-spawned wand; a fresh wand already on
        // WandMesh is reassigned harmlessly.
        if (baseWand(h.Weapon) != None)
        {
            baseWand(h.Weapon).Mesh = Mesh(DynamicLoadObject("HPModels.WandMesh", class'Mesh'));
            baseWand(h.Weapon).ThirdPersonMesh = baseWand(h.Weapon).Mesh;
        }
        default.bWandSizeTrapActive = 0;
        Log("[Archipelago] APTrapController.TrapTick: Overcompensation trap ended on level change - wand mesh restored");
    }

    if (default.bLevicorpusTrapActive == 1
        && (bLevelChanged || h.Level.TimeSeconds >= default.LevicorpusTrapExpiry))
    {
        // The fresh level-change pawn spawns upright, so only the same-level
        // timeout needs the active un-roll (LevicorpusHold stops re-pinning once
        // the flag clears, but the walking physics would take a moment to right
        // him). The strafe bindings are global either way, so swap them back on
        // both paths (the swap is its own inverse). The per-frame upside-down
        // hold lives in the watcher Tick (LevicorpusHold): the 0.25s Timer is too
        // coarse to fight the walking physics each frame.
        if (!bLevelChanged)
        {
            R = h.Rotation;
            R.Roll = 0;
            h.SetRotation(R);
            h.DesiredRotation.Roll = 0;
        }
        class'APTrapKit'.static.RestoreStrafeKeys(h);
        default.bLevicorpusTrapActive = 0;
        if (bLevelChanged)
        {
            Log("[Archipelago] APTrapController.TrapTick: Levicorpus trap cleared on level change (fresh pawn upright, strafe bindings restored)");
        }
        else
        {
            Log("[Archipelago] APTrapController.TrapTick: Levicorpus trap ended on timer - Harry righted, strafe bindings restored");
        }
    }

    if (default.bJellyLegsTrapActive == 1 && bLevelChanged)
    {
        // A level change ends the hijack early like the other timed traps. The
        // lifetime countdown in JellyLegsTick handles the same-level timeout; the
        // fresh pawn spawns un-corralled, so clearing the gate here is harmless.
        EndJellyLegsTrap(h);
        Log("[Archipelago] APTrapController.TrapTick: Jelly-Legs trap cleared on level change (jump restored)");
    }

    if (default.bDrowsinessTrapActive == 1 && h.iSleepyAnimTimer <= 0)
    {
        // The engine owns the effect and its revert (harry.Timer counts the
        // sleepy countdown once per second, and a fresh level-change pawn
        // spawns awake at zero); this flag only gates the HUD countdown row.
        default.bDrowsinessTrapActive = 0;
        Log("[Archipelago] APTrapController.TrapTick: Drowsiness trap ended (engine countdown at zero)");
    }

    default.TrapLastLevelName = curLevel;
}

// Per-frame upside-down hold for the Levicorpus Trap (watcher Tick). The native
// PlayerWalking physics rights the pawn (forces Roll toward 0) every frame, faster
// than the 0.25s Timer can fight, so the roll is re-pinned here each frame like the
// sprint speed caps. The ledge pull-up is the exception: it moves Harry by
// animation root motion in the pawn's local frame, which the 180 roll turns upside
// down so the climb hauls him DOWN. Root motion is native, so the only lever is the
// pawn rotation: right him for the duration of the climb (Mounting/MountFinish) so
// the root motion plays world-up, then re-flip once he is back on his feet. Only
// acts while the trap is active and Harry is bound.
static function LevicorpusHold(harry h)
{
    local Rotator R;
    local int wantRoll;

    if (default.bLevicorpusTrapActive == 0 || h == None)
    {
        return;
    }
    if (h.IsInState('Mounting') || h.IsInState('MountFinish'))
    {
        wantRoll = 0;
    }
    else
    {
        wantRoll = 32768;
    }
    if (h.Rotation.Roll != wantRoll)
    {
        R = h.Rotation;
        R.Roll = wantRoll;
        h.SetRotation(R);
    }
    h.DesiredRotation.Roll = wantRoll;
    // Strafe inversion from the flipped right-axis is handled in the input layer by
    // SwapStrafeKeys, not here: this Tick runs after harry.PlayerMove has already
    // consumed aStrafe, so a per-frame negate would land too late.
}

// Per-frame screen tint for the Confundus Trap (watcher Tick, like LevicorpusHold).
// The trap's only effect (inverted look) is otherwise invisible, so a held green
// wash makes it unmistakable and pairs with the on-screen countdown. FlashFog is
// the engine's screen-fog Plane (X/Y/Z colour, W blend); FadeViewController writes
// it directly each tick for sustained fades, so a per-frame write here holds the
// tint despite the native flash decay. Values are 0..1 like that flash path; the
// exact colour and intensity are tuning values. Cleared by ClearConfundusTint when
// the trap ends on the timer; the level-change path gets a fresh pawn whose
// FlashFog is already zero. Only acts while the trap is active and Harry is bound.
static function ConfundusTint(harry h)
{
    if (default.bConfundusTrapActive == 0 || h == None)
    {
        return;
    }
    h.FlashFog.X = 0.0;     // red
    h.FlashFog.Y = 0.35;    // green
    h.FlashFog.Z = 0.1;     // blue
    h.FlashFog.W = 0.45;    // blend
}

// Zero the Confundus screen tint. Called from TrapTick when the trap ends on the
// same-level timer. A no-op on a fresh level-change pawn (FlashFog already zero).
static function ClearConfundusTint(harry h)
{
    if (h == None)
    {
        return;
    }
    h.FlashFog.X = 0.0;
    h.FlashFog.Y = 0.0;
    h.FlashFog.Z = 0.0;
    h.FlashFog.W = 0.0;
}
