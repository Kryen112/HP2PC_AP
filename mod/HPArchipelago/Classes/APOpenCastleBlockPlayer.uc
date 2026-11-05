// A BlockPlayer with box collision, for the open castle player blockers a stock
// install lacks. It spawns without collision (a blocker overlapping level
// geometry would not spawn); APOpenCastle.SpawnBlocker turns it on.
class APOpenCastleBlockPlayer extends BlockPlayer;

defaultproperties
{
    CollideType=CT_Box
    bCollideActors=False
    bBlockPlayers=False
}
