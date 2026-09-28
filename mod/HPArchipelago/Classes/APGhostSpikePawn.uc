//================================================================================
// APGhostSpikePawn.
//
// Ghost-players render spike, HPawn base: the same translucent Harry mesh as
// APGhostSpikeActor on the pawn lineage every vanilla prop and character uses.
// No shadow, no collision, no physics; APGhostSpikeDriver places and animates it.
//================================================================================

class APGhostSpikePawn extends HPawn;

defaultproperties
{
    DrawType=DT_Mesh
    Mesh=SkeletalMesh'HPModels.skharryMesh'
    Style=STY_Translucent
    AmbientGlow=65
    ShadowClass=None
    Physics=PHYS_None
    bCollideActors=False
    bCollideWorld=False
    bBlockActors=False
    bBlockPlayers=False
    bProjTarget=False
    eVulnerableToSpell=SPELL_None
    CollisionRadius=15.00
    CollisionHeight=42.00
}
