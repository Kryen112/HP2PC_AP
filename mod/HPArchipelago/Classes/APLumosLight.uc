//================================================================================
// APLumosLight.
//
// Drop-in LumosLight for the Overcompensation Trap. The trap enlarges the held
// wand to the 3x APWandGiant mesh, but retail baseWand pins the Lumos light and
// the spell-charge glow at WeaponLoc - 20 along the wand axis (the 1x wand length)
// and re-asserts it every frame. That offset is uncontrollable from the mod, so
// this light re-places both at the 3x tip. The rescale is gated on
// bWandSizeTrapActive, so with no trap live this behaves exactly like the retail
// light and no swap-back is needed. APTrapController.MarkWandSizeTrapActive swaps
// this in for the retail LumosLight when the trap fires.
//
// baseWand positions the light by calling TheLumosLight.UpdateLocation, so the
// override there re-places the light (and the glow, which baseWand sets to the same
// tip just before that call) from inside baseWand's own call: synchronous, no
// tick-order race. But baseWand only calls UpdateLocation while Lumos is on. When
// Lumos is off the glow is still pinned to the 1x tip and UpdateLocation is never
// reached, so Tick realigns the glow instead. This actor is spawned when the trap
// fires, after baseWand, so it ticks after baseWand and its write lands last.
// Retail LumosLight disables Tick while Lumos is off, so PreBeginPlay and TurnOff
// re-enable it to keep that realignment running.
//
// Extends HGame.LumosLight: HGame precedes HPArchipelago in Default.ini EditPackages.
//================================================================================

class APLumosLight extends LumosLight;

const RETAIL_TIP_OFFSET = 20.0;     // baseWand.GetWandEndPoint() hardcoded 1x offset
const GIANT_SCALE       = 3.0;      // APWandGiant MeshMap scale (APWandMesh.uc)

// The APWandGiant tip in world space: the retail 1x offset scaled by the mesh bake.
// The unit wand axis is rotated first so the * and >> precedence is plain.
function vector GiantWandTip()
{
    local vector axis;

    axis = vect(0,0,1) >> PlayerHarry.WeaponRot;
    return PlayerHarry.WeaponLoc - axis * (RETAIL_TIP_OFFSET * GIANT_SCALE);
}

// Drag the spell-charge glow from the 1x tip baseWand pins it to back onto the giant
// tip. Guarded by bEmit so a non-glowing particle system is left where it is.
function RealignChargeGlow(vector tip)
{
    local baseWand wand;

    wand = baseWand(PlayerHarry.Weapon);
    if (wand != None && wand.fxChargeParticles != None && wand.fxChargeParticles.bEmit)
    {
        wand.fxChargeParticles.SetLocation(tip);
    }
}

// baseWand.Tick passes the 1x wand tip and re-asserts it every frame; while the trap
// is active, re-place the light and the glow at the giant tip instead. Passes
// through unchanged when no trap is live.
function UpdateLocation(Vector NewLocation)
{
    local vector tip;

    if (class'APTrapController'.default.bWandSizeTrapActive == 0 || PlayerHarry == None)
    {
        Super.UpdateLocation(NewLocation);
        return;
    }
    tip = GiantWandTip();
    Super.UpdateLocation(tip);
    RealignChargeGlow(tip);
}

// The Lumos-on realignment happens in UpdateLocation (called from baseWand.Tick).
// With Lumos off baseWand never calls UpdateLocation, so realign the glow here.
// Only acts while the trap is active and Lumos is off; the Lumos-on light animation
// is left to Super.
function Tick(float fTimeDelta)
{
    Super.Tick(fTimeDelta);
    if (class'APTrapController'.default.bWandSizeTrapActive == 1 && !bLumosOn && PlayerHarry != None)
    {
        RealignChargeGlow(GiantWandTip());
    }
}

// Retail LumosLight disables Tick while Lumos is off; keep it live so the Lumos-off
// glow realignment in Tick runs. It early-returns cheaply when no trap is active.
function PreBeginPlay()
{
    Super.PreBeginPlay();
    Enable('Tick');
}

// Retail TurnOff disables Tick; re-enable it so the glow realignment keeps running
// after Lumos ends while the trap is still live.
function TurnOff()
{
    Super.TurnOff();
    Enable('Tick');
}

// Retail LumosLight.Destroyed emits an unconditional debug ClientMessage; drop it
// while keeping the teardown (turn the light off, free the particles).
event Destroyed()
{
    TurnOff();
    if (Particles != None)
    {
        Particles.Destroy();
    }
}

defaultproperties
{
    bUseDebugMode=False
}
