// The visible stone slab under the open castle Spongify pad on the Grounds,
// flush with the floor and skinned with the stock pad texture. It has no
// collision, so the Spongify spell reaches the pad above it.
class APSpongifySlab extends Actor;

function PostBeginPlay()
{
    local Mesh slab;
    local Texture face;

    Super.PostBeginPlay();
    slab = class'APAppearanceMath'.static.LoadMesh("HPArchipelago.APSlabMesh");
    face = class'APAppearanceMath'.static.LoadTexture("GroundsHub.ground.Spongify_GH1");
    if (slab != None)
    {
        Mesh = slab;
    }
    if (face != None)
    {
        Skin = face;
        MultiSkins[0] = face;
    }
}

defaultproperties
{
    DrawType=DT_Mesh
    CollideType=CT_Box
    bCollideActors=False
    bBlockActors=False
    bBlockPlayers=False
    bCollideWorld=False
}
