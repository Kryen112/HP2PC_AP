// Base class for the 6 AP-themed pickup star bursts.
//
// Modeled on HPParticle.BronzePickup / SilverPickup / GoldPickup defaults
// (same emission/motion/shape so the burst feels native) but with a smaller
// particle count (6 of these spawn at once on each AP card pickup; vanilla
// spawns only 1).
//
// Subclasses override only ColorStart/ColorEnd to one of the 6 Archipelago
// logo colors. Spawned by APCardMarker.Touch when the player picks up an AP
// marker.
class APStarsBase extends WizardPickups;

// Spawn the 6 Archipelago-logo-coloured pickup star bursts at loc. ctx is the
// picked-up actor (the burst spawns into its level). Pitch=16464 matches vanilla
// WizardCardIcon.Touch's rotPickupFX so the stars emit upward, not into the floor.
static function SpawnPickupBurst(Actor ctx, Vector loc)
{
    local Rotator rot;
    rot.Pitch = 16464;
    rot.Yaw = 0;
    rot.Roll = 0;
    ctx.Spawn(class'APStarsRed',    None, '', loc, rot);
    ctx.Spawn(class'APStarsOrange', None, '', loc, rot);
    ctx.Spawn(class'APStarsYellow', None, '', loc, rot);
    ctx.Spawn(class'APStarsGreen',  None, '', loc, rot);
    ctx.Spawn(class'APStarsBlue',   None, '', loc, rot);
    ctx.Spawn(class'APStarsPurple', None, '', loc, rot);
}

defaultproperties
{
    ParticlesPerSec=(Base=1000.00,Rand=0.00)
    SourceWidth=(Base=0.00,Rand=0.00)
    SourceHeight=(Base=0.00,Rand=0.00)
    AngularSpreadWidth=(Base=45.00,Rand=45.00)
    AngularSpreadHeight=(Base=45.00,Rand=45.00)
    bSteadyState=True
    Speed=(Base=200.00,Rand=50.00)
    Lifetime=(Base=2.00,Rand=1.00)
    SizeWidth=(Base=3.00,Rand=2.00)
    SizeLength=(Base=3.00,Rand=2.00)
    SizeEndScale=(Base=4.00,Rand=0.00)
    SpinRate=(Base=-8.00,Rand=8.00)
    Chaos=20.00
    ChaosDelay=0.25
    Attraction=(X=0.25,Y=0.25,Z=0.00)
    Damping=3.00
    GravityModifier=0.20
    ParticlesMax=40
    ParticlesEmitted=20
    Textures(0)=Texture'HPParticle.hp_fx.Particles.Les_Sparkle_04'
    Age=643.23
    bDynamicLight=True
    Tag=Dummyparticle
    Location=(X=0.00,Y=0.00,Z=32.00)
    OldLocation=(X=0.00,Y=0.00,Z=32.00)
    CollisionRadius=75.00
    CollisionHeight=35.00
}
