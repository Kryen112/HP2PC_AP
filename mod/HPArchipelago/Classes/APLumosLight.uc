//================================================================================
// APLumosLight.
//
// Drop-in LumosLight for the Overcompensation Trap. The trap enlarges the held
// wand to the 3x APWandGiant mesh, but retail baseWand.GetWandEndPoint() pins the
// Lumos light (and the spell-charge glow) at WeaponLoc - 20 along the wand axis,
// the 1x wand length, and re-asserts it every frame. That offset is uncontrollable
// from the mod, and a per-frame correction elsewhere loses the tick-order race
// against baseWand. baseWand positions the light by calling TheLumosLight.Update-
// Location, so overriding that here re-places it at the 3x tip inside baseWand's
// own call: synchronous, no race. APCardWatcher.MarkWandSizeTrapActive swaps this
// in for the retail LumosLight when the trap fires. The rescale is gated on
// bWandSizeTrapActive, so when no trap is active this behaves exactly like the
// retail light and no swap-back is needed.
//
// Extends HGame.LumosLight: HGame precedes HPArchipelago in Default.ini EditPackages.
//================================================================================

class APLumosLight extends LumosLight;

const RETAIL_TIP_OFFSET = 20.0;     // baseWand.GetWandEndPoint() hardcoded 1x offset
const GIANT_SCALE       = 3.0;      // APWandGiant MeshMap scale (APWandMesh.uc)

// baseWand.Tick passes the 1x wand tip and re-asserts it every frame; while the
// trap is active, re-place the light at the giant tip instead. baseWand sets the
// spell-charge glow to the same 1x tip just before this call (reachable here only
// while Lumos is on), so realign it too. Passes through unchanged when no trap is
// live. The unit wand axis is rotated first so the * and >> precedence is plain.
function UpdateLocation(Vector NewLocation)
{
    local vector tip, axis;
    local baseWand wand;

    if (class'APCardWatcher'.default.bWandSizeTrapActive == 0 || PlayerHarry == None)
    {
        Super.UpdateLocation(NewLocation);
        return;
    }
    axis = vect(0,0,1) >> PlayerHarry.WeaponRot;
    tip = PlayerHarry.WeaponLoc - axis * (RETAIL_TIP_OFFSET * GIANT_SCALE);
    Super.UpdateLocation(tip);
    wand = baseWand(PlayerHarry.Weapon);
    if (wand != None && wand.fxChargeParticles != None && wand.fxChargeParticles.bEmit)
    {
        wand.fxChargeParticles.SetLocation(tip);
    }
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
