//================================================================================
// APGhostSpikeActor.
//
// Ghost-players render spike, Engine.Actor base. A translucent Harry mesh with
// no collision and no physics, placed and animated by APGhostSpikeDriver. Style
// and glow mirror Moaning Myrtle, the shipped translucent character.
//================================================================================

class APGhostSpikeActor extends Actor;

defaultproperties
{
    DrawType=DT_Mesh
    Mesh=SkeletalMesh'HPModels.skharryMesh'
    Style=STY_Translucent
    AmbientGlow=65
    Physics=PHYS_None
    bCollideActors=False
    bCollideWorld=False
    bBlockActors=False
    bBlockPlayers=False
    bProjTarget=False
    eVulnerableToSpell=SPELL_None
}
