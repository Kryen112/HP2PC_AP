//=============================================================================
// APFordAngliaBlocker - wrecked-Ford-Anglia open-castle blocker for the
// Whomping Willow chokepoint. Drop-in stand-in for the generic
// BookcaseGlassDoors blocker at the Willow approach: the car visually crashed
// into the tree reads as "you're blocked because the Willow encounter isn't
// available yet", which a stack of bookcases outdoors does not.
//
// Inherits APBookcaseBlocker (and through it BookcaseGlassDoors) so the unlock
// pipeline (DestroyTaggedOpenCastleBlockers scans by Tag, not class), the
// spawn/encroachment retry, and the bumped-subtitle reminder in
// SpawnOpenCastleBookcase work unchanged - only the mesh / collision /
// lighting differ. Tag and BlockMessage are set per-spawn by SpawnOpenCastleBookcase.
//
// AmbientGlow brightens the mesh a touch so the wreck reads at outdoor night
// lighting in Grounds_Night; the bookcase mesh ships brighter natively and
// does not need the help.
//=============================================================================

class APFordAngliaBlocker extends APBookcaseBlocker;

defaultproperties
{
    Mesh=SkeletalMesh'HProps.skFordAngliaDamagedMesh'
    DrawScale=1.10
    AmbientGlow=25

    CollisionRadius=140.00
    CollisionWidth=55.00
    CollisionHeight=53.00
    CollideType=CT_Box
}
