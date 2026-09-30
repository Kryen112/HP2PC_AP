//================================================================================
// APGhostLight.
//
// The coloured glow that rides with a ghost so players are told apart before
// the nameplate is readable. A plain light actor like Lumos, moved by its
// APGhostPawn every tick and coloured from the peer's slot number. Nothing is
// drawn; the light itself is the marker.
//================================================================================

class APGhostLight extends Actor;

// Hue steps of 97 spread neighbouring slots across the wheel.
const HUE_STEP = 97;

function SetSlotColour(int slot)
{
    LightHue = byte((slot * HUE_STEP) & 255);
}

function SetLit(bool bLit)
{
    if (bLit) LightType = LT_Steady;
    else      LightType = LT_None;
}

defaultproperties
{
    DrawType=DT_None
    bCollideActors=False
    bCollideWorld=False
    bBlockActors=False
    bBlockPlayers=False
    Physics=PHYS_None
    LightType=LT_Steady
    LightBrightness=180
    LightSaturation=48
    LightRadius=5
}
